import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/email_rebind_page.dart';
import 'package:liuhetong_mobile/features/profile/profile_page.dart';
import '../../core/account_credentials_client_test.dart' show MemoryStore;

void main() {
  final requests = <http.Request>[];
  late BusinessApiClient api;
  var availabilityFails = false, rejectCooldown = false, cooldown = false;
  Completer<http.Response>? bindingResponse;
  setUp(() async {
    requests.clear();
    availabilityFails = false;
    rejectCooldown = false;
    cooldown = false;
    bindingResponse = null;
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(
        accessToken: 'a', refreshToken: 'r', matrixUserId: '@stable:test');
    api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path.endsWith('/email/rebind/confirm')) {
            return bindingResponse!.future;
          }
          if (path.endsWith('/profile/me')) {
            return http.Response(
                jsonEncode({
                  'username': 'alice1',
                  'nickname': 'Alice',
                  'masked_email': 'a***@test.example',
                  'masked_phone': '138****0000',
                  'avatar_fallback_seed': 'stable-uuid'
                }),
                200);
          }
          if (path.endsWith('/invitations/mine')) {
            return http.Response(
                '{"code":"ABCDEF","max_uses":10,"use_count":2,"share_url":"https://test.example"}',
                200);
          }
          if (path.endsWith('/account-security')) {
            return http.Response(
                '{"masked_email":"a***@test.example","masked_phone":"138****0000","email_bound":true,"phone_bound":true,"email_verified":true,"phone_verified":true}',
                200);
          }
          if (path.endsWith('/username-change')) {
            return http.Response(
                jsonEncode({
                  'username': 'alice1',
                  'can_change': !cooldown,
                  'next_change_at': cooldown ? '2027-09-26T12:00:00Z' : null,
                  'min_length': 6,
                  'max_length': 20
                }),
                200);
          }
          if (path.endsWith('/username-availability')) {
            if (availabilityFails) return http.Response('{}', 503);
            return http.Response(
                '{"username":"Alice-New","available":true}', 200);
          }
          if (path.endsWith('/profile/username') && request.method == 'PATCH') {
            if (rejectCooldown) {
              cooldown = true;
              return http.Response(
                  '{"error":{"code":"USERNAME_CHANGE_COOLDOWN","message":"cooldown"}}',
                  409);
            }
            return http.Response(
                '{"username":"Alice-New","changed":true,"next_change_at":"2027-09-26T12:00:00Z"}',
                200);
          }
          return http.Response('{}', 200);
        }));
  });
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    });
    await tester.pumpAndSettle();
  }

  Future<void> details(WidgetTester tester) async {
    await tester.pumpWidget(
        CupertinoApp(home: ProfileTabPage(api: api, onLogout: () async {})));
    await settle(tester);
    await tester.tap(find.text('Alice').first);
    await settle(tester);
    expect(find.byType(ProfileDetailsPage), findsOneWidget);
  }

  testWidgets(
      'profile username entry checks availability and saves business identity only',
      (tester) async {
    await details(tester);
    await tester.tap(find.byKey(const Key('profile-username-row')));
    await settle(tester);
    expect(find.text('修改畅聊号'), findsOneWidget);
    await tester.enterText(find.byType(CupertinoTextField), 'Alice-New');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.text('该畅聊号可以使用'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(find.text('Alice-New'), findsOneWidget);
    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/api/v1/profile/username');
    expect(jsonDecode(patch.body), {'username': 'Alice-New'});
    expect(patch.headers['Idempotency-Key'], isNotEmpty);
    expect((await api.sessionStore.session())!.matrixUserId, '@stable:test');
  });
  testWidgets(
      'profile email row opens binding directly and rechecks authority on return',
      (tester) async {
    await details(tester);
    await tester.tap(find.byKey(const Key('profile-email-row')));
    await settle(tester);
    expect(find.byType(EmailRebindPage), findsOneWidget);
    final before =
        requests.where((r) => r.url.path.endsWith('account-security')).length;
    await tester.pageBack();
    await settle(tester);
    expect(
        requests.where((r) => r.url.path.endsWith('account-security')).length,
        before + 1);
    expect(requests.where((r) => r.url.path.endsWith('/profile/me')).length, 2);
  });
  testWidgets('availability failure exposes retry without replacing the draft',
      (tester) async {
    await details(tester);
    await tester.tap(find.byKey(const Key('profile-username-row')));
    await settle(tester);
    availabilityFails = true;
    await tester.enterText(find.byType(CupertinoTextField), 'Alice-New');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.text('重试'), findsOneWidget);
    availabilityFails = false;
    await tester.tap(find.text('重试'));
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.text('该畅聊号可以使用'), findsOneWidget);
    expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField))
            .controller!
            .text,
        'Alice-New');
  });
  testWidgets(
      'profile binding return shows pending then refreshes after settle',
      (tester) async {
    await details(tester);
    await tester.tap(find.byKey(const Key('profile-email-row')));
    await settle(tester);
    bindingResponse = Completer<http.Response>();
    final confirmation = api
        .confirmEmailRebind(email: 'new@example.test', code: '123456')
        .catchError((Object _) {});
    await tester.pageBack();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    });
    await tester.pump(const Duration(seconds: 9));
    await tester.pump();
    expect(find.text('绑定结果待确认，请稍后重试'), findsOneWidget);
    expect(find.text('暂不可用'), findsNWidgets(2));
    bindingResponse!.complete(http.Response('', 204));
    await settle(tester);
    await confirmation;
    expect(find.text('绑定结果待确认，请稍后重试'), findsNothing);
    expect(find.text('暂不可用'), findsNothing);
    expect(requests.where((r) => r.url.path.endsWith('/profile/me')).length, 2);
  });
  testWidgets('server cooldown during save refreshes policy and disables edits',
      (tester) async {
    await details(tester);
    await tester.tap(find.byKey(const Key('profile-username-row')));
    await settle(tester);
    await tester.enterText(find.byType(CupertinoTextField), 'Alice-New');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    rejectCooldown = true;
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField))
            .enabled,
        false);
    expect(find.textContaining('下次可修改'), findsOneWidget);
  });
}
