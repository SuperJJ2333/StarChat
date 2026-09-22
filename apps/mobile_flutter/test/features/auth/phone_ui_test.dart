import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_page.dart';
import 'package:liuhetong_mobile/ui/components/modern_action_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      'phone host login completes before authentication callback and is never auto retried',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final pending = Completer<void>();
    var calls = 0;
    var authenticated = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore());
    await tester.pumpWidget(CupertinoApp(
        home: LoginPage(
            api: api,
            onPhoneLogin: (phone, code) async {
              calls++;
              await pending.future;
            },
            onAuthenticated: () async {
              authenticated++;
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手机号登录'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('auth-login-phone')), '13800000001');
    await tester.enterText(find.byKey(const Key('auth-login-code')), '123456');
    final agreement = find.byKey(const Key('auth-agreement-checkbox'));
    await tester.ensureVisible(agreement);
    await tester.tap(agreement);
    await tester.pump();
    final login = find.widgetWithText(ModernActionButton, '登录');
    await tester.ensureVisible(login);
    await tester.tap(login);
    await tester.pump();
    expect(calls, 1);
    expect(authenticated, 0);
    pending.complete();
    await tester.pumpAndSettle();
    expect(authenticated, 1);
    expect(calls, 1);
  });
  testWidgets('phone login is explicit and mounting sends no SMS',
      (tester) async {
    var calls = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore(),
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(home: LoginPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('手机号登录'), findsOneWidget);
    await tester.tap(find.text('手机号登录'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auth-login-phone')), findsOneWidget);
    expect(find.byKey(const Key('auth-login-code')), findsOneWidget);
    expect(calls, 0);
  });
}
