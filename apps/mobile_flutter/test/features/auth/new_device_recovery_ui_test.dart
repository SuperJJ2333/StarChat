import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'package:liuhetong_mobile/features/auth/login_page.dart';
import 'package:liuhetong_mobile/ui/components/modern_action_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> showRecovery(
    WidgetTester tester, {
    required Future<void> Function() onConfirm,
    required Future<void> Function() onCancel,
    required Future<void> Function() onAuthenticated,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(CupertinoApp(
      home: LoginPage(
        api: api,
        onLogin: (_, __) async => throw const MatrixNewDeviceRecoveryRequired(),
        onConfirmNewDeviceRecovery: onConfirm,
        onCancelNewDeviceRecovery: onCancel,
        onAuthenticated: onAuthenticated,
      ),
    ));
    await tester.enterText(
        find.byKey(const Key('auth-login-identity')), 'old-user');
    await tester.enterText(
        find.byKey(const Key('auth-login-password')), 'password');
    await tester.tap(find.byKey(const Key('auth-agreement-checkbox')));
    await tester.pump();
    final login = find.widgetWithText(ModernActionButton, '登录');
    await tester.ensureVisible(login);
    await tester.tap(login);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('cancel and system back preserve the old identity',
      (tester) async {
    var confirmations = 0;
    var cancellations = 0;
    var authenticated = 0;
    await showRecovery(
      tester,
      onConfirm: () async => confirmations++,
      onCancel: () async => cancellations++,
      onAuthenticated: () async => authenticated++,
    );

    expect(find.text('恢复聊天设备'), findsOneWidget);
    expect(find.textContaining('旧聊天记录可能无法解密'), findsOneWidget);
    expect(find.textContaining('原有本机聊天数据将保留'), findsOneWidget);
    expect(find.textContaining('清除本机聊天数据'), findsNothing);
    expect(confirmations, 0);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(cancellations, 1);
    expect(confirmations, 0);
    expect(authenticated, 0);

    final login = find.widgetWithText(ModernActionButton, '登录');
    await tester.ensureVisible(login);
    await tester.tap(login);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(cancellations, 2);
    expect(confirmations, 0);
    expect(authenticated, 0);
  });

  testWidgets('explicit confirmation establishes a new device once',
      (tester) async {
    var confirmations = 0;
    var cancellations = 0;
    var authenticated = 0;
    await showRecovery(
      tester,
      onConfirm: () async => confirmations++,
      onCancel: () async => cancellations++,
      onAuthenticated: () async => authenticated++,
    );

    await tester.tap(find.text('保留旧库并建立新设备'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(confirmations, 1);
    expect(cancellations, 0);
    expect(authenticated, 1);
  });

  testWidgets('phone login uses the same explicit recovery choice',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var confirmations = 0;
    var authenticated = 0;
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(CupertinoApp(
      home: LoginPage(
        api: api,
        onPhoneLogin: (_, __,
                {invitationCode = '',
                termsAccepted = false,
                shouldContinue}) async =>
            throw const MatrixNewDeviceRecoveryRequired(),
        onConfirmNewDeviceRecovery: () async => confirmations++,
        onAuthenticated: () async => authenticated++,
      ),
    ));
    await tester.tap(find.text('手机号登录'));
    await tester.pump();
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
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('恢复聊天设备'), findsOneWidget);
    expect(confirmations, 0);
    await tester.tap(find.text('保留旧库并建立新设备'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(confirmations, 1);
    expect(authenticated, 1);
  });
}
