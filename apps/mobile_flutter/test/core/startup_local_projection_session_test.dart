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
  @override
  Future<void> get initializationCompleted => barrier.future;
  @override
  bool get isLoggedIn => true;
  @override
  String get userId => '@startup:synthetic.test';
  @override
  String get deviceId => 'SYNTHETIC';
  @override
  Future<void> sync() async {
    syncCalls++;
  }

  @override
  Future<void> suspend() async {}
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
}
