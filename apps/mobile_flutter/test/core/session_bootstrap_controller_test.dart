import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';

final class FakeBusiness implements BusinessSessionGateway {
  FakeBusiness(this.result, {this.matrixUserId, this.error});
  final BusinessSessionRestore result;
  final String? matrixUserId;
  final Object? error;
  int logoutCalls = 0;
  @override
  Future<String?> currentMatrixUserId() async => matrixUserId;
  @override
  Future<void> logout() async => logoutCalls++;
  @override
  Future<BusinessSessionRestore> restoreSession() async {
    if (error != null) throw error!;
    return result;
  }
}

final class FakeMatrix implements MatrixSessionGateway {
  FakeMatrix(
      {required this.isLoggedIn,
      this.userId,
      this.deviceId = 'DEVICE',
      this.syncError});
  @override
  bool isLoggedIn;
  @override
  String? userId;
  @override
  String? deviceId;
  final Object? syncError;
  int logoutCalls = 0;
  int suspendCalls = 0;
  int clearCalls = 0;
  @override
  Future<void> suspend() async => suspendCalls++;
  @override
  Future<void> clearLocalChatData() async {
    clearCalls++;
    isLoggedIn = false;
  }

  Future<void> logout() async {
    logoutCalls++;
    isLoggedIn = false;
  }

  @override
  Future<void> sync() async {
    if (syncError != null) throw syncError!;
  }
}

void main() {
  test('no persisted domains becomes unauthenticated', () async {
    final controller = SessionBootstrapController(
      business: FakeBusiness(BusinessSessionRestore.absent),
      matrix: FakeMatrix(isLoggedIn: false),
    );
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
  });

  test('both restored domains become authenticated', () async {
    final controller = SessionBootstrapController(
      business: FakeBusiness(BusinessSessionRestore.authenticated,
          matrixUserId: '@alice:matrix.localhost'),
      matrix: FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost'),
    );
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
  });

  test('temporary network failure preserves an offline authenticated session',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.offline,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(
        isLoggedIn: true,
        userId: '@alice:matrix.localhost',
        syncError: const SocketException('offline'));
    final controller =
        SessionBootstrapController(business: business, matrix: matrix);
    await controller.bootstrap();
    expect(
        controller.state.status, SessionBootstrapStatus.offlineAuthenticated);
    expect(business.logoutCalls, 0);
    expect(matrix.logoutCalls, 0);
    expect(matrix.suspendCalls, 0);
    expect(matrix.clearCalls, 0);
  });

  for (final result in [
    BusinessSessionRestore.absent,
    BusinessSessionRestore.invalid,
  ]) {
    test('Business $result preserves a locally logged-in Matrix session',
        () async {
      final matrix =
          FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost');
      final controller = SessionBootstrapController(
        business: FakeBusiness(result),
        matrix: matrix,
      );

      await controller.bootstrap();

      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      expect(matrix.suspendCalls, 1);
      expect(matrix.clearCalls, 0);
    });
  }

  for (final errcode in ['M_UNKNOWN_TOKEN', 'M_FORBIDDEN']) {
    test('Matrix $errcode preserves chat data and returns to login', () async {
      final business = FakeBusiness(BusinessSessionRestore.authenticated,
          matrixUserId: '@alice:matrix.localhost');
      final matrix = FakeMatrix(
        isLoggedIn: true,
        userId: '@alice:matrix.localhost',
        syncError:
            MatrixException.fromJson({'errcode': errcode, 'error': 'expired'}),
      );
      final controller =
          SessionBootstrapController(business: business, matrix: matrix);

      await controller.bootstrap();

      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      expect(controller.state.message, '登录状态已失效，请重新登录');
      expect(business.logoutCalls, 1);
      expect(matrix.suspendCalls, 1);
      expect(matrix.clearCalls, 0);
    });
  }

  test('mismatched domain identities fail closed without deleting data',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix =
        FakeMatrix(isLoggedIn: true, userId: '@mallory:matrix.localhost');
    final controller =
        SessionBootstrapController(business: business, matrix: matrix);
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
    expect(business.logoutCalls, 0);
    expect(matrix.logoutCalls, 0);
    expect(matrix.suspendCalls, 0);
    expect(matrix.clearCalls, 0);
  });

  test('missing migrated Business MXID cannot authenticate a Matrix session',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated);
    final matrix = FakeMatrix(
      isLoggedIn: true,
      userId: '@mallory:matrix.localhost',
    );
    final controller =
        SessionBootstrapController(business: business, matrix: matrix);

    await controller.bootstrap();

    expect(controller.state.status, SessionBootstrapStatus.fatalError);
    expect(business.logoutCalls, 0);
    expect(matrix.logoutCalls, 0);
  });

  test('local storage failure becomes fatal error', () async {
    final controller = SessionBootstrapController(
      business: FakeBusiness(BusinessSessionRestore.absent,
          error: const FormatException('corrupt')),
      matrix: FakeMatrix(isLoggedIn: false),
    );
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
  });

  test('ordinary logout suspends Matrix without erasing its local store',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix =
        FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost');
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
    );
    await controller.logout();
    expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
    expect(business.logoutCalls, 1);
    expect(matrix.suspendCalls, 1);
    expect(matrix.clearCalls, 0);
  });
}
