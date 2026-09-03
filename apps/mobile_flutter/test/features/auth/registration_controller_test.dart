import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/features/auth/registration_controller.dart';

final class FakeRegistrationGateway implements RegistrationGateway {
  bool invitationValid = true;
  int registerCalls = 0;
  int statusCalls = 0;
  Object? registerError;
  Object? verifyError;
  final List<String> verifiedCodes = [];
  final List<String> verifiedTokens = [];

  @override
  Future<InvitationValidationResult> validateInvitation(
          String invitationCode) async =>
      invitationValid
          ? const InvitationValidationResult(
              InvitationValidationState.ready, '邀请码可用')
          : const InvitationValidationResult(
              InvitationValidationState.invalid, '邀请码无效');

  @override
  Future<RegistrationReceipt> register(
      {required String username,
      String? nickname,
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
    if (verifyError != null) throw verifyError!;
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
    expect(controller.state.fieldErrors['invitation_code'], '邀请码无效');
  });

  test('registration validates username email and password before network',
      () async {
    final gateway = FakeRegistrationGateway();
    final controller = RegistrationController(gateway: gateway);

    expect(
      await controller.register(
        username: 'ab',
        email: 'not-an-email',
        password: 'short',
        passwordConfirmation: 'different',
        invitationCode: '',
      ),
      isFalse,
    );
    expect(gateway.registerCalls, 0);
    expect(controller.state.fieldErrors['username'], isNotNull);
    expect(controller.state.fieldErrors['email'], '请输入有效的邮箱地址');
    expect(controller.state.fieldErrors['password'], '密码至少需要 12 位');
    expect(controller.state.fieldErrors['password_confirmation'], '两次密码输入不一致');
    expect(controller.state.fieldErrors['invitation_code'], '请输入邀请码');
  });

  test('registration keeps server validation fields attached to their inputs',
      () async {
    final gateway = FakeRegistrationGateway()
      ..registerError = const BusinessApiException(
          statusCode: 422,
          code: 'VALIDATION_ERROR',
          message: '请求参数校验失败',
          fieldErrors: {'email': '邮箱格式无效'});
    final controller = RegistrationController(gateway: gateway);

    expect(
      await controller.register(
        nickname: '昵称',
        username: 'chat-id',
        email: 'valid@example.com',
        password: 'correct horse battery staple',
        passwordConfirmation: 'correct horse battery staple',
        invitationCode: 'INVITE',
      ),
      isFalse,
    );
    expect(controller.state.fieldErrors, {'email': '邮箱格式无效'});
  });

  test('registration conflict assigns the single error to email only',
      () async {
    final gateway = FakeRegistrationGateway()
      ..registerError = const BusinessApiException(
          statusCode: 409,
          code: 'REGISTRATION_CONFLICT',
          message: '用户名或邮箱已被使用');
    final controller = RegistrationController(gateway: gateway);

    await controller.register(
      nickname: '昵称',
      username: 'chat-id',
      email: 'taken@example.com',
      password: 'correct horse battery staple',
      passwordConfirmation: 'correct horse battery staple',
      invitationCode: 'INVITE',
    );

    expect(controller.state.fieldErrors, {'email': '邮箱已被使用'});
  });

  test('verification accepts an email code or link token then polls ACTIVE',
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

  test('verification code error is stored and can be cleared', () async {
    final gateway = FakeRegistrationGateway()
      ..verifyError = const BusinessApiException(
        statusCode: 422,
        code: 'EMAIL_VERIFICATION_CODE_INVALID',
        message: '验证码无效',
      );
    final controller = RegistrationController(gateway: gateway);
    await controller.register(
      username: 'alice',
      email: 'alice@example.test',
      password: 'correct horse battery staple',
      invitationCode: 'INVITE',
    );

    await controller.verifyCode('000000');

    expect(controller.state.fieldErrors['code'], '验证码错误，请重新输入');
    expect(controller.state.registrationSession, 'session-1');
    controller.clearVerificationCodeError();
    expect(controller.state.fieldErrors.containsKey('code'), isFalse);
    expect(controller.state.registrationSession, 'session-1');
  });

  test('short verification code is submitted without a client-side length rule',
      () async {
    final controller =
        RegistrationController(gateway: FakeRegistrationGateway());
    await controller.register(
      username: 'alice',
      email: 'alice@example.test',
      password: 'correct horse battery staple',
      invitationCode: 'INVITE',
    );

    await controller.verifyCode('123');

    expect(controller.state.fieldErrors, isEmpty);
    expect(controller.state.status, RegistrationFlowStatus.provisioning);
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

  // 统一邀请码（规格 §6.2）：注册只有一个邀请码字段；邀请关系由服务端
  // 按"注册消耗了谁的邀请码"推导，客户端不再提交独立的推荐码。
  test('register submits with the single invitation code only', () async {
    final gateway = FakeRegistrationGateway();
    final controller = RegistrationController(gateway: gateway);

    expect(
        await controller.register(
            username: 'alice',
            email: 'alice@example.test',
            password: 'correct horse battery staple',
            invitationCode: 'AB2CD3FG'),
        isTrue);
    expect(gateway.registerCalls, 1);
    expect(
        controller.state.status, RegistrationFlowStatus.awaitingVerification);
  });
}
