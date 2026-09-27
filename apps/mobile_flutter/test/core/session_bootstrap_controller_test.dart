import 'package:flutter/services.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_security_logger.dart';
import 'package:matrix/matrix.dart';

final class FakeBusiness implements BusinessSessionGateway {
  Completer<void>? restoreGate;
  FakeBusiness(
    this.result, {
    this.matrixUserId,
    this.error,
    this.logoutBlocker,
    this.restoreGate,
  });
  BusinessSessionRestore result;
  String? matrixUserId;
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
  test(
      'cold start after archive before Business binding asks broker to resolve a null MXID',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated);
    final matrix = FakeMatrix(isLoggedIn: false);
    var restoreCalls = 0;
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
      restoreLocalMatrixSession: (identity) async {
        expect(identity, isNull);
        restoreCalls++;
        // An authorized account selection finds the durable archive journal.
        throw const MatrixNewDeviceRecoveryRequired();
      },
    );
    addTearDown(controller.dispose);

    await controller.bootstrap();

    expect(restoreCalls, 1);
    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);
    expect(controller.canShowCachedMessages, isFalse);
    expect(matrix.syncCalls, 0);
    expect(business.localClearCalls, 0);
  });

  test('cold start with unbound Business MXID reauthorizes a logged-in Matrix',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated);
    final matrix =
        FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost');
    var restoreCalls = 0;
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
      restoreLocalMatrixSession: (identity) async {
        expect(identity, isNull);
        restoreCalls++;
        // Broker-authorized restoration finishes the missing Business bind.
        business.matrixUserId = '@alice:matrix.localhost';
      },
    );
    addTearDown(controller.dispose);

    await controller.bootstrap();

    expect(restoreCalls, 1);
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
    expect(matrix.syncCalls, 1);
  });

  test(
      'retained identity recovery remains behind an authenticated Business session',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
      restoreLocalMatrixSession: (_) async =>
          throw const MatrixNewDeviceRecoveryRequired(),
    );
    addTearDown(controller.dispose);

    await controller.bootstrap();

    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);
    expect(controller.canShowCachedMessages, isFalse);
    expect(business.localClearCalls, 0);
    expect(matrix.clearCalls, 0);
  });

  test(
      'confirmed new device revalidates Business without replaying old restore',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    var restoreCalls = 0;
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
      restoreLocalMatrixSession: (_) async {
        restoreCalls++;
        throw const MatrixNewDeviceRecoveryRequired();
      },
    );
    addTearDown(controller.dispose);

    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);
    matrix.isLoggedIn = true;
    matrix.userId = '@alice:matrix.localhost';
    await controller.bootstrapAfterConfirmedNewDevice();

    expect(controller.state.status, SessionBootstrapStatus.authenticated);
    expect(restoreCalls, 1);
    expect(matrix.syncCalls, 1);
  });

  test('confirmed recovery hides chats until Business revalidation completes',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
      restoreLocalMatrixSession: (_) async =>
          throw const MatrixNewDeviceRecoveryRequired(),
    );
    addTearDown(controller.dispose);

    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);
    matrix.isLoggedIn = true;
    matrix.userId = '@alice:matrix.localhost';
    final revalidationGate = Completer<void>();
    business.restoreGate = revalidationGate;
    final pending = controller.bootstrapAfterConfirmedNewDevice();
    await Future<void>.delayed(Duration.zero);

    expect(controller.canShowCachedMessages, isFalse);
    revalidationGate.complete();
    await pending;
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
  });

  test(
      'retry after incomplete new-device login redoes session completion before chat access',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    var restores = 0;
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
      restoreLocalMatrixSession: (identity) async {
        restores++;
        if (restores == 1) {
          throw const MatrixNewDeviceRecoveryRequired();
        }
        expect(identity, '@alice:matrix.localhost');
      },
    );
    addTearDown(controller.dispose);

    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);
    // Token login may have succeeded before binding or broker completion
    // failed. The recovery action did not return successfully.
    matrix.isLoggedIn = true;
    matrix.userId = '@alice:matrix.localhost';
    await controller.bootstrap();

    expect(restores, 2);
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
    expect(matrix.syncCalls, 1);
  });

  test(
      'failed new-device binding with no Business MXID keeps recovery available',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
      restoreLocalMatrixSession: (_) async =>
          throw const MatrixNewDeviceRecoveryRequired(),
    );
    addTearDown(controller.dispose);

    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);
    // The new Matrix token was accepted, but Business binding failed, so the
    // local Business identity is absent until the recovery action is retried.
    matrix.isLoggedIn = true;
    matrix.userId = '@alice:matrix.localhost';
    business.matrixUserId = null;
    await controller.bootstrap();

    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);
    expect(controller.canShowCachedMessages, isFalse);
    expect(matrix.syncCalls, 0);
    expect(business.localClearCalls, 0);
  });

  test('offline retry preserves unfinished recovery for a later online retry',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    var restores = 0;
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
      restoreLocalMatrixSession: (_) async {
        if (++restores == 1) throw const MatrixNewDeviceRecoveryRequired();
        matrix.isLoggedIn = true;
        matrix.userId = '@alice:matrix.localhost';
      },
    );
    addTearDown(controller.dispose);

    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);
    business.result = BusinessSessionRestore.offline;
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);
    expect(controller.canShowCachedMessages, isFalse);
    expect(restores, 1);

    business.result = BusinessSessionRestore.authenticated;
    await controller.bootstrap();
    expect(restores, 2);
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
  });

  test(
      'incomplete restore is retried even after local client becomes logged in',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    var restores = 0;
    final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
        restoreLocalMatrixSession: (identity) async {
          matrix.isLoggedIn = true;
          matrix.userId = identity;
          if (++restores == 1) {
            throw StateError('session completion unavailable');
          }
        });
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
    expect(matrix.syncCalls, 0);
    await controller.bootstrap();
    expect(restores, 2);
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
    expect(business.localClearCalls, 0);
    controller.dispose();
  });

  test('wrapped protected-data restore failure keeps its specific guidance',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
        restoreLocalMatrixSession: (_) async {
          throw LoginStageException.fromCause(
              'account_storage', PlatformException(code: '-25308'));
        });
    await controller.bootstrap();
    expect(controller.state.message, contains('安全存储'));
    expect(controller.state.message, contains('解锁'));
    expect(business.localClearCalls, 0);
    controller.dispose();
  });
  test('offline business session never requests a new Matrix authorization',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.offline,
        matrixUserId: '@alice:matrix.localhost');
    var requests = 0;
    final controller = SessionBootstrapController(
        business: business,
        matrix: FakeMatrix(isLoggedIn: false),
        restoreLocalMatrixSession: (_) async {
          requests++;
        });
    await controller.bootstrap();
    expect(requests, 0);
    expect(business.localClearCalls, 0);
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
    controller.dispose();
  });
  test('logout wins over an in-flight local restore and suspends late client',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    final entered = Completer<void>();
    final finish = Completer<void>();
    final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
        restoreLocalMatrixSession: (identity) async {
          entered.complete();
          await finish.future;
          matrix.isLoggedIn = true;
          matrix.userId = identity;
        });
    final bootstrap = controller.bootstrap();
    await entered.future;
    await controller.logout();
    finish.complete();
    await bootstrap;
    expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
    expect(matrix.syncCalls, 0);
    expect(matrix.suspendCalls, 2);
    controller.dispose();
  });

  test('logout also suspends a late client when restoration then throws',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    final entered = Completer<void>();
    final finish = Completer<void>();
    final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
        restoreLocalMatrixSession: (identity) async {
          entered.complete();
          await finish.future;
          matrix.isLoggedIn = true;
          matrix.userId = identity;
          throw StateError('late completion failed');
        });
    final bootstrap = controller.bootstrap();
    await entered.future;
    await controller.logout();
    finish.complete();
    await bootstrap;
    expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
    expect(matrix.syncCalls, 0);
    expect(matrix.suspendCalls, 2);
    controller.dispose();
  });

  test(
      'valid business session reopens its retained Matrix store without password login',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    var restores = 0;
    final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
        restoreLocalMatrixSession: (identity) async {
          expect(identity, '@alice:matrix.localhost');
          restores++;
          matrix.isLoggedIn = true;
          matrix.userId = identity;
        });
    await controller.bootstrap();
    expect(restores, 1);
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
    expect(business.localClearCalls, 0);
    expect(matrix.clearCalls, 0);
    controller.dispose();
  });
  test('local restore error retains credentials and a later retry can reopen',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    var restores = 0;
    final controller = SessionBootstrapController(
        business: business,
        matrix: matrix,
        restoreLocalMatrixSession: (identity) async {
          if (++restores == 1) throw const FileSystemException('secret-path');
          matrix.isLoggedIn = true;
          matrix.userId = identity;
        });
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
    expect(controller.state.message, isNot(contains('secret-path')));
    expect(business.localClearCalls, 0);
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
    controller.dispose();
  });

  test(
      'unavailable local Matrix session preserves valid business credentials and retries',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(isLoggedIn: false);
    final controller =
        SessionBootstrapController(business: business, matrix: matrix);
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
    expect(business.localClearCalls, 0);
    expect(business.logoutCalls, 0);
    expect(matrix.clearCalls, 0);
    matrix.isLoggedIn = true;
    matrix.userId = '@alice:matrix.localhost';
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
    controller.dispose();
  });

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
