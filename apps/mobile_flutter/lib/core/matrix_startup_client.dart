import 'package:matrix/matrix.dart';

import 'session_store.dart';
import '../features/matrix/local_identity_preflight.dart';

/// A crash during identity archival must reach the safe login shell. A
/// diagnostic salt is optional there and must not trigger archive replay or
/// create new secure-store data before Business authentication.
Future<String?> loadStartupDiagnosticSalt(SecureSessionStore store) async {
  try {
    return await store.diagnosticSalt();
  } on MatrixArchiveRecoveryPending {
    return null;
  }
}

/// Do not interpret an unfinished archive against a half-written active
/// pointer before Business authentication. Account selection replays it after
/// the broker grant has confirmed the target user and homeserver.
Future<void> validateLocalLoginStorageForAuthentication(
    SecureSessionStore store) async {
  try {
    await store.validateLocalLoginStorage();
  } on MatrixArchiveRecoveryPending {
    // The journal is preserved for grant-checked replay in selectAccount.
  }
}

/// A safe authentication shell may be composed when the active Matrix scope
/// cannot be opened before Business auth. It has no database or chat data.
final class StartupMatrixClient {
  const StartupMatrixClient(this.client, {required this.recoveryDeferred});

  final Client client;
  final bool recoveryDeferred;
}

Future<StartupMatrixClient> openStartupMatrixClient({
  required Future<Client> Function() openRetained,
  required Client Function() createSafeShell,
}) async {
  try {
    return StartupMatrixClient(await openRetained(), recoveryDeferred: false);
  } on MatrixLocalIdentityPreflightException catch (error) {
    if (!error.canCreateNewDevice &&
        error.cause != MatrixLocalIdentityCause.originalIdentityElsewhere &&
        error.cause != MatrixLocalIdentityCause.recoveryPending &&
        error.cause !=
            MatrixLocalIdentityCause.legacyPlaintextMigrationDeferred) {
      rethrow;
    }
    return StartupMatrixClient(createSafeShell(), recoveryDeferred: true);
  }
}

/// A deferred safe shell is deliberately uninitialized. The ordinary
/// continuity reader may clear a retained binding when given such a client;
/// only clients actually opened from a Matrix store may reach it.
Future<T> Function(Client) guardStartupContinuityReader<T>(
  StartupMatrixClient startup,
  Future<T> Function(Client) read,
) =>
    (client) async {
      if (startup.recoveryDeferred && identical(client, startup.client)) {
        throw StateError('Deferred local identity recovery');
      }
      return read(client);
    };
