import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_security_logger.dart';
import 'package:matrix/matrix.dart';

final class FakeBusiness implements BusinessSessionGateway {
  final Completer<void>? restoreGate;
  FakeBusiness(
    this.result, {
    this.matrixUserId,
    this.error,
    this.logoutBlocker,
    this.restoreGate,
  });
  final BusinessSessionRestore result;
  final String? matrixUserId;
  final Object? error;
  final Completer<void>? logoutBlocker;
  int logoutCalls = 0;
  int localClearCalls = 0;
  @override
  Future<String?> currentMatrixUserId() async => matrixUserId;
  Future<void> logout() async {
    logoutCalls++;
    await logoutBlocker?.future;
  }

  @override
  Future<BusinessSessionRevocation?> clearLocalSession() async {
    localClearCalls++;
    return _FakeRevocation(() async {
      logoutCalls++;
      await logoutBlocker?.future;
    });
  }

  @override
  Future<BusinessSessionRestore> restoreSession() async {
    await restoreGate?.future;
    if (error != null) throw error!;
    return result;
  }
}

final class _FakeRevocation implements BusinessSessionRevocation {
  const _FakeRevocation(this._revoke);
  final Future<void> Function() _revoke;
  @override
  Future<void> revoke() => _revoke();
}

final class FakeMatrix implements MatrixSessionGateway {
  FakeMatrix({
    required this.isLoggedIn,
    this.userId,
    this.deviceId = 'DEVICE',
    this.syncError,
    this.suspendError,
    this.suspendBlocker,
  });
  @override
  bool isLoggedIn;
  @override
  String? userId;
  @override
  String? deviceId;
  final Object? syncError;
  final Object? suspendError;
  final Completer<void>? suspendBlocker;
  int suspendCalls = 0;
  int syncCalls = 0;
  int clearCalls = 0;
  @override
  Future<void> suspend() async {
    suspendCalls++;
    if (suspendError != null) throw suspendError!;
    await suspendBlocker?.future;
  }

  @override
  Future<void> clearLocalChatData() async {
    clearCalls++;
    isLoggedIn = false;
  }

  @override
  Future<void> sync() async {
    syncCalls++;
    if (syncError != null) throw syncError!;
  }
}

void main() {
  test('authenticated listener logout prevents Matrix authorization', () async {
    final matrix =
        FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost');
    final controller = SessionBootstrapController(
        business: FakeBusiness(BusinessSessionRestore.authenticated,
            matrixUserId: '@alice:matrix.localhost'),
        matrix: matrix);
    Future<void>? logout;
    controller.addListener(() {
      if (controller.state.status == SessionBootstrapStatus.authenticated) {
        logout = controller.logout();
      }
    });
    await controller.bootstrap();
    await logout;
    expect(matrix.syncCalls, 0);
  });

  test('late recovery cannot synchronize after logout', () async {
    final controller = SessionBootstrapController(
        business: FakeBusiness(BusinessSessionRestore.authenticated,
            matrixUserId: '@alice:matrix.localhost'),
        matrix:
            FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost'));
    await controller.bootstrap();
    final finish = Completer<bool>();
    var synchronized = false;
    final work = controller.runAuthenticatedBackground(
        prepare: () => finish.future,
        complete: () async {
          synchronized = true;
        });
    await controller.logout();
    finish.complete(true);
    await work;
    expect(synchronized, isFalse);
  });

  test(
    'local matching identity exposes cached preview during slow refresh',
    () async {
      final gate = Completer<void>();
      final controller = SessionBootstrapController(
        business: FakeBusiness(
          BusinessSessionRestore.authenticated,
          matrixUserId: '@alice:matrix.localhost',
          restoreGate: gate,
        ),
        matrix: FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost'),
      );
      final pending = controller.bootstrap();
      await Future<void>.delayed(Duration.zero);
      expect(controller.canShowCachedMessages, isTrue);
      expect(controller.state.status, SessionBootstrapStatus.loading);
      gate.complete();
      await pending;
    },
  );
  test('mismatched local identity never exposes cached messages', () async {
    final controller = SessionBootstrapController(
      business: FakeBusiness(
        BusinessSessionRestore.authenticated,
        matrixUserId: '@bob:matrix.localhost',
      ),
      matrix: FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost'),
    );
    await controller.bootstrap();
    expect(controller.canShowCachedMessages, isFalse);
  });
  test('no persisted domains becomes unauthenticated', () async {
    final controller = SessionBootstrapController(
      business: FakeBusiness(BusinessSessionRestore.absent),
      matrix: FakeMatrix(isLoggedIn: false),
    );
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
    expect((controller.matrix as FakeMatrix).suspendCalls, 1);
  });

  test(
    'bootstrap blocks chat access before Matrix suspension drains',
    () async {
      final blocker = Completer<void>();
      final controller = SessionBootstrapController(
        business: FakeBusiness(BusinessSessionRestore.absent),
        matrix: FakeMatrix(isLoggedIn: true, suspendBlocker: blocker),
      );

      final bootstrap = controller.bootstrap();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      blocker.complete();
      await bootstrap;
    },
  );

  test('both restored domains become authenticated', () async {
    final controller = SessionBootstrapController(
      business: FakeBusiness(
        BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost',
      ),
      matrix: FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost'),
    );
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
  });

  test(
    'temporary network failure preserves an offline authenticated session',
    () async {
      final business = FakeBusiness(
        BusinessSessionRestore.offline,
        matrixUserId: '@alice:matrix.localhost',
      );
      final matrix = FakeMatrix(
        isLoggedIn: true,
        userId: '@alice:matrix.localhost',
        syncError: const SocketException('offline'),
      );
      final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
      );
      await controller.bootstrap();
      expect(
        controller.state.status,
        SessionBootstrapStatus.offlineAuthenticated,
      );
      expect(business.logoutCalls, 0);
      expect(matrix.suspendCalls, 0);
      expect(matrix.clearCalls, 0);
    },
  );

  for (final result in [
    BusinessSessionRestore.absent,
    BusinessSessionRestore.invalid,
  ]) {
    test(
      'Business $result preserves a locally logged-in Matrix session',
      () async {
        final matrix = FakeMatrix(
          isLoggedIn: true,
          userId: '@alice:matrix.localhost',
        );
        final controller = SessionBootstrapController(
          business: FakeBusiness(result),
          matrix: matrix,
        );

        await controller.bootstrap();

        expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
        expect(matrix.suspendCalls, 1);
        expect(matrix.clearCalls, 0);
      },
    );
  }

  for (final errcode in ['M_UNKNOWN_TOKEN', 'M_FORBIDDEN']) {
    test('Matrix $errcode preserves chat data and returns to login', () async {
      final business = FakeBusiness(
        BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost',
      );
      final matrix = FakeMatrix(
        isLoggedIn: true,
        userId: '@alice:matrix.localhost',
        syncError: MatrixException.fromJson({
          'errcode': errcode,
          'error': 'expired',
        }),
      );
      final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
      );

      await controller.bootstrap();

      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      expect(controller.state.message, '登录状态已失效，请重新登录');
      expect(business.logoutCalls, 1);
      expect(matrix.suspendCalls, 1);
      expect(matrix.clearCalls, 0);
    });
  }

  test(
    'mismatched domain identities fail closed without deleting data',
    () async {
      final business = FakeBusiness(
        BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost',
      );
      final matrix = FakeMatrix(
        isLoggedIn: true,
        userId: '@mallory:matrix.localhost',
      );
      final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
      );
      await controller.bootstrap();
      expect(controller.state.status, SessionBootstrapStatus.fatalError);
      expect(business.logoutCalls, 0);
      expect(matrix.suspendCalls, 0);
      expect(matrix.clearCalls, 0);
    },
  );

  test(
    'missing migrated Business MXID cannot authenticate a Matrix session',
    () async {
      final business = FakeBusiness(BusinessSessionRestore.authenticated);
      final matrix = FakeMatrix(
        isLoggedIn: true,
        userId: '@mallory:matrix.localhost',
      );
      final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
      );

      await controller.bootstrap();

      expect(controller.state.status, SessionBootstrapStatus.fatalError);
      expect(business.logoutCalls, 0);
      expect(matrix.suspendCalls, 0);
      expect(matrix.clearCalls, 0);
    },
  );

  test(
    'suspend failure clears Business and keeps Matrix data recoverable',
    () async {
      final business = FakeBusiness(BusinessSessionRestore.absent);
      final matrix = FakeMatrix(
        isLoggedIn: true,
        userId: '@alice:matrix.localhost',
        suspendError: StateError('close failed'),
      );
      final diagnostics = <String>[];
      final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
        securityLogger: MatrixSecurityLogger(
          traceId: () => 'trace-test',
          sink: diagnostics.add,
        ),
      );

      await controller.bootstrap();

      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      expect(controller.state.message, '聊天会话暂停失败，请重新打开应用后重试');
      expect(business.logoutCalls, 1);
      expect(matrix.suspendCalls, 1);
      expect(matrix.clearCalls, 0);
      expect(diagnostics, [
        '{"trace_id":"trace-test","stage":"lifecycle",'
            '"outcome":"failure","event_code":"E2EE_LIFECYCLE_SUSPEND_FAILED"}',
      ]);
    },
  );

  test('local storage failure becomes fatal error', () async {
    final controller = SessionBootstrapController(
      business: FakeBusiness(
        BusinessSessionRestore.absent,
        error: const FormatException('corrupt'),
      ),
      matrix: FakeMatrix(isLoggedIn: false),
    );
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
  });

  test(
    'ordinary logout suspends Matrix without erasing its local store',
    () async {
      final business = FakeBusiness(
        BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost',
      );
      final matrix = FakeMatrix(
        isLoggedIn: true,
        userId: '@alice:matrix.localhost',
      );
      final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
      );
      await controller.logout();
      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      expect(business.logoutCalls, 1);
      expect(matrix.suspendCalls, 1);
      expect(matrix.clearCalls, 0);
    },
  );

  test(
    'logout blocks chat access after local Business clear and before suspend drains',
    () async {
      final blocker = Completer<void>();
      final business = FakeBusiness(BusinessSessionRestore.authenticated);
      final controller = SessionBootstrapController(
        business: business,
        matrix: FakeMatrix(isLoggedIn: true, suspendBlocker: blocker),
      );

      final logout = controller.logout();
      await Future<void>.delayed(Duration.zero);

      expect(business.logoutCalls, 1);
      expect(business.localClearCalls, 1);
      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      blocker.complete();
      await logout;
    },
  );

  test(
    'logout completes when remote Business revocation never completes',
    () async {
      final remoteNeverCompletes = Completer<void>();
      final business = FakeBusiness(
        BusinessSessionRestore.authenticated,
        logoutBlocker: remoteNeverCompletes,
      );
      final matrix = FakeMatrix(isLoggedIn: true);
      final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
        remoteLogoutTimeout: const Duration(milliseconds: 10),
      );

      await controller.logout().timeout(const Duration(milliseconds: 100));

      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      expect(business.localClearCalls, 1);
      expect(business.logoutCalls, 1);
      expect(matrix.suspendCalls, 1);
      expect(matrix.clearCalls, 0);
    },
  );
}
