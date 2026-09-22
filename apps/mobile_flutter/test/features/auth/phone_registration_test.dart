import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/core/business_phone_contracts.dart';
import 'package:liuhetong_mobile/features/auth/registration_controller.dart';

class Gateway implements RegistrationGateway, PhoneAuthGateway {
  int verifies = 0;
  int sends = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<InvitationValidationResult> validateInvitation(String code) async =>
      const InvitationValidationResult(InvitationValidationState.ready, 'OK');
  @override
  Future<RegistrationPhoneReceipt> registerWithPhone(
          {required String username,
          String? nickname,
          required String phone,
          required String password,
          required String invitationCode}) async =>
      const RegistrationPhoneReceipt(
          registrationSession: 'session',
          status: 'PENDING_PHONE',
          resendAfterSeconds: 0);
  @override
  Future<void> requestRegistrationOtp(String session) async {
    sends++;
  }

  @override
  Future<void> verifyRegistrationPhone(
      {required String registrationSession,
      required String phone,
      required String code}) async {
    verifies++;
    throw TimeoutException('response lost');
  }

  @override
  Future<RegistrationStatusReceipt> registrationStatus(String session) async =>
      const RegistrationStatusReceipt(status: 'ACTIVE', resendAfterSeconds: 0);
}

void main() {
  test('phone verify lost response recovers by status without replaying OTP',
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
            invitationCode: 'invite'),
        isTrue);
    await controller.verifyCode('123456');
    expect(controller.state.status, RegistrationFlowStatus.completed);
    expect(gateway.verifies, 1);
    expect(gateway.sends, 1);
  });
}
