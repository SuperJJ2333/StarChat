import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'session_bootstrap_controller_test.dart' show FakeBusiness;

class _InitializingMatrix
    implements MatrixSessionGateway, MatrixInitializationGateway {
  final barrier = Completer<void>();
  int syncCalls = 0;
  bool suspended = false;
  bool replacement = false;
  int failSuspends = 0;
  @override
  Future<void> get initializationCompleted =>
      suspended || replacement ? Future<void>.value() : barrier.future;
  @override
  bool get isLoggedIn => !suspended;
  @override
  String get userId => '@startup:synthetic.test';
  @override
  String get deviceId => 'SYNTHETIC';
  @override
  Future<void> sync() async {
    syncCalls++;
  }

  @override
  Future<void> suspend() async {
    if (failSuspends > 0) {
      failSuspends--;
      throw StateError('synthetic close failure');
    }
    suspended = true;
  }

  @override
  Future<void> clearLocalChatData() async {}
}

void main() {
  for (final outcome in ['success', 'network-error', 'dispose', 'mismatch']) {
    test('local projection session barrier: $outcome', () async {
      final matrix = _InitializingMatrix();
      final business = FakeBusiness(BusinessSessionRestore.authenticated,
          matrixUserId:
              outcome == 'mismatch' ? '@other:synthetic.test' : matrix.userId);
      final eligibility = <bool>[];
      final controller = SessionBootstrapController(
          business: business,
          matrix: matrix,
          onLocalProjectionEligibility: eligibility.add);
      var disposed = false;
      addTearDown(() {
        if (!disposed) controller.dispose();
      });
      final flight = controller.bootstrap();
      await Future<void>.delayed(Duration.zero);
      expect(eligibility, [outcome != 'mismatch']);
      expect(controller.canShowCachedMessages, outcome != 'mismatch');
      expect(controller.state.status, SessionBootstrapStatus.loading);
      expect(matrix.syncCalls, 0);
      if (outcome == 'dispose') {
        controller.dispose();
        disposed = true;
      }
      if (outcome == 'network-error') {
        matrix.barrier
            .completeError(const SocketException('synthetic recovery failure'));
      } else {
        matrix.barrier.complete();
      }
      await flight;
      if (outcome == 'success') {
        expect(controller.state.status, SessionBootstrapStatus.authenticated);
        expect(matrix.syncCalls, 1);
      } else if (outcome == 'network-error') {
        expect(controller.state.status, SessionBootstrapStatus.fatalError);
        expect(controller.canShowCachedMessages, isFalse);
        expect(matrix.syncCalls, 0);
      } else if (outcome == 'dispose') {
        expect(matrix.syncCalls, 0);
      }
    });
  }
  for (final outcome in ['success', 'offline', 'disposed', 'failed-suspend']) {
    test('failed startup retries safely through authorized restore: $outcome',
        () async {
      final matrix = _InitializingMatrix()
        ..failSuspends = outcome == 'failed-suspend' ? 1 : 0;
      final business = FakeBusiness(BusinessSessionRestore.authenticated,
          matrixUserId: matrix.userId);
      final restoreGate = Completer<void>();
      var restores = 0;
      final grants = <String>[];
      final controller = SessionBootstrapController(
          business: business,
          matrix: matrix,
          restoreLocalMatrixSession: (identity) async {
            expect(identity, matrix.userId);
            restores++;
            await restoreGate.future;
            matrix.replacement = true;
            matrix.suspended = false;
          });
      var disposed = false;
      addTearDown(() {
        if (!disposed) controller.dispose();
      });
      var dispatchEnabled = false;
      controller.addListener(() {
        final next =
            controller.state.status == SessionBootstrapStatus.authenticated;
        if (next && !dispatchEnabled) grants.add('pending-txid');
        dispatchEnabled = next;
      });
      final first = controller.bootstrap();
      await Future<void>.delayed(Duration.zero);
      matrix.barrier
          .completeError(StateError('synthetic full restore failure'));
      await first;
      expect(controller.state.status, SessionBootstrapStatus.fatalError);
      expect(controller.canShowCachedMessages, isFalse);
      expect(grants, isEmpty);
      if (outcome == 'offline') {
        business.result = BusinessSessionRestore.offline;
      }
      final retry = controller.bootstrap();
      final duplicate = controller.bootstrap();
      await Future<void>.delayed(Duration.zero);
      expect(controller.canShowCachedMessages, isFalse,
          reason: 'failed projection is never republished during retry');
      expect(matrix.syncCalls, 0);
      expect(grants, isEmpty);
      if (outcome == 'offline') {
        await retry;
        await duplicate;
        expect(restores, 0);
        expect(controller.state.status, SessionBootstrapStatus.fatalError);
        expect(matrix.suspended, isTrue);
        return;
      }
      expect(restores, 1,
          reason:
              'Retry must reach safe restore once after a failed SDK future');
      expect(controller.state.status, SessionBootstrapStatus.loading);
      if (outcome == 'disposed') {
        controller.dispose();
        disposed = true;
      }
      restoreGate.complete();
      await retry;
      await duplicate;
      if (outcome == 'disposed') {
        expect(matrix.suspended, isTrue,
            reason: 'late restored client must be retired');
        expect(grants, isEmpty);
        expect(matrix.syncCalls, 0);
      } else {
        expect(controller.state.status, SessionBootstrapStatus.authenticated);
        expect(matrix.replacement, isTrue);
        expect(grants, ['pending-txid'],
            reason: 'duplicate Retry must not grant dispatch twice');
        expect(matrix.syncCalls, 1);
      }
    });
  }
}
