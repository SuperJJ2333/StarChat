import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_recovery_service.dart';

final class _Backend implements MatrixRecoveryBackend {
  String? unlocked;
  var restoreCalls = 0;
  var uploadCalls = 0;
  var matches = true;

  @override
  Future<RecoveryBootstrapResult> bootstrapOnlineBackup(
          {String? recoveryKey}) async =>
      RecoveryBootstrapResult.reused;
  @override
  Future<bool> backupKeyMatchesCurrentVersion() async => matches;
  @override
  Future<void> restoreAllInboundSessions() async => restoreCalls++;
  @override
  Future<void> unlockSecretStorage(String recoveryKey) async =>
      unlocked = recoveryKey;
  @override
  Future<void> uploadPendingInboundSessions() async => uploadCalls++;
}

void main() {
  test('stored recovery key unlocks backup, restores sessions, and uploads',
      () async {
    final backend = _Backend();
    final service = MatrixRecoveryService(backend);
    await service.restoreFromRecoveryKey('local-only-recovery-key');
    expect(backend.unlocked, 'local-only-recovery-key');
    expect(backend.restoreCalls, 1);
    expect(backend.uploadCalls, 1);
    expect(service.state, MatrixRecoveryState.ready);
  });

  test('backup key mismatch refuses restore without destructive mutation',
      () async {
    final backend = _Backend()..matches = false;
    final service = MatrixRecoveryService(backend);
    await expectLater(service.restoreFromRecoveryKey('local-only-recovery-key'),
        throwsA(isA<RecoveryBackupMismatch>()));
    expect(backend.restoreCalls, 0);
    expect(backend.uploadCalls, 0);
  });
}
