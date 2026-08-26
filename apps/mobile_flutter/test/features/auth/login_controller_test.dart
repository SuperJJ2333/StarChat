import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/business_api_client.dart';

void main() {
  test('network failures are retried up to three attempts', () async {
    var attempts = 0;
    final controller = LoginController(
        operation: (_, __) async {
          attempts++;
          if (attempts < 3) throw const SocketException('offline');
        },
        delay: (_) => Future.value());
    await controller.submit('user', 'password');
    expect(attempts, 3);
    expect(controller.state.status, LoginStatus.succeeded);
  });
  test('authentication failure is not retried', () async {
    var attempts = 0;
    final controller = LoginController(
        operation: (_, __) async {
          attempts++;
          throw const LoginAuthenticationException();
        },
        delay: (_) => Future.value());
    await controller.submit('user', 'wrong');
    expect(attempts, 1);
    expect(controller.state.message, '用户名或密码错误');
  });
  test('business API 401 is shown as username or password error', () async {
    var attempts = 0;
    final controller = LoginController(
        operation: (_, __) async {
          attempts++;
          throw const BusinessApiException(
              statusCode: 401,
              code: 'CREDENTIALS_INVALID',
              message: '用户名或密码错误');
        },
        delay: (_) => Future.value());
    await controller.submit('missing', 'wrong');
    expect(attempts, 1);
    expect(controller.state.message, '用户名或密码错误');
  });
  test('http connection reset is shown as a friendly network failure',
      () async {
    var attempts = 0;
    final controller = LoginController(
        operation: (_, __) async {
          attempts++;
          throw http.ClientException('Connection reset by peer');
        },
        delay: (_) => Future.value());
    await controller.submit('user', 'password');
    expect(attempts, 3);
    expect(controller.state.message, '网络连接不稳定，请重试');
  });

  test('same Matrix identity is reused without token exchange', () async {
    final business = FakeDualDomainBusiness();
    final matrix = FakeMatrixTokenLogin(isLoggedIn: true);
    final controller = LoginController.dualDomain(
        business: business, matrix: matrix, deviceKey: () => 'device-1');

    expect(await controller.submit('alice', 'business-password'), isTrue);
    expect(business.loginPasswords, ['business-password']);
    expect(business.tokenRequests, 0);
    expect(matrix.clears, 0);
    expect(matrix.tokens, isEmpty);
  });

  test('different Matrix identity fails closed before requesting a token',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
      ..userId = '@bob:matrix.example.test';
    final service = DualDomainLoginService(
        business: business, matrix: matrix, deviceKey: () => 'device-1');

    await expectLater(
      service.login('alice', 'business-password'),
      throwsA(isA<MatrixAccountSwitchRequired>()),
    );

    expect(business.tokenRequests, 0);
    expect(matrix.clears, 0);
  });

  test('invalid same-device Matrix credentials are refreshed non-destructively',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
      ..credentialsInvalid = true;
    final controller = LoginController.dualDomain(
        business: business, matrix: matrix, deviceKey: () => 'device-1');

    expect(await controller.submit('alice', 'business-password'), isTrue);

    expect(matrix.tokens, ['one-time-login-token']);
    expect(matrix.loginDeviceIds, ['DEVICE']);
    expect(matrix.credentialsInvalid, isFalse);
    expect(matrix.clears, 0);
  });

  test('different Matrix identity fails closed without clearing local data',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
      ..userId = '@bob:matrix.example.test';
    final service = DualDomainLoginService(
        business: business, matrix: matrix, deviceKey: () => 'device-1');
    await expectLater(
        service.login('alice', 'business-password'),
        throwsA(isA<MatrixAccountSwitchRequired>()));
    expect(matrix.clears, 0);
    expect(matrix.suspends, 1);
    expect(matrix.tokens, isEmpty);
    expect(business.logouts, 1);
  });

  test('dual-domain login failure suspends Matrix without clearing it',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = FakeMatrixTokenLogin(isLoggedIn: false)..failSync = true;
    final service = DualDomainLoginService(
        business: business, matrix: matrix, deviceKey: () => 'device-1');

    await expectLater(
        service.login('alice', 'business-password'), throwsStateError);
    expect(business.logouts, 1);
    expect(matrix.suspends, 1);
    expect(matrix.clears, 0);
    expect(matrix.isLoggedIn, isTrue);
  });

  test(
      'dual-domain login exchanges a one-time token and never gives Matrix the Business password',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = FakeMatrixTokenLogin(isLoggedIn: false);
    final controller = LoginController.dualDomain(
        business: business, matrix: matrix, deviceKey: () => 'device-1');

    expect(await controller.submit('alice', 'business-password'), isTrue);
    expect(business.tokenRequests, 1);
    expect(matrix.tokens, ['one-time-login-token']);
    expect(matrix.homeservers, ['https://matrix.example.test']);
    expect(matrix.tokens, isNot(contains('business-password')));
    expect(business.boundMatrixUsers, ['@alice:matrix.example.test']);
  });
}

final class FakeDualDomainBusiness implements DualDomainBusinessGateway {
  final List<String> loginPasswords = [];
  int tokenRequests = 0;
  final List<String> boundMatrixUsers = [];
  int logouts = 0;
  @override
  Future<String?> currentMatrixUserId() async =>
      '@alice:matrix.example.test';
  @override
  Future<void> loginBusiness(
      {required String username,
      required String password,
      required String deviceKey,
      required String deviceName}) async {
    loginPasswords.add(password);
  }

  @override
  Future<MatrixLoginGrant> issueMatrixLoginToken() async {
    tokenRequests++;
    return const MatrixLoginGrant(
        loginToken: 'one-time-login-token',
        homeserver: 'https://matrix.example.test',
        expiresIn: 60,
        matrixUserId: '@alice:matrix.example.test');
  }

  @override
  Future<void> bindMatrixUserId(String matrixUserId) async {
    boundMatrixUsers.add(matrixUserId);
  }

  @override
  Future<void> logoutBusiness() async {
    logouts++;
  }
}

final class FakeMatrixTokenLogin implements MatrixTokenLoginGateway {
  FakeMatrixTokenLogin({required this.isLoggedIn});
  @override
  bool isLoggedIn;
  @override
  bool credentialsInvalid = false;
  @override
  String? userId = '@alice:matrix.example.test';
  @override
  String? deviceId = 'DEVICE';
  final List<String> tokens = [];
  final List<String> homeservers = [];
  final List<String?> loginDeviceIds = [];
  int clears = 0;
  int suspends = 0;
  bool failSync = false;
  @override
  Future<void> loginWithToken(
      {required String loginToken,
      required Uri homeserver,
      String? deviceId}) async {
    tokens.add(loginToken);
    homeservers.add(homeserver.toString());
    loginDeviceIds.add(deviceId);
    isLoggedIn = true;
    credentialsInvalid = false;
    userId = '@alice:matrix.example.test';
  }

  @override
  Future<void> sync() async {
    if (failSync) throw StateError('sync failed');
  }

  @override
  Future<void> clearLocalChatData() async {
    clears++;
    isLoggedIn = false;
    userId = null;
  }

  @override
  Future<void> suspend() async => suspends++;
}
