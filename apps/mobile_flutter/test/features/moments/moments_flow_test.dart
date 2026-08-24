import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moments_page.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_image_grid.dart';

final class MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Map<String, dynamic> momentJson(
        {required bool liked, required int likeCount}) =>
    {
      'id': 'm1',
      'author': {
        'user_id': 'u1',
        'username': 'alice_id',
        'nickname': 'Alice',
        'remark': '项目小爱',
        'display_name': '项目小爱',
        'avatar_url': null,
      },
      'text': '朋友圈正文',
      'image_urls': <String>[],
      'created_at': DateTime.now().toIso8601String(),
      'viewer_has_liked': liked,
      'like_count': likeCount,
      'like_users': <Map<String, dynamic>>[],
      'comments': <Map<String, dynamic>>[],
    };

Future<BusinessApiClient> momentsApi(
    Future<http.Response> Function(http.Request) handler) async {
  final store = SecureSessionStore(MemoryStore());
  await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.example'),
    sessionStore: store,
    client: MockClient(handler),
  );
}

void main() {
  testWidgets('moment image grid supports 1 4 and 9 images', (tester) async {
    for (final count in [1, 4, 9]) {
      await tester.pumpWidget(CupertinoApp(
          home: WeChatMomentImageGrid(
              imageUrls: List.generate(count, (i) => 'invalid://$i'))));
      expect(find.byKey(const ValueKey('moment-image')), findsNWidgets(count));
    }
  });

  testWidgets(
      'moments has one feed and likes optimistically before API success',
      (tester) async {
    final likeResponse = Completer<http.Response>();
    var serverLiked = false;
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(
          jsonEncode({
            'items': [
              momentJson(liked: serverLiked, likeCount: serverLiked ? 3 : 2)
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(
          jsonEncode({
            'history_range': 'ALL',
            'personalized_recommendations': true,
            'cover_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/m1/likes' &&
          request.method == 'POST') {
        final response = await likeResponse.future;
        serverLiked = true;
        return response;
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });

    await tester.pumpWidget(CupertinoApp(home: MomentsPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('推荐'), findsNothing);
    expect(find.text('最新'), findsNothing);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pump();
    expect(find.byIcon(CupertinoIcons.heart_fill), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    likeResponse.complete(http.Response(
      jsonEncode({'id': 'like-1'}),
      201,
      headers: {'content-type': 'application/json'},
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.heart_fill), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('failed optimistic like rolls back and shows API error',
      (tester) async {
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(
          jsonEncode({
            'items': [momentJson(liked: false, likeCount: 2)]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(
          jsonEncode({
            'history_range': 'ALL',
            'personalized_recommendations': true,
            'cover_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/m1/likes') {
        return http.Response(
          jsonEncode({
            'error': {'code': 'MOMENT_LIKE_FAILED', 'message': '点赞同步失败'}
          }),
          503,
          headers: {'content-type': 'application/json'},
        );
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });

    await tester.pumpWidget(CupertinoApp(home: MomentsPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pumpAndSettle();

    expect(find.byIcon(CupertinoIcons.heart), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('点赞同步失败'), findsOneWidget);
  });

  testWidgets('comment button submits and immediately renders returned comment',
      (tester) async {
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(
          jsonEncode({
            'items': [momentJson(liked: false, likeCount: 0)]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(
          jsonEncode({
            'history_range': 'ALL',
            'personalized_recommendations': true,
            'cover_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/m1/comments') {
        expect(jsonDecode(request.body)['text'], '即时评论');
        return http.Response(
          jsonEncode({
            'id': 'c1',
            'user_id': 'u2',
            'parent_id': null,
            'text': '即时评论',
            'created_at': DateTime.now().toIso8601String(),
            'author': {
              'user_id': 'u2',
              'username': 'bob_id',
              'nickname': 'Bob',
              'remark': '项目小波',
              'display_name': '项目小波',
              'avatar_url': null,
            },
            'parent_author': null,
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });

    await tester.pumpWidget(CupertinoApp(home: MomentsPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-comment-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), '即时评论');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    await tester.pumpAndSettle();

    expect(find.text('项目小波：即时评论'), findsOneWidget);
  });

  testWidgets('failed comment keeps draft and shows server error',
      (tester) async {
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(
          jsonEncode({
            'items': [momentJson(liked: false, likeCount: 0)]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(
          jsonEncode({
            'history_range': 'ALL',
            'personalized_recommendations': true,
            'cover_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/m1/comments') {
        return http.Response(
          jsonEncode({
            'error': {'code': 'COMMENT_FAILED', 'message': '评论提交失败'}
          }),
          503,
          headers: {'content-type': 'application/json'},
        );
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });

    await tester.pumpWidget(CupertinoApp(home: MomentsPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-comment-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), '保留这条评论');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    await tester.pumpAndSettle();

    expect(find.text('评论提交失败'), findsOneWidget);
    expect(find.text('保留这条评论'), findsOneWidget);
  });

  testWidgets('cover opens full screen viewer with bottom-right change action',
      (tester) async {
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(
          jsonEncode({'items': <Map<String, dynamic>>[]}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(
          jsonEncode({
            'history_range': 'ALL',
            'personalized_recommendations': true,
            'cover_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });

    await tester.pumpWidget(CupertinoApp(home: MomentsPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-cover-header')));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byKey(const Key('moment-change-cover')), findsOneWidget);
    expect(find.text('换封面'), findsOneWidget);
  });
}
