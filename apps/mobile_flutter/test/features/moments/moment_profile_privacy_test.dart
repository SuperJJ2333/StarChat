import 'dart:convert';
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_profile_preview.dart';
import 'package:liuhetong_mobile/features/moments/moments_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_detail_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/features/moments/moments_privacy_changes.dart';

class _Store implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

Future<BusinessApiClient> apiFor(
    Future<http.Response> Function(http.Request) handler) async {
  final store = SecureSessionStore(_Store());
  await store.saveSession(
      accessToken: 'e30.eyJzdWIiOiJ1MSJ9.test', refreshToken: 'synthetic');
  return BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: store,
      client: MockClient(handler));
}

http.Response response(Object value, [int code = 200]) =>
    http.Response(jsonEncode(value), code,
        headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  testWidgets('detail discards cached content after permission revocation',
      (tester) async {
    final api =
        await apiFor((_) async => response({'message': 'not found'}, 404));
    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api,
            initialItem: MomentItem.fromJson({
              'id': 'm1',
              'text': 'previously visible',
              'author': {'user_id': 'u2', 'username': 'bob'}
            }),
            currentUsername: 'alice')));
    await tester.pumpAndSettle();
    expect(find.text('previously visible'), findsNothing);
    expect(find.text('动态已不可见'), findsOneWidget);
  });
  testWidgets('privacy invalidation hides old preview while checking new grant',
      (tester) async {
    final pending = Completer<http.Response>();
    var reads = 0;
    final api = await apiFor((_) async => ++reads == 1
        ? response({'entry_visible': true, 'items': []})
        : pending.future);
    await tester.pumpWidget(CupertinoApp(
        home: MomentProfilePreview(api: api, userId: 'u2', displayName: '小明')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('friend-moments-section')), findsOneWidget);
    momentsPrivacyChanges.notifyListeners();
    await tester.pump();
    expect(find.byKey(const Key('friend-moments-section')), findsNothing);
    pending.complete(response({'entry_visible': false, 'items': []}));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('friend-moments-section')), findsNothing);
  });
  testWidgets('forbidden profile does not render even a supplied preview',
      (tester) async {
    final api = await apiFor(
        (_) async => response({'entry_visible': false, 'items': []}));
    await tester.pumpWidget(CupertinoApp(
        home: MomentProfilePreview(api: api, userId: 'u2', displayName: '小明')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('friend-moments-section')), findsNothing);
  });
  testWidgets('permitted empty profile opens the correct author empty timeline',
      (tester) async {
    final paths = <String>[];
    final api = await apiFor((r) async {
      paths.add(r.url.path);
      return response(r.url.path.endsWith('/preview')
          ? {'entry_visible': true, 'items': []}
          : {'items': []});
    });
    await tester.pumpWidget(CupertinoApp(
        home: MomentProfilePreview(api: api, userId: 'u2', displayName: '小明')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('friend-moments-section')));
    await tester.pumpAndSettle();
    expect(paths, contains('/api/v1/moments/users/u2'));
    expect(find.text('暂无动态'), findsOneWidget);
  });
  testWidgets(
      'settings persist author range, exclusion list and entry gate together',
      (tester) async {
    Map<String, dynamic>? saved;
    final api = await apiFor((r) async {
      if (r.method == 'PUT') {
        saved = Map<String, dynamic>.from(jsonDecode(r.body));
        return response(saved!);
      }
      return response({
        'history_range': 'ALL',
        'personalized_recommendations': false,
        'profile_entry_enabled': true,
        'excluded_user_ids': ['u2']
      });
    });
    await tester.pumpWidget(CupertinoApp(home: MomentsSettingsPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近三天'));
    await tester.pumpAndSettle();
    expect(saved?['history_range'], 'THREE_DAYS');
    expect(saved?['excluded_user_ids'], ['u2']);
    await tester.tap(find.byKey(const Key('moments-profile-entry-switch')));
    await tester.pumpAndSettle();
    expect(saved?['profile_entry_enabled'], false);
    expect(saved?['personalized_recommendations'], false);
  });
  testWidgets('failed privacy save retains draft and offers retry',
      (tester) async {
    var fail = true;
    final api = await apiFor((r) async {
      if (r.method == 'PUT') {
        return fail
            ? response({'message': 'failed'}, 500)
            : response(jsonDecode(r.body));
      }
      return response({
        'history_range': 'ALL',
        'personalized_recommendations': true,
        'profile_entry_enabled': true,
        'excluded_user_ids': []
      });
    });
    await tester.pumpWidget(CupertinoApp(home: MomentsSettingsPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近三天'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsOneWidget);
    fail = false;
    await tester.tap(find.byKey(const Key('moments-privacy-retry')));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsNothing);
  });
}
