import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moments_page.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';

/// 问题四：朋友圈按需分页加载。
/// - 首屏只请求最新一页；滚动接近底部自动加载下一页（并发只发一次）；
/// - 到底停止（“没有更多了”）；下拉刷新重新获取第一页并重置分页；
/// - 加载更多失败保留已展示内容并提供重试；空列表有空态。
/// 后端契约不变（GET /moments/feed?mode=&cursor=，游标分页）。
final class MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Map<String, dynamic> postJson(String id) => {
      'id': id,
      'author': {
        'user_id': 'u1',
        'username': 'alice_id',
        'nickname': 'Alice',
        'remark': null,
        'display_name': 'Alice',
        'avatar_url': null,
      },
      'text': '正文-$id',
      'image_urls': <String>[],
      'created_at': DateTime.now().toIso8601String(),
      'viewer_has_liked': false,
      'like_count': 0,
      'like_users': <Map<String, dynamic>>[],
      'comments': <Map<String, dynamic>>[],
    };

http.Response page(List<String> ids, String? cursor) => http.Response(
      jsonEncode({
        'items': [for (final id in ids) postJson(id)],
        'next_cursor': cursor,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
  });

  Future<void> pumpMoments(WidgetTester tester, BusinessApiClient api) async {
    final identity = ProfileRepository.forTesting(
        accountKey: 'matrix:@me:test', store: MomentsIdentityStore());
    await tester.pumpWidget(
        CupertinoApp(home: MomentsPage(api: api, identityCache: identity)));
    await tester.pumpAndSettle();
  }

  testWidgets('首屏只请求最新一页，滚动到底自动加载下一页且并发只发一次', (tester) async {
    final feedCalls = <String?>[];
    Completer<http.Response>? holdLoadMore;
    final api = await momentsApiFor((request) async {
      if (request.url.path.endsWith('/moments/feed')) {
        final cursor = request.url.queryParameters['cursor'];
        feedCalls.add(cursor);
        if (cursor != null) {
          // 挂起加载更多，验证滚动连发不会重复请求。
          holdLoadMore = Completer<http.Response>();
          return holdLoadMore!.future;
        }
        return page(
            ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8'], 'cursor-1');
      }
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
    });
    await pumpMoments(tester, api);

    expect(feedCalls, [isNull], reason: '首屏只允许一次第一页请求');
    expect(find.text('正文-p1'), findsOneWidget);

    // 滚动接近底部：触发第一次自动加载（挂起中）。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
    await tester.pump();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await tester.pump();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await tester.pump();
    expect(feedCalls.where((c) => c != null).length, 1,
        reason: '加载更多进行中，继续滚动不得重复请求');

    holdLoadMore!.complete(page(['n1', 'n2'], null));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text('正文-n1'), findsOneWidget);
    expect(find.byKey(const Key('moments-no-more')), findsOneWidget,
        reason: '到底后显示“没有更多了”并停止请求');

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(feedCalls.where((c) => c != null).length, 1, reason: '到底后不再请求');
  });

  testWidgets('加载更多失败保留内容并支持重试', (tester) async {
    var failNext = true;
    final api = await momentsApiFor((request) async {
      if (request.url.path.endsWith('/moments/feed')) {
        if (request.url.queryParameters['cursor'] != null) {
          if (failNext) {
            return http.Response('{"message":"boom"}', 500,
                headers: {'content-type': 'application/json'});
          }
          return page(['n1'], null);
        }
        return page(
            ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8'], 'cursor-1');
      }
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
    });
    await pumpMoments(tester, api);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
    await tester.pumpAndSettle();

    expect(find.text('正文-p8'), findsOneWidget, reason: '失败保留已展示内容');
    expect(find.byKey(const Key('moments-load-more-retry')), findsOneWidget);

    failNext = false;
    await tester.tap(find.byKey(const Key('moments-load-more-retry')));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(find.text('正文-n1'), findsOneWidget, reason: '重试成功补齐下一页');
    expect(find.byKey(const Key('moments-load-more-retry')), findsNothing);
  });

  testWidgets('下拉刷新重新获取第一页并重置分页游标', (tester) async {
    var version = 0;
    final feedCalls = <String?>[];
    final api = await momentsApiFor((request) async {
      if (request.url.path.endsWith('/moments/feed')) {
        final cursor = request.url.queryParameters['cursor'];
        feedCalls.add(cursor);
        if (cursor != null) {
          return page(version == 0 ? ['old-1'] : ['new-1'], null);
        }
        return page(
            version == 0
                ? [for (var i = 1; i <= 12; i++) 'p$i']
                : [for (var i = 1; i <= 12; i++) 'p$i-new'],
            'cursor-1');
      }
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
    });
    await pumpMoments(tester, api);
    expect(feedCalls, [isNull]);

    // 下拉刷新。
    version = 1;
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 600));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('正文-p1-new'), findsOneWidget);
    expect(find.text('正文-p1'), findsNothing, reason: '刷新后展示最新一页');

    // 刷新后滚动加载必须使用新一轮游标（拉取新内容的第二页）。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.text('正文-new-1'), findsOneWidget);
    expect(feedCalls.where((c) => c != null), ['cursor-1'],
        reason: '加载更多只发生在刷新后的游标上');
  });

  for (final staleFailure in [false, true]) {
    testWidgets('刷新后丢弃旧游标响应并能继续分页：failure=$staleFailure', (tester) async {
      var version = 0;
      var freshNextRequests = 0;
      Completer<http.Response>? holdLoadMore;
      final api = await momentsApiFor((request) async {
        if (request.url.path.endsWith('/moments/feed')) {
          final cursor = request.url.queryParameters['cursor'];
          if (cursor != null) {
            if (version == 1) {
              freshNextRequests++;
              return page(['fresh-next'], null);
            }
            holdLoadMore = Completer<http.Response>();
            return holdLoadMore!.future;
          }
          return page(
              version == 0
                  ? [for (var i = 1; i <= 12; i++) 'p$i']
                  : [for (var i = 1; i <= 12; i++) 'p$i-new'],
              'cursor-$version');
        }
        return http.Response('{}', 200,
            headers: {'content-type': 'application/json'});
      });
      await pumpMoments(tester, api);

      // 先触发加载更多（旧游标，挂起）。
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
      await tester.pump();
      final pending = holdLoadMore!;
      expect(pending.isCompleted, isFalse);

      // 刷新开始并完成（epoch 前移）：先回顶部，再下拉触发 overscroll。
      version = 1;
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 1600));
      await tester.pump();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 600));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('正文-p1-new'), findsOneWidget);

      // 旧游标响应此时才到达：必须被丢弃，不得混入新列表。
      pending.complete(staleFailure
          ? http.Response('{"code":"UNAVAILABLE","message":"offline"}', 503,
              headers: {'content-type': 'application/json'})
          : page(['stale-1'], null));
      await tester.pumpAndSettle();
      expect(find.text('正文-stale-1'), findsNothing, reason: '过期分页响应必须丢弃');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -1800));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('moments-load-more-retry')), findsNothing);
      expect(freshNextRequests, 1);
    });
  }

  testWidgets('首屏失败有重试入口，滚动不抛异常，重试后能继续分页', (tester) async {
    var offline = true;
    var nextCalls = 0;
    final api = await momentsApiFor((request) async {
      if (request.url.path.endsWith('/moments/feed')) {
        if (offline) {
          return http.Response('{"code":"OFFLINE","message":"offline"}', 503,
              headers: {'content-type': 'application/json'});
        }
        if (request.url.queryParameters['cursor'] != null) {
          nextCalls++;
          return page(['next'], null);
        }
        return page([for (var i = 0; i < 12; i++) 'p$i'], 'next');
      }
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
    });
    await pumpMoments(tester, api);
    expect(find.byKey(const Key('moments-initial-retry')), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    offline = false;
    await tester.tap(find.byKey(const Key('moments-initial-retry')));
    await tester.pumpAndSettle();
    expect(find.text('正文-p0'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1800));
    await tester.pumpAndSettle();
    expect(nextCalls, 1);
  });

  testWidgets('空列表显示空态', (tester) async {
    final api = await momentsApiFor((request) async {
      if (request.url.path.endsWith('/moments/feed')) {
        return page(const [], null);
      }
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
    });
    await pumpMoments(tester, api);
    expect(find.byKey(const Key('moments-empty')), findsOneWidget);
  });
}

Future<BusinessApiClient> momentsApiFor(
    Future<http.Response> Function(http.Request) handler) async {
  final store = SecureSessionStore(MemoryStore());
  await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.example'),
    sessionStore: store,
    client: MockClient(handler),
  );
}

final class MomentsIdentityStore implements ProfileStore {
  final values = <String, ProfileSnapshot>{};

  @override
  Future<ProfileSnapshot?> read(String accountKey) async => values[accountKey];

  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    values[accountKey] = snapshot;
  }
}
