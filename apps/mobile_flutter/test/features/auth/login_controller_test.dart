import 'dart:io';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';

void main() {
  test('cancel holds operation guard until local logout completes', () async {
    final business = FakeDualDomainBusiness()..logoutGate = Completer<void>();
    final service = DualDomainLoginService(
        business: business,
        matrix: FakeMatrixTokenLogin(isLoggedIn: false),
        deviceKey: () => 'device');
    final cancellation = service.cancelAccountSwitch();
    await expectLater(service.login('alice', 'password'),
        throwsA(isA<BusinessApiException>()));
    expect(business.loginPasswords, isEmpty);
    business.logoutGate!.complete();
    await cancellation;
  });

  test('expired pending grant is replaced before confirmed clear', () async {
    var clock = DateTime.utc(2026, 9, 9);
    final business = FakeDualDomainBusiness()..currentIdentity = null;
    final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
      ..userId = '@bob:matrix.example.test';
    final service = DualDomainLoginService(
        business: business,
        matrix: matrix,
        deviceKey: () => 'device',
        now: () => clock);
    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixAccountSwitchRequired>()));
    clock = clock.add(const Duration(seconds: 61));
    await service.confirmAccountSwitchAndLogin();
    expect(business.tokenRequests, 2);
    expect(matrix.clears, 1);
  });
  test('cancel invalidates pending grant and cannot clear old account',
      () async {
    final business = FakeDualDomainBusiness()..currentIdentity = null;
    final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
      ..userId = '@bob:matrix.example.test';
    final service = DualDomainLoginService(
        business: business, matrix: matrix, deviceKey: () => 'device');
    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixAccountSwitchRequired>()));
    await service.cancelAccountSwitch();
    await expectLater(service.confirmAccountSwitchAndLogin(), throwsStateError);
    expect(matrix.clears, 0);
    expect(business.logouts, 1);
  });
  test('first failure reports sync stage even when compensating logout fails',
      () async {
    final business = FakeDualDomainBusiness()..failLogout = true;
    final matrix = FakeMatrixTokenLogin(isLoggedIn: false)..failSync = true;
    final service = DualDomainLoginService(
        business: business, matrix: matrix, deviceKey: () => 'device');
    final controller = LoginController(operation: service.login);
    expect(await controller.submit('alice', 'secret-password'), isFalse);
    expect(controller.state.message, contains('L05'));
    expect(controller.state.message, isNot(contains('secret-password')));
    expect(business.tokenRequests, 1);
    expect(matrix.suspends, 1);
  });
  test('unknown-outcome token consumption cannot reuse pending grant',
      () async {
    final business = FakeDualDomainBusiness()..currentIdentity = null;
    final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
      ..userId = '@bob:matrix.example.test'
      ..failLogin = true;
    final service = DualDomainLoginService(
        business: business, matrix: matrix, deviceKey: () => 'device');
    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixAccountSwitchRequired>()));
    await expectLater(service.confirmAccountSwitchAndLogin(),
        throwsA(isA<LoginStageException>()));
    await expectLater(service.confirmAccountSwitchAndLogin(), throwsStateError);
    expect(business.tokenRequests, 1);
    expect(matrix.tokens, hasLength(1));
    expect(business.logouts, 0);
  });

  test('legacy unknown identity switch consumes its initial grant only once',
      () async {
    final business = FakeDualDomainBusiness()..currentIdentity = null;
    final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
      ..userId = '@bob:matrix.example.test';
    final service = DualDomainLoginService(
        business: business, matrix: matrix, deviceKey: () => 'device');
    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixAccountSwitchRequired>()));
    await service.confirmAccountSwitchAndLogin();
    expect(business.tokenRequests, 1);
    expect(matrix.clears, 1);
    expect(matrix.tokens, hasLength(1));
  });

  test(
      'concurrent login attempts cannot perform duplicate password or grant exchange',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = FakeMatrixTokenLogin(isLoggedIn: false);
    final service = DualDomainLoginService(
        business: business, matrix: matrix, deviceKey: () => 'device');
    final first = service.login('alice', 'password');
    await expectLater(service.login('alice', 'password'),
        throwsA(isA<BusinessApiException>()));
    await first;
    expect(business.loginPasswords, hasLength(1));
    expect(business.tokenRequests, 1);
  });

  test('network failures are retried up to three attempts', () async {
    var attempts = 0;
    final controller = LoginController(
      operation: (_, __) async {
        attempts++;
        if (attempts < 3) throw const SocketException('offline');
      },
      delay: (_) => Future.value(),
    );
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
      delay: (_) => Future.value(),
    );
    await controller.submit('user', 'wrong');
    expect(attempts, 1);
    expect(controller.state.message, '账号或密码错误');
  });
  test('business API 401 is shown as username or password error', () async {
    var attempts = 0;
    final controller = LoginController(
      operation: (_, __) async {
        attempts++;
        throw const BusinessApiException(
          statusCode: 401,
          code: 'CREDENTIALS_INVALID',
          message: '账号或密码错误',
        );
      },
      delay: (_) => Future.value(),
    );
    await controller.submit('missing', 'wrong');
    expect(attempts, 1);
    expect(controller.state.message, '账号或密码错误');
  });
  test(
    'http connection reset is shown as a friendly network failure',
    () async {
      var attempts = 0;
      final controller = LoginController(
        operation: (_, __) async {
          attempts++;
          throw http.ClientException('Connection reset by peer');
        },
        delay: (_) => Future.value(),
      );
      await controller.submit('user', 'password');
      expect(attempts, 3);
      expect(controller.state.message, '网络连接不稳定，请重试');
    },
  );

  test('same Matrix identity is reused without token exchange', () async {
    final business = FakeDualDomainBusiness();
    final matrix = FakeMatrixTokenLogin(isLoggedIn: true);
    final controller = LoginController.dualDomain(
      business: business,
      matrix: matrix,
      deviceKey: () => 'device-1',
    );

    expect(await controller.submit('alice', 'business-password'), isTrue);
    expect(business.loginPasswords, ['business-password']);
    expect(business.tokenRequests, 0);
    expect(matrix.clears, 0);
    expect(matrix.tokens, isEmpty);
  });

  test(
    'different Matrix identity reports both identities without clearing',
    () async {
      final business = FakeDualDomainBusiness();
      final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
        ..userId = '@bob:matrix.example.test';
      final service = DualDomainLoginService(
        business: business,
        matrix: matrix,
        deviceKey: () => 'device-1',
      );

      await expectLater(
        service.login('alice', 'business-password'),
        throwsA(
          isA<MatrixAccountSwitchRequired>()
              .having(
                (error) => error.fromMxid,
                'fromMxid',
                '@bob:matrix.example.test',
              )
              .having(
                (error) => error.toMxid,
                'toMxid',
                '@alice:matrix.example.test',
              ),
        ),
      );

      expect(business.tokenRequests, 0);
      expect(matrix.clears, 0);
      expect(matrix.suspends, 0);
      expect(business.logouts, 0);
    },
  );

  test(
    'invalid same-device Matrix credentials are refreshed non-destructively',
    () async {
      final business = FakeDualDomainBusiness();
      final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
        ..credentialsInvalid = true;
      final controller = LoginController.dualDomain(
        business: business,
        matrix: matrix,
        deviceKey: () => 'device-1',
      );

      expect(await controller.submit('alice', 'business-password'), isTrue);

      expect(matrix.tokens, ['one-time-login-token']);
      expect(matrix.loginDeviceIds, ['DEVICE']);
      expect(matrix.credentialsInvalid, isFalse);
      expect(matrix.clears, 0);
    },
  );

  test(
    'confirmed account switch requests a fresh target token then clears once',
    () async {
      final business = FakeDualDomainBusiness();
      final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
        ..userId = '@bob:matrix.example.test';
      final service = DualDomainLoginService(
        business: business,
        matrix: matrix,
        deviceKey: () => 'device-1',
      );
      await expectLater(
        service.login('alice', 'business-password'),
        throwsA(isA<MatrixAccountSwitchRequired>()),
      );

      await service.confirmAccountSwitchAndLogin();

      expect(business.tokenRequests, 1);
      expect(matrix.clears, 1);
      expect(matrix.loginDeviceIds, [null]);
      expect(matrix.userId, '@alice:matrix.example.test');
      expect(business.boundMatrixUsers, ['@alice:matrix.example.test']);
    },
  );

  test(
    'changed token target aborts confirmed switch before deletion',
    () async {
      final business = FakeDualDomainBusiness()
        ..grants.add(
          const MatrixLoginGrant(
            loginToken: 'different-target-token',
            homeserver: 'https://matrix.example.test',
            expiresIn: 60,
            matrixUserId: '@carol:matrix.example.test',
          ),
        );
      final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
        ..userId = '@bob:matrix.example.test';
      final service = DualDomainLoginService(
        business: business,
        matrix: matrix,
        deviceKey: () => 'device-1',
      );

      await expectLater(
        service.login('alice', 'business-password'),
        throwsA(isA<MatrixAccountSwitchRequired>()),
      );
      await expectLater(
        service.confirmAccountSwitchAndLogin(),
        throwsStateError,
      );

      expect(business.tokenRequests, 1);
      expect(matrix.clears, 0);
      expect(matrix.tokens, isEmpty);
      expect(matrix.userId, '@bob:matrix.example.test');
    },
  );

  test('token failure aborts confirmed switch before deletion', () async {
    final business = FakeDualDomainBusiness()..failTokenRequest = true;
    final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
      ..userId = '@bob:matrix.example.test';
    final service = DualDomainLoginService(
      business: business,
      matrix: matrix,
      deviceKey: () => 'device-1',
    );

    await expectLater(
      service.login('alice', 'business-password'),
      throwsA(isA<MatrixAccountSwitchRequired>()),
    );
    await expectLater(service.confirmAccountSwitchAndLogin(),
        throwsA(isA<LoginStageException>()));

    expect(matrix.clears, 0);
    expect(matrix.tokens, isEmpty);
  });

  test(
    'dual-domain login failure suspends Matrix without clearing it',
    () async {
      final business = FakeDualDomainBusiness();
      final matrix = FakeMatrixTokenLogin(isLoggedIn: false)..failSync = true;
      final service = DualDomainLoginService(
        business: business,
        matrix: matrix,
        deviceKey: () => 'device-1',
      );

      await expectLater(
        service.login('alice', 'business-password'),
        throwsA(isA<LoginStageException>()),
      );
      expect(business.logouts, 1);
      expect(matrix.suspends, 1);
      expect(matrix.clears, 0);
      expect(matrix.isLoggedIn, isTrue);
    },
  );

  test(
    'dual-domain login exchanges a one-time token and never gives Matrix the Business password',
    () async {
      final business = FakeDualDomainBusiness();
      final matrix = FakeMatrixTokenLogin(isLoggedIn: false);
      final controller = LoginController.dualDomain(
        business: business,
        matrix: matrix,
        deviceKey: () => 'device-1',
      );

      expect(await controller.submit('alice', 'business-password'), isTrue);
      expect(business.tokenRequests, 1);
      expect(matrix.tokens, ['one-time-login-token']);
      expect(matrix.homeservers, ['https://matrix.example.test']);
      expect(matrix.tokens, isNot(contains('business-password')));
      expect(business.boundMatrixUsers, ['@alice:matrix.example.test']);
    },
  );
}

final class FakeDualDomainBusiness implements DualDomainBusinessGateway {
  final List<String> loginPasswords = [];
  int tokenRequests = 0;
  final List<String> boundMatrixUsers = [];
  int logouts = 0;
  bool failTokenRequest = false;
  bool failLogout = false;
  Completer<void>? logoutGate;
  final List<MatrixLoginGrant> grants = [];
  String? currentIdentity = "@alice:matrix.example.test";
  @override
  Future<String?> currentMatrixUserId() async => currentIdentity;
  @override
  Future<void> loginBusiness({
    required String username,
    required String password,
    required String deviceKey,
    required String deviceName,
  }) async {
    loginPasswords.add(password);
  }

  @override
  Future<MatrixLoginGrant> issueMatrixLoginToken() async {
    tokenRequests++;
    if (failTokenRequest) throw StateError('token unavailable');
    if (grants.isNotEmpty) return grants.removeAt(0);
    return const MatrixLoginGrant(
      loginToken: 'one-time-login-token',
      homeserver: 'https://matrix.example.test',
      expiresIn: 60,
      matrixUserId: '@alice:matrix.example.test',
    );
  }

  @override
  Future<void> bindMatrixUserId(String matrixUserId) async {
    boundMatrixUsers.add(matrixUserId);
  }

  @override
  Future<void> logoutBusiness() async {
    logouts++;
    await logoutGate?.future;
    if (failLogout) throw StateError("compensation failure");
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
  bool failLogin = false;
  @override
  Future<void> loginWithToken({
    required String loginToken,
    required Uri homeserver,
    String? deviceId,
  }) async {
    tokens.add(loginToken);
    if (failLogin) throw const SocketException("uncertain response");
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
