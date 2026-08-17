import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/auth/registration_controller.dart';

final class FakeRegistrationGateway implements RegistrationGateway {
  bool invitationValid = true;
  int registerCalls = 0;
  int statusCalls = 0;
  Object? registerError;
  final List<String> verifiedCodes = [];
  final List<String> verifiedTokens = [];

  @override
  Future<bool> validateInvitation(String invitationCode) async =>
      invitationValid;

  @override
  Future<RegistrationReceipt> register(
      {required String username,
      required String email,
      required String password,
      required String invitationCode}) async {
    registerCalls++;
    if (registerError != null) throw registerError!;
    return const RegistrationReceipt(
        registrationSession: 'session-1',
        status: 'PENDING_EMAIL',
        resendAfterSeconds: 60);
  }

  @override
  Future<RegistrationStatusReceipt> registrationStatus(
      String registrationSession) async {
    statusCalls++;
    return RegistrationStatusReceipt(
        status: statusCalls == 1 ? 'PENDING_MATRIX' : 'ACTIVE',
        resendAfterSeconds: 0);
  }

  @override
  Future<void> verifyEmail(
      {required String registrationSession,
      String? code,
      String? token}) async {
    if (code != null) verifiedCodes.add(code);
    if (token != null) verifiedTokens.add(token);
  }

  @override
  Future<int> resendVerification(String registrationSession) async => 60;
}

void main() {
  test(
      'invitation is prevalidated before registration and starts 60 second countdown',
      () async {
    final gateway = FakeRegistrationGateway();
    final controller =
        RegistrationController(gateway: gateway, delay: (_) async {});

    expect(
        await controller.register(
            username: 'alice',
            email: 'alice@example.test',
            password: 'correct horse battery staple',
            invitationCode: 'INVITE'),
        isTrue);
    expect(gateway.registerCalls, 1);
    expect(
        controller.state.status, RegistrationFlowStatus.awaitingVerification);
    expect(controller.state.resendAfterSeconds, 60);
    controller.tickSecond();
    expect(controller.state.resendAfterSeconds, 59);
  });

  test('invalid invitation maps to a Chinese invitation field error', () async {
    final gateway = FakeRegistrationGateway()..invitationValid = false;
    final controller = RegistrationController(gateway: gateway);

    expect(
        await controller.register(
            username: 'alice',
            email: 'alice@example.test',
            password: 'correct horse battery staple',
            invitationCode: 'BAD'),
        isFalse);
    expect(gateway.registerCalls, 0);
    expect(controller.state.fieldErrors['invitation_code'], '邀请码无效或已失效');
  });

  test(
      'verification accepts either six digit code or link token then polls ACTIVE',
      () async {
    final gateway = FakeRegistrationGateway();
    final controller =
        RegistrationController(gateway: gateway, delay: (_) async {});
    await controller.register(
        username: 'alice',
        email: 'alice@example.test',
        password: 'correct horse battery staple',
        invitationCode: 'INVITE');

    await controller.verifyCode('123456');
    await controller.verifyLinkToken('signed-link-token');
    expect(gateway.verifiedCodes, ['123456']);
    expect(gateway.verifiedTokens, ['signed-link-token']);
    expect(await controller.pollUntilActive(maxAttempts: 2), isTrue);
    expect(controller.state.status, RegistrationFlowStatus.completed);
  });

  test(
      'temporary network failures retry without losing entered registration values',
      () async {
    final gateway = FakeRegistrationGateway();
    var failures = 0;
    gateway.registerError = const SocketException('offline');
    final controller = RegistrationController(
        gateway: gateway,
        delay: (_) async {
          failures++;
          if (failures == 2) gateway.registerError = null;
        });

    expect(
        await controller.register(
            username: 'alice',
            email: 'alice@example.test',
            password: 'correct horse battery staple',
            invitationCode: 'INVITE'),
        isTrue);
    expect(gateway.registerCalls, 3);
  });
}
