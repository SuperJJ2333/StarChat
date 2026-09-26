import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_page.dart';
import 'package:liuhetong_mobile/features/auth/password_change_page.dart';
import 'package:liuhetong_mobile/features/profile/account_settings_pages.dart';
import '../../core/account_credentials_client_test.dart' show MemoryStore;

void main() {
  late BusinessApiClient api;
  final requests = <http.Request>[];
  var reject = false;
  var securityFail = false;
  var noBindings = false;
  Completer<http.Response>? bindingResponse;
  setUp(() async {
    requests.clear();
    reject = false;
    securityFail = false;
    noBindings = false;
    bindingResponse = null;
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(
        accessToken: 'a', refreshToken: 'r', matrixUserId: '@a:test');
    api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/email/rebind/confirm')) {
            return bindingResponse!.future;
          }
          if (r.url.path.endsWith('/password/code/verify')) {
            return http.Response(
                '{"reset_token":"proof","expires_in":300}', 200);
          }
          if (r.url.path.endsWith('/password/code/reset')) {
            return http.Response('', 204);
          }
          if (r.url.path.endsWith('/auth/login')) {
            return http.Response(
                '{"access_token":"new","refresh_token":"new-r","matrix_user_id":"@new:test"}',
                200);
          }
          if (r.url.path.endsWith('account-security') && securityFail) {
            return http.Response('{}', 503);
          }
          if (r.url.path.endsWith('account-security') && noBindings) {
            return http.Response(
                '{"masked_email":"","masked_phone":"","email_bound":false,"phone_bound":false,"email_verified":false,"phone_verified":false}',
                200);
          }
          if (r.url.path.endsWith('account-security')) {
            return http.Response(
                jsonEncode({
                  'masked_email': 'a***@example.test',
                  'masked_phone': null,
                  'email_bound': true,
                  'phone_bound': false,
                  'email_verified': true,
                  'phone_verified': false
                }),
                200);
          }
          if (r.method == 'PUT' && reject) {
            return http.Response(
                '{"error":{"code":"OFFLINE","message":"保存失败"}}', 503,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          return http.Response('{"auto_allow_group_join":false}', 200);
        }));
  });
  Future<void> settle(WidgetTester tester) async {
    // The API serializes credential identity reads with durable session writes.
    // Flush that real async queue before advancing simulated animation time.
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
  }

  Future<void> submitPassword(WidgetTester tester) async {
    Finder input(String key) => find.descendant(
        of: find.byKey(Key(key)), matching: find.byType(CupertinoTextField));
    await tester.tap(find.text('账号安全'));
    await settle(tester);
    await tester.tap(find.text('更换密码'));
    await settle(tester);
    await tester.enterText(input('password-target'), 'a@example.test');
    await tester.enterText(input('password-code'), '123456');
    await tester.tap(find.byKey(const Key('password-verify')));
    await settle(tester);
    await tester.enterText(input('password-new'), 'new-password-123');
    await tester.enterText(input('password-confirmation'), 'new-password-123');
    await tester.tap(find.byKey(const Key('password-submit')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await settle(tester);
    expect(requests.where((r) => r.url.path.endsWith('/password/code/reset')),
        hasLength(1),
        reason: requests.map((r) => r.url.path).join(','));
  }

  testWidgets(
      'warm account security paints synchronously without spinner or extra GET',
      (tester) async {
    await api.loadAccountSecurity();
    final count = requests.length;
    await tester.pumpWidget(CupertinoApp(
        home: AccountSecurityPage(api: api, onPasswordChanged: () async {})));
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('a***@example.test'), findsOneWidget);
    await settle(tester);
    expect(requests.length, count);
  });
  testWidgets('warm chat setting paints confirmed switch immediately',
      (tester) async {
    await api.autoAllowGroupJoin();
    final count = requests.length;
    await tester.pumpWidget(CupertinoApp(home: ChatSettingsPage(api: api)));
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.byType(CupertinoSwitch), findsOneWidget);
    expect(tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        false);
    await settle(tester);
    expect(requests.length, count);
  });
  testWidgets(
      'pending binding stops spinner and reconciles after real response',
      (tester) async {
    await api.loadAccountSecurity();
    bindingResponse = Completer<http.Response>();
    final confirmation = api
        .confirmEmailRebind(email: 'new@example.test', code: '123456')
        .catchError((Object _) {});
    await tester.pumpWidget(CupertinoApp(
        home: AccountSecurityPage(api: api, onPasswordChanged: () async {})));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump(const Duration(seconds: 9));
    await tester.pump();
    expect(find.text('绑定结果待确认，请稍后重试'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('更换密码'), findsNothing);
    bindingResponse!.complete(http.Response('', 204));
    await settle(tester);
    await confirmation;
    expect(find.text('更换密码'), findsOneWidget);
    expect(find.text('绑定结果待确认，请稍后重试'), findsNothing);
  });
  testWidgets(
      'real API password completion emits lifecycle once without generic logout',
      (tester) async {
    var logouts = 0;
    final codes = <String>[];
    final subscription =
        api.sessionInvalidations.listen((event) => codes.add(event.code));
    addTearDown(subscription.cancel);
    await tester.pumpWidget(CupertinoApp(
        home: SettingsPage(
            api: api,
            onLogout: () async {
              logouts++;
            })));
    await submitPassword(tester);
    expect(codes, ['PASSWORD_CHANGED']);
    expect(logouts, 0);
    expect(find.byType(PasswordChangePage), findsNothing);
    expect(await api.sessionStore.session(), isNull);
  });
  testWidgets(
      'new session started during reset invalidation is preserved without stale navigation',
      (tester) async {
    var logouts = 0;
    Future<void>? newLogin;
    final subscription = api.sessionInvalidations.listen((event) {
      if (event.code == 'PASSWORD_CHANGED') {
        newLogin = api
            .login(
                username: 'new',
                password: 'new-password-123',
                deviceKey: 'new-device',
                deviceName: 'test')
            .then((_) {});
      }
    });
    addTearDown(subscription.cancel);
    await tester.pumpWidget(CupertinoApp(
        home: SettingsPage(
            api: api,
            onLogout: () async {
              logouts++;
              await Future<void>.delayed(Duration.zero);
              await api.logout();
            })));
    await submitPassword(tester);
    await newLogin;
    expect(logouts, 0);
    expect((await api.sessionStore.session())!.accessToken, 'new');
    expect(find.byType(PasswordChangePage), findsOneWidget);
  });
  testWidgets('failed binding reload hides stale actionable account rows',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: AccountSecurityPage(api: api, onPasswordChanged: () async {})));
    await settle(tester);
    await tester.tap(find.text('更换邮箱'));
    await settle(tester);
    securityFail = true;
    await tester.pageBack();
    await settle(tester);
    expect(find.text('账号信息加载失败，请重试'), findsOneWidget);
    expect(find.text('更换密码'), findsNothing);
  });
  testWidgets(
      'no verified bindings cannot start binding flows and renders missing state',
      (tester) async {
    noBindings = true;
    await tester.pumpWidget(CupertinoApp(
        home: AccountSecurityPage(api: api, onPasswordChanged: () async {})));
    await settle(tester);
    expect(find.text('未绑定'), findsNWidgets(2));
    await tester.tap(find.text('绑定邮箱'));
    await settle(tester);
    expect(find.byType(AccountSecurityPage), findsOneWidget);
    expect(find.text('当前账号没有可用的已验证联系方式，请联系客服。'), findsOneWidget);
  });
  testWidgets(
      'settings account security and general chat route to separate pages',
      (tester) async {
    await tester.pumpWidget(
        CupertinoApp(home: SettingsPage(api: api, onLogout: () async {})));
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('通用'), findsOneWidget);
    await tester.tap(find.text('账号安全'));
    await settle(tester);
    expect(find.byType(AccountSecurityPage), findsOneWidget);
    expect(find.text('a***@example.test'), findsOneWidget);
    await tester.tap(find.text('更换密码'));
    await settle(tester);
    expect(find.byType(PasswordChangePage), findsOneWidget);
  });
  testWidgets(
      'chat setting reverts failed server write and displays retryable error',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(home: ChatSettingsPage(api: api)));
    await settle(tester);
    expect(tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        isFalse);
    reject = true;
    await tester.tap(find.byType(CupertinoSwitch));
    await settle(tester);
    expect(tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        isFalse);
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(requests.last.url.path,
        '/api/v1/profile/privacy/auto-allow-group-join');
  });
  testWidgets('login forgot password opens same password page anonymously',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(home: LoginPage(api: api)));
    await settle(tester);
    await tester.tap(find.text('忘记密码'));
    await settle(tester);
    final page =
        tester.widget<PasswordChangePage>(find.byType(PasswordChangePage));
    expect(page.authenticated, false);
  });
}
