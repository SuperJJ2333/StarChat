import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';

import 'login_controller_test.dart' show FakeDualDomainBusiness;

final class _RecoverableMatrix
    implements
        MatrixTokenLoginGateway,
        MatrixAccountSelectionGateway,
        MatrixNewDeviceRecoveryGateway,
        MatrixExpectedIdentityTokenLoginGateway {
  @override
  bool isLoggedIn = false;
  @override
  bool credentialsInvalid = false;
  @override
  String? userId;
  @override
  String? deviceId;

  int selections = 0;
  int recoveries = 0;
  int suspends = 0;
  int clears = 0;
  int logins = 0;
  bool offerRecoveryOnSelect = true;
  final loginDeviceIds = <String?>[];
  final expectedLoginUserIds = <String>[];
  final operations = <String>[];
  bool failRecovery = false;
  Completer<void>? recoveryGate;
  Object? loginError;
  String loginResultUserId = '@alice:matrix.example.test';

  @override
  Future<void> selectAccount(String matrixUserId, Uri homeserver) async {
    selections++;
    operations.add('select');
    if (offerRecoveryOnSelect && selections == 1) {
      throw const MatrixNewDeviceRecoveryRequired();
    }
    userId = null;
    deviceId = null;
  }

  @override
  Future<void> confirmNewDeviceRecovery(
      String matrixUserId, Uri homeserver) async {
    recoveries++;
    operations.add('archive');
    if (failRecovery) throw StateError('archive unavailable');
    await recoveryGate?.future;
    userId = null;
    deviceId = null;
  }

  @override
  Future<void> loginWithToken({
    required String loginToken,
    required Uri homeserver,
    String? deviceId,
  }) async {
    logins++;
    operations.add('login');
    loginDeviceIds.add(deviceId);
    if (loginError != null) throw loginError!;
    userId = loginResultUserId;
    this.deviceId = 'NEW-DEVICE';
    isLoggedIn = true;
  }

  @override
  Future<void> loginWithTokenForExpectedIdentity({
    required String expectedMatrixUserId,
    required String loginToken,
    required Uri homeserver,
    String? deviceId,
  }) async {
    expectedLoginUserIds.add(expectedMatrixUserId);
    await loginWithToken(
        loginToken: loginToken, homeserver: homeserver, deviceId: deviceId);
  }

  @override
  Future<void> sync() async => operations.add('sync');

  @override
  Future<void> suspend() async {
    suspends++;
    operations.add('suspend');
  }

  @override
  Future<void> clearLocalChatData() async => clears++;
}

DualDomainLoginService _service(
        FakeDualDomainBusiness business, _RecoverableMatrix matrix) =>
    DualDomainLoginService(
      business: business,
      matrix: matrix,
      deviceKey: () => 'installation',
      retainedHomeserver: Uri.parse('https://matrix.example.test'),
    );

void main() {
  test('ordinary blank selected scope carries the broker MXID into login',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = _RecoverableMatrix()..offerRecoveryOnSelect = false;
    final service = _service(business, matrix);

    await service.login('alice', 'password');
    expect(matrix.expectedLoginUserIds, ['@alice:matrix.example.test']);
    expect(matrix.loginDeviceIds, [null]);
  });
  test('retained account checks broker identity before opening local storage',
      () async {
    final business = FakeDualDomainBusiness()
      ..grants.add(const MatrixLoginGrant(
        loginToken: 'wrong-target',
        homeserver: 'https://matrix.example.test',
        expiresIn: 60,
        matrixUserId: '@mallory:matrix.example.test',
      ));
    final matrix = _RecoverableMatrix();
    final service = _service(business, matrix);

    await expectLater(
        service.restoreAuthenticatedSession('@alice:matrix.example.test'),
        throwsA(isA<Exception>()));
    expect(business.tokenRequests, 1);
    expect(matrix.selections, 0);
    expect(matrix.recoveries, 0);
    expect(matrix.logins, 0);
  });

  test('retained account checks broker homeserver before storage', () async {
    final business = FakeDualDomainBusiness()
      ..grants.add(const MatrixLoginGrant(
        loginToken: 'wrong-home',
        homeserver: 'https://wrong.matrix.example.test',
        expiresIn: 60,
        matrixUserId: '@alice:matrix.example.test',
      ));
    final matrix = _RecoverableMatrix();
    final service = _service(business, matrix);

    await expectLater(
        service.restoreAuthenticatedSession('@alice:matrix.example.test'),
        throwsA(isA<Exception>()));
    expect(business.tokenRequests, 1);
    expect(matrix.selections, 0);
    expect(matrix.recoveries, 0);
  });

  test('retained Business session keeps recovery intent for explicit action',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = _RecoverableMatrix();
    final service = _service(business, matrix);

    await expectLater(
        service.restoreAuthenticatedSession('@alice:matrix.example.test'),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));
    expect(business.logouts, 0);
    expect(matrix.recoveries, 0);
    await service.confirmNewDeviceAndLogin();
    expect(matrix.recoveries, 1);
    expect(matrix.loginDeviceIds, [null]);
  });

  test('old-identity mismatch preserves Business session until explicit choice',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = _RecoverableMatrix();
    final service = _service(business, matrix);

    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));
    expect(business.logouts, 0);
    expect(business.tokenRequests, 1);
    expect(matrix.recoveries, 0);
    expect(matrix.suspends, 0);
    expect(matrix.clears, 0);
    expect(matrix.logins, 0);

    await service.cancelNewDeviceRecovery();
    await expectLater(service.confirmNewDeviceAndLogin(), throwsStateError);
    expect(business.logouts, 0);
    expect(matrix.recoveries, 0);
    expect(matrix.clears, 0);
  });

  test('confirmed recovery validates a fresh grant before archiving', () async {
    final business = FakeDualDomainBusiness()
      ..grants.addAll(const [
        MatrixLoginGrant(
          loginToken: 'initial-valid-grant',
          homeserver: 'https://matrix.example.test',
          expiresIn: 60,
          matrixUserId: '@alice:matrix.example.test',
        ),
        MatrixLoginGrant(
          loginToken: 'wrong-user-grant',
          homeserver: 'https://matrix.example.test',
          expiresIn: 60,
          matrixUserId: '@mallory:matrix.example.test',
        ),
      ]);
    final matrix = _RecoverableMatrix();
    final service = _service(business, matrix);

    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));
    await expectLater(service.confirmNewDeviceAndLogin(), throwsA(anything));
    expect(matrix.recoveries, 0);
    expect(matrix.logins, 0);
    expect(matrix.clears, 0);
  });

  test('changed Business account blocks recovery before archive', () async {
    final business = FakeDualDomainBusiness();
    final matrix = _RecoverableMatrix();
    final service = _service(business, matrix);
    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));
    business.currentIdentity = '@bob:matrix.example.test';

    await expectLater(service.confirmNewDeviceAndLogin(), throwsStateError);
    expect(business.tokenRequests, 1);
    expect(matrix.recoveries, 0);
  });

  test('wrong homeserver grant blocks recovery before archive', () async {
    final business = FakeDualDomainBusiness()
      ..grants.addAll(const [
        MatrixLoginGrant(
          loginToken: 'initial-valid-grant',
          homeserver: 'https://matrix.example.test',
          expiresIn: 60,
          matrixUserId: '@alice:matrix.example.test',
        ),
        MatrixLoginGrant(
          loginToken: 'wrong-home-grant',
          homeserver: 'https://wrong.matrix.example.test',
          expiresIn: 60,
          matrixUserId: '@alice:matrix.example.test',
        ),
      ]);
    final matrix = _RecoverableMatrix();
    final service = _service(business, matrix);
    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));

    await expectLater(service.confirmNewDeviceAndLogin(), throwsStateError);
    expect(matrix.recoveries, 0);
    expect(matrix.logins, 0);
  });

  test('confirmed recovery keeps old device ID out of the new login', () async {
    final business = FakeDualDomainBusiness();
    final matrix = _RecoverableMatrix();
    final service = _service(business, matrix);

    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));
    await service.confirmNewDeviceAndLogin();

    expect(business.tokenRequests, 2);
    expect(matrix.recoveries, 1);
    expect(matrix.loginDeviceIds, [null]);
    expect(matrix.operations.indexOf('archive'),
        lessThan(matrix.operations.indexOf('login')));
    expect(business.boundMatrixUsers, ['@alice:matrix.example.test']);
    expect(business.logouts, 0);
    expect(matrix.clears, 0);
    await expectLater(service.confirmNewDeviceAndLogin(), throwsStateError);
    expect(matrix.recoveries, 1);
  });

  test('archive failure does not submit a Matrix login or clear old data',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = _RecoverableMatrix()..failRecovery = true;
    final service = _service(business, matrix);

    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));
    await expectLater(service.confirmNewDeviceAndLogin(), throwsA(anything));
    expect(matrix.logins, 0);
    expect(matrix.clears, 0);
    expect(business.logouts, 0);
  });

  test('grant expiry during archive requests a fresh grant', () async {
    var clock = DateTime.utc(2026, 9, 24);
    final business = FakeDualDomainBusiness();
    final matrix = _RecoverableMatrix()..recoveryGate = Completer<void>();
    final service = DualDomainLoginService(
      business: business,
      matrix: matrix,
      deviceKey: () => 'installation',
      retainedHomeserver: Uri.parse('https://matrix.example.test'),
      now: () => clock,
    );
    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));

    final confirmation = service.confirmNewDeviceAndLogin();
    while (matrix.recoveries == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    clock = clock.add(const Duration(minutes: 2));
    matrix.recoveryGate!.complete();
    await confirmation;
    expect(business.tokenRequests, 3);
    expect(matrix.logins, 1);
  });

  test('concurrent confirmation and server rejection preserve old archive',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = _RecoverableMatrix()
      ..recoveryGate = Completer<void>()
      ..loginError = StateError('server rejected new device');
    final service = _service(business, matrix);
    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));

    final first = service.confirmNewDeviceAndLogin();
    while (matrix.recoveries == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await expectLater(
        service.confirmNewDeviceAndLogin(), throwsA(isA<Exception>()));
    matrix.recoveryGate!.complete();
    await expectLater(first, throwsStateError);
    expect(matrix.recoveries, 1);
    expect(matrix.clears, 0);
    expect(business.logouts, 0);
  });

  test('wrong server Matrix identity is never bound to the Business account',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = _RecoverableMatrix()
      ..loginResultUserId = '@mallory:matrix.example.test';
    final service = _service(business, matrix);
    await expectLater(service.login('alice', 'password'),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));

    await expectLater(service.confirmNewDeviceAndLogin(), throwsStateError);
    expect(matrix.recoveries, 1);
    expect(matrix.clears, 0);
    expect(business.boundMatrixUsers, isEmpty);
  });
}
