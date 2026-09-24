import 'dart:convert';
import 'dart:io';

import 'package:matrix/matrix.dart';
import 'package:olm/olm.dart' as olm;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/matrix_local_binding.dart';

enum MatrixLocalIdentityCause {
  missingDatabaseWithBinding,
  missingKey,
  missingOlmAccount,
  fingerprintMismatch,
  identityMismatch,
  unreadable,
  originalIdentityElsewhere,
  multipleCandidates,
}

/// No key, account identifier, fingerprint, pickle or SQL is part of this error.
final class MatrixLocalIdentityPreflightException implements Exception {
  const MatrixLocalIdentityPreflightException(this.cause,
      {this.canCreateNewDevice = false});

  final MatrixLocalIdentityCause cause;
  final bool canCreateNewDevice;

  @override
  String toString() => 'MatrixLocalIdentityPreflightException(${cause.name})';
}

enum MatrixLocalIdentityStatus { pristine, verifiedRetained }

final class MatrixLocalIdentityInspection {
  const MatrixLocalIdentityInspection(this.status,
      {this.matrixUserId, this.ed25519Fingerprint});

  final MatrixLocalIdentityStatus status;
  final String? matrixUserId;
  final String? ed25519Fingerprint;

  @override
  String toString() => 'MatrixLocalIdentityInspection(${status.name})';
}

final class MatrixLocalIdentityRecord {
  const MatrixLocalIdentityRecord({
    required this.hasRetainedData,
    this.matrixUserId,
    this.deviceId,
    this.olmAccount,
  });

  final bool hasRetainedData;
  final String? matrixUserId;
  final String? deviceId;
  final String? olmAccount;
}

abstract interface class MatrixLocalIdentityReader {
  Future<bool> exists(String databasePath);
  Future<MatrixLocalIdentityRecord> read(String databasePath, String cipher);
}

/// Only this reader touches the on-disk DB. It never opens MatrixSdkDatabase,
/// invokes SDK migrations, or creates a database file.
final class ReadOnlySqlCipherIdentityReader
    implements MatrixLocalIdentityReader {
  const ReadOnlySqlCipherIdentityReader();

  @override
  Future<bool> exists(String databasePath) async {
    if (await File(databasePath).exists()) return true;
    // An orphaned WAL/SHM can still contain retained chat state. Never treat
    // that filesystem state as a pristine install.
    if (await File('$databasePath-wal').exists() ||
        await File('$databasePath-shm').exists()) {
      throw const FormatException('Orphaned Matrix database sidecar');
    }
    return false;
  }

  @override
  Future<MatrixLocalIdentityRecord> read(
      String databasePath, String cipher) async {
    final factory = createDatabaseFactoryFfi(
      ffiInit: SQfLiteEncryptionHelper.ffiInit,
    );
    final db = await factory.openDatabase(databasePath,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    try {
      // sqflite ignores onConfigure for readOnly, so set the key on this
      // strictly read-only connection before touching sqlite_master.
      final cipherVersion = await db.rawQuery('PRAGMA cipher_version');
      if (cipherVersion.isEmpty) throw const FormatException('No SQLCipher');
      await db.execute("PRAGMA key = '${cipher.replaceAll("'", "''")}'");
      final clientTables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'box_client'");
      if (clientTables.length != 1) {
        throw const FormatException('Missing Matrix client table');
      }
      final rows = await db.rawQuery(
          "SELECT k, v FROM box_client WHERE k IN ('user_id', 'device_id', 'olm_account')");
      final values = <String, String>{};
      for (final row in rows) {
        final key = row['k'];
        final value = row['v'];
        if (key is! String || value is! String) {
          throw const FormatException('Invalid Matrix client row');
        }
        values[key] = value;
      }
      final count = await db.rawQuery(
          "SELECT COUNT(*) AS amount FROM box_client WHERE k <> 'version'");
      final clientHasData = (count.single['amount'] as int? ?? 0) > 0;
      var otherHasData = false;
      for (final table in const [
        'box_rooms',
        'box_olm_session',
        'box_inbound_group_session',
      ]) {
        final tableRows = await db.rawQuery(
            'SELECT name FROM sqlite_master WHERE type = ? AND name = ?',
            ['table', table]);
        if (tableRows.isEmpty) continue;
        final contents = await db.rawQuery('SELECT 1 FROM $table LIMIT 1');
        if (contents.isNotEmpty) otherHasData = true;
      }
      return MatrixLocalIdentityRecord(
        hasRetainedData: clientHasData || otherHasData,
        matrixUserId: values['user_id'],
        deviceId: values['device_id'],
        olmAccount: values['olm_account'],
      );
    } finally {
      await db.close();
    }
  }
}

typedef MatrixOlmFingerprintReader = Future<String> Function(
    String matrixUserId, String pickle);

Future<String> _unpickleFingerprint(String matrixUserId, String pickle) async {
  await olm.init();
  final account = olm.Account();
  try {
    account.unpickle(matrixUserId, pickle);
    final keys = jsonDecode(account.identity_keys());
    final fingerprint = keys is Map ? keys['ed25519'] : null;
    if (fingerprint is! String || fingerprint.isEmpty) {
      throw const FormatException('Invalid Olm identity');
    }
    return fingerprint;
  } finally {
    account.free();
  }
}

final class MatrixLocalIdentityPreflight {
  MatrixLocalIdentityPreflight({
    MatrixLocalIdentityReader? reader,
    MatrixOlmFingerprintReader? fingerprintReader,
  })  : reader = reader ?? const ReadOnlySqlCipherIdentityReader(),
        fingerprintReader = fingerprintReader ?? _unpickleFingerprint;

  final MatrixLocalIdentityReader reader;
  final MatrixOlmFingerprintReader fingerprintReader;

  Future<MatrixLocalIdentityInspection> inspect({
    required String databasePath,
    required String? cipher,
    required MatrixLocalBinding? binding,
    required String expectedHomeserver,
    String? expectedUserId,
  }) async {
    bool present;
    try {
      present = await reader.exists(databasePath);
    } catch (_) {
      throw const MatrixLocalIdentityPreflightException(
          MatrixLocalIdentityCause.unreadable);
    }
    if (!present) {
      if (binding != null) {
        throw const MatrixLocalIdentityPreflightException(
            MatrixLocalIdentityCause.missingDatabaseWithBinding);
      }
      return const MatrixLocalIdentityInspection(
          MatrixLocalIdentityStatus.pristine);
    }
    if (cipher == null || cipher.isEmpty) {
      throw const MatrixLocalIdentityPreflightException(
          MatrixLocalIdentityCause.missingKey);
    }
    MatrixLocalIdentityRecord record;
    try {
      record = await reader.read(databasePath, cipher);
    } catch (_) {
      throw const MatrixLocalIdentityPreflightException(
          MatrixLocalIdentityCause.unreadable);
    }
    final userId = record.matrixUserId;
    if (userId == null || userId.isEmpty) {
      if (binding == null && !record.hasRetainedData) {
        return const MatrixLocalIdentityInspection(
            MatrixLocalIdentityStatus.pristine);
      }
      throw const MatrixLocalIdentityPreflightException(
          MatrixLocalIdentityCause.identityMismatch);
    }
    if ((expectedUserId != null && userId != expectedUserId) ||
        (binding != null &&
            (binding.matrixUserId != userId ||
                binding.homeserver != expectedHomeserver))) {
      throw const MatrixLocalIdentityPreflightException(
          MatrixLocalIdentityCause.identityMismatch);
    }
    final pickle = record.olmAccount;
    if (pickle == null || pickle.isEmpty) {
      throw const MatrixLocalIdentityPreflightException(
          MatrixLocalIdentityCause.missingOlmAccount);
    }
    String fingerprint;
    try {
      fingerprint = await fingerprintReader(userId, pickle);
    } catch (_) {
      throw const MatrixLocalIdentityPreflightException(
          MatrixLocalIdentityCause.unreadable);
    }
    final boundFingerprint = binding?.ed25519Fingerprint;
    if (boundFingerprint != null && boundFingerprint != fingerprint) {
      throw const MatrixLocalIdentityPreflightException(
          MatrixLocalIdentityCause.fingerprintMismatch);
    }
    return MatrixLocalIdentityInspection(
      MatrixLocalIdentityStatus.verifiedRetained,
      matrixUserId: userId,
      ed25519Fingerprint: fingerprint,
    );
  }
}
