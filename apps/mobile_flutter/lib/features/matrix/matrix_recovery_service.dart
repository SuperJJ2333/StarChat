import 'package:flutter/foundation.dart';

enum RecoveryBootstrapResult {
  created,
  reused,
  needsSecretStorageUnlock,
  needsInteractiveAuthentication,
}

enum MatrixRecoveryState { idle, restoring, ready, needsRecoveryKey, failed }

abstract interface class MatrixRecoveryBackend {
  Future<RecoveryBootstrapResult> bootstrapOnlineBackup({String? recoveryKey});
  Future<void> uploadPendingInboundSessions();
  Future<void> unlockSecretStorage(String recoveryKey);
  Future<void> restoreAllInboundSessions();
  Future<bool> backupKeyMatchesCurrentVersion();
}

final class RecoveryBackupMismatch implements Exception {
  const RecoveryBackupMismatch();
}

/// Coordinates Matrix-only room-key recovery. Recovery keys never cross this
/// boundary into a Business API or a widget navigation argument.
final class MatrixRecoveryService extends ChangeNotifier {
  MatrixRecoveryService(this._backend);

  final MatrixRecoveryBackend _backend;
  MatrixRecoveryState _state = MatrixRecoveryState.idle;
  MatrixRecoveryState get state => _state;

  Future<void> restoreFromRecoveryKey(String recoveryKey) async {
    _setState(MatrixRecoveryState.restoring);
    try {
      await _backend.unlockSecretStorage(recoveryKey);
      if (!await _backend.backupKeyMatchesCurrentVersion()) {
        throw const RecoveryBackupMismatch();
      }
      await _backend.restoreAllInboundSessions();
      await _backend.uploadPendingInboundSessions();
      _setState(MatrixRecoveryState.ready);
    } on RecoveryBackupMismatch {
      _setState(MatrixRecoveryState.needsRecoveryKey);
      rethrow;
    } catch (_) {
      _setState(MatrixRecoveryState.failed);
      rethrow;
    }
  }

  Future<void> uploadPendingInboundSessions() =>
      _backend.uploadPendingInboundSessions();

  void _setState(MatrixRecoveryState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }
}
