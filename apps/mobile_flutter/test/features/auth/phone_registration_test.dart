import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/core/business_phone_contracts.dart';
import 'package:liuhetong_mobile/features/auth/registration_controller.dart';
import 'package:liuhetong_mobile/features/auth/registration_page.dart';

class Gateway implements RegistrationGateway, PhoneAuthGateway {
  int verifies = 0;
  int sends = 0;
  int registrations = 0;
  String? registeredPhone;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<InvitationValidationResult> validateInvitation(String code) async =>
      const InvitationValidationResult(InvitationValidationState.ready, 'OK');
  @override
  Future<RegistrationPhoneReceipt> registerWithPhone({
    required String username,
    String? nickname,
    required String phone,
    required String password,
    required String invitationCode,
  }) async {
    registrations++;
    registeredPhone = phone;
    return const RegistrationPhoneReceipt(
      registrationSession: 'session',
      status: 'PENDING_PHONE',
      resendAfterSeconds: 0,
    );
  }

  @override
  Future<void> requestRegistrationOtp(String session) async {
    sends++;
  }

  @override
  Future<void> verifyRegistrationPhone({
    required String registrationSession,
    required String phone,
    required String code,
  }) async {
    verifies++;
    throw TimeoutException('response lost');
  }

  @override
  Future<RegistrationStatusReceipt> registrationStatus(String session) async =>
      const RegistrationStatusReceipt(status: 'ACTIVE', resendAfterSeconds: 0);
}

void main() {
  testWidgets('phone registration request validates directly below phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final gateway = Gateway();
    final controller = RegistrationController(gateway: gateway);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      CupertinoApp(
        home: RegistrationPage(
          controller: controller,
          onVerification: (_) {},
          onBack: () {},
        ),
      ),
    );
    await tester.tap(find.text('手机号注册'));
    await tester.pump();
    final action = find.byKey(const Key('auth-registration-send-code'));
    expect(tester.widget<CupertinoButton>(action).onPressed, isNotNull);
    await tester.enterText(
      find.byKey(const Key('auth-registration-phone')),
      '123',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    await tester.tap(action);
    await tester.pump();
    final error = find.byKey(const Key('auth-registration-error-phone'));
    final phone = find.byKey(const Key('auth-registration-phone'));
    expect(error, findsOneWidget);
    expect(
      find.byKey(const Key('auth-registration-error-username')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('auth-registration-error-password')),
      findsNothing,
    );
    expect(
      tester.getTopLeft(error).dy,
      greaterThan(tester.getBottomLeft(phone).dy),
    );
    expect(gateway.registrations, 0);
    expect(gateway.sends, 0);
    await tester.enterText(phone, '13800000001');
    await tester.pump();
    expect(error, findsNothing);
    expect(
      find.byKey(const Key('auth-registration-phone-valid')),
      findsOneWidget,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    await tester.tap(action);
    await tester.pump();
    expect(
      find.byKey(const Key('auth-registration-phone-valid')),
      findsOneWidget,
    );
  });
  testWidgets(
    'phone registration accepts +86 formatted input and normalizes it',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final gateway = Gateway();
      final controller = RegistrationController(gateway: gateway);
      await tester.pumpWidget(
        CupertinoApp(
          home: RegistrationPage(
            controller: controller,
            onVerification: (_) {},
            onBack: () {},
          ),
        ),
      );
      await tester.tap(find.text('手机号注册'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('auth-registration-nickname')),
        'Alice',
      );
      await tester.enterText(
        find.byKey(const Key('auth-registration-username')),
        'alice',
      );
      await tester.enterText(
        find.byKey(const Key('auth-registration-password')),
        'correct horse battery staple',
      );
      await tester.enterText(
        find.byKey(const Key('auth-registration-password-confirm')),
        'correct horse battery staple',
      );
      await tester.enterText(
        find.byKey(const Key('auth-registration-invitation')),
        'INVITE',
      );
      final phone = find.byKey(const Key('auth-registration-phone'));
      await tester.enterText(phone, '+86 138 0000 0001');
      FocusManager.instance.primaryFocus?.unfocus();
      final action = find.byKey(const Key('auth-registration-send-code'));
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pump();
      expect(
        find.byKey(const Key('auth-registration-error-phone')),
        findsNothing,
      );
      expect(gateway.registeredPhone, '13800000001');
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
      controller.dispose();
    },
  );
  testWidgets('pending phone registration locks the OTP destination', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final gateway = Gateway();
    final controller = RegistrationController(gateway: gateway);
    expect(
      await controller.register(
        username: 'alice',
        nickname: 'Alice',
        email: '',
        phone: '13800000001',
        password: 'correct horse battery staple',
        passwordConfirmation: 'correct horse battery staple',
        invitationCode: 'INVITE',
      ),
      isTrue,
    );
    await tester.pumpWidget(
      CupertinoApp(
        home: RegistrationPage(
          controller: controller,
          onVerification: (_) {},
          onBack: () {},
        ),
      ),
    );
    final input = tester.widget<CupertinoTextField>(
      find.descendant(
        of: find.byKey(const Key('auth-registration-phone')),
        matching: find.byType(CupertinoTextField),
      ),
    );
    expect(input.enabled, isTrue);
    expect(input.readOnly, isTrue);
    final resend = find.byKey(const Key('auth-registration-send-code'));
    expect(gateway.sends, 1);
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    await tester.ensureVisible(resend);
    await tester.pumpAndSettle();
    expect(tester.widget<CupertinoButton>(resend).onPressed, isNotNull);
    await tester.tap(resend);
    await tester.pump();
    expect(gateway.sends, 2);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    controller.dispose();
  });
  test(
    'phone verify lost response recovers by status without replaying OTP',
    () async {
      final gateway = Gateway();
      final controller = RegistrationController(gateway: gateway);
      addTearDown(controller.dispose);
      final dynamic flow = controller;
      expect(
        await flow.register(
          username: 'alice',
          nickname: 'Alice',
          email: '',
          phone: '13800000001',
          password: 'passwordlong12',
          invitationCode: 'invite',
        ),
        isTrue,
      );
      await controller.verifyCode('123456');
      expect(controller.state.status, RegistrationFlowStatus.completed);
      expect(gateway.verifies, 1);
      expect(gateway.sends, 1);
    },
  );
}
