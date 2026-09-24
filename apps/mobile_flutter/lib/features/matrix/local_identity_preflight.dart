import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';
import 'package:olm/olm.dart' as olm;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/matrix_local_binding.dart';

enum MatrixLocalIdentityCause {
  missingDatabaseWithBinding,
  missingDatabaseWithKey,
  missingKey,
  missingOlmAccount,
  fingerprintMismatch,
  identityMismatch,
  unreadable,
  originalIdentityElsewhere,
  multipleCandidates,
  recoveryPending,
  legacyPlaintextMigrationDeferred,
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
      {this.matrixUserId,
      this.ed25519Fingerprint,
      this.requiresAuthenticatedMigration = false});

  final MatrixLocalIdentityStatus status;
  final String? matrixUserId;
  final String? ed25519Fingerprint;

  /// The SDK would encrypt a verified legacy plaintext DB when it opens it.
  /// Its caller must obtain Business authorization before that write.
  final bool requiresAuthenticatedMigration;

  @override
  String toString() => 'MatrixLocalIdentityInspection(${status.name})';
}

final class MatrixLocalIdentityRecord {
  const MatrixLocalIdentityRecord({
    required this.hasRetainedData,
    this.matrixUserId,
    this.deviceId,
    this.olmAccount,
    this.requiresAuthenticatedMigration = false,
  });

  final bool hasRetainedData;
  final String? matrixUserId;
  final String? deviceId;
  final String? olmAccount;
  final bool requiresAuthenticatedMigration;
}

abstract interface class MatrixLocalIdentityReader {
  Future<bool> exists(String databasePath);
  Future<MatrixLocalIdentityRecord> read(String databasePath, String cipher);
}

/// Optional capability used only to inspect a legacy plaintext SQLite file
/// when no SQLCipher key survived in Keychain. A missing key for an encrypted
/// database still fails closed.
abstract interface class MatrixPlaintextIdentityProbe {
  Future<bool> hasPlaintextHeader(String databasePath);
}

/// Only this reader touches the on-disk DB. It never opens MatrixSdkDatabase,
/// invokes SDK migrations, or creates a database file.
final class ReadOnlySqlCipherIdentityReader
    implements MatrixLocalIdentityReader, MatrixPlaintextIdentityProbe {
  const ReadOnlySqlCipherIdentityReader();

  static const _sqliteHeader = <int>[
    83,
    81,
    76,
    105,
    116,
    101,
    32,
    102,
    111,
    114,
    109,
    97,
    116,
    32,
    51,
    0,
  ];

  @override
  Future<bool> hasPlaintextHeader(String databasePath) async {
    final file = await File(databasePath).open(mode: FileMode.read);
    try {
      final bytes = await file.read(_sqliteHeader.length);
      if (bytes.length != _sqliteHeader.length) return false;
      for (var index = 0; index < bytes.length; index++) {
        if (bytes[index] != _sqliteHeader[index]) return false;
      }
      return true;
    } finally {
      await file.close();
    }
  }

  @override
  Future<bool> exists(String databasePath) async {
    // SQLCipher's plaintext migration uses a temporary .encrypted database.
    // An interrupted migration may leave its only copy (or WAL) there.
    // Its identity cannot be safely inferred from the normal database path.
    for (final suffix in const [
      '.encrypted',
      '.encrypted-wal',
      '.encrypted-shm',
    ]) {
      if (await File('$databasePath$suffix').exists()) {
        throw const FormatException('Interrupted Matrix encryption migration');
      }
    }
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
    // A SQLite read-only connection may still update WAL read marks in -shm.
    // Inspect a short-lived copy of the encrypted DB and both sidecars so the
    // original retained files are physically untouched. The old client must
    // already be closed; if a file changes while copying, fail closed.
    final snapshotDirectory =
        await Directory.systemTemp.createTemp('matrix_identity_preflight_');
    final snapshotPath =
        '${snapshotDirectory.path}${Platform.pathSeparator}identity.sqlite';
    const suffixes = ['', '-wal', '-shm'];
    final before = <String, String?>{};
    try {
      for (final suffix in suffixes) {
        final source = File('$databasePath$suffix');
        final type =
            await FileSystemEntity.type(source.path, followLinks: false);
        if (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file) {
          throw const FormatException('Invalid Matrix database file');
        }
        if (type == FileSystemEntityType.notFound) {
          before[suffix] = null;
          continue;
        }
        final digest = await _fileDigest(source);
        before[suffix] = digest;
        final snapshot = await source.copy('$snapshotPath$suffix');
        if (await _fileDigest(snapshot) != digest) {
          throw const FormatException('Matrix database changed during copy');
        }
      }
      final record = await _readSnapshot(snapshotPath, cipher);
      for (final suffix in suffixes) {
        final source = File('$databasePath$suffix');
        final type =
            await FileSystemEntity.type(source.path, followLinks: false);
        final digest = type == FileSystemEntityType.notFound
            ? null
            : type == FileSystemEntityType.file
                ? await _fileDigest(source)
                : throw const FormatException('Invalid Matrix database file');
        if (digest != before[suffix]) {
          throw const FormatException('Matrix database changed during probe');
        }
      }
      return record;
    } finally {
      await snapshotDirectory.delete(recursive: true);
    }
  }

  Future<String> _fileDigest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<MatrixLocalIdentityRecord> _readSnapshot(
      String databasePath, String cipher) async {
    final plaintext = await hasPlaintextHeader(databasePath);
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
      if (!plaintext) {
        if (cipher.isEmpty) {
          throw const FormatException('Missing SQLCipher key');
        }
        await db.execute("PRAGMA key = '${cipher.replaceAll("'", "''")}'");
      }
      return readMatrixIdentityTables(db,
          requiresAuthenticatedMigration: plaintext);
    } finally {
      await db.close();
    }
  }
}

/// Inspects Matrix's existing SQLite boxes without invoking SDK migrations.
/// The caller must provide a read-only connection to a temporary DB snapshot.
Future<MatrixLocalIdentityRecord> readMatrixIdentityTables(Database db,
    {bool requiresAuthenticatedMigration = false}) async {
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
  final tables =
      await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
  for (final row in tables) {
    final table = row['name'];
    if (table is! String || table.isEmpty) {
      throw const FormatException('Invalid Matrix table name');
    }
    if (table == 'box_client' || table.startsWith('sqlite_')) continue;
    // Matrix SDK has more than twenty boxes, and its schema may grow. A
    // retained row in any user table must prevent a pristine classification.
    final quotedName = table.replaceAll('"', '""');
    final contents = await db.rawQuery('SELECT 1 FROM "$quotedName" LIMIT 1');
    if (contents.isNotEmpty) {
      otherHasData = true;
      break;
    }
  }
  return MatrixLocalIdentityRecord(
    hasRetainedData: clientHasData || otherHasData,
    matrixUserId: values['user_id'],
    deviceId: values['device_id'],
    olmAccount: values['olm_account'],
    requiresAuthenticatedMigration: requiresAuthenticatedMigration,
  );
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
      if (cipher != null && cipher.isNotEmpty) {
        throw const MatrixLocalIdentityPreflightException(
            MatrixLocalIdentityCause.missingDatabaseWithKey);
      }
      return const MatrixLocalIdentityInspection(
          MatrixLocalIdentityStatus.pristine);
    }
    if (cipher == null || cipher.isEmpty) {
      bool plaintext;
      try {
        plaintext = reader is MatrixPlaintextIdentityProbe &&
            await (reader as MatrixPlaintextIdentityProbe)
                .hasPlaintextHeader(databasePath);
      } catch (_) {
        throw const MatrixLocalIdentityPreflightException(
            MatrixLocalIdentityCause.unreadable);
      }
      if (!plaintext) {
        throw const MatrixLocalIdentityPreflightException(
            MatrixLocalIdentityCause.missingKey);
      }
    }
    MatrixLocalIdentityRecord record;
    try {
      record = await reader.read(databasePath, cipher ?? '');
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
    if (record.requiresAuthenticatedMigration && boundFingerprint == null) {
      throw const MatrixLocalIdentityPreflightException(
          MatrixLocalIdentityCause.identityMismatch);
    }
    if (boundFingerprint != null && boundFingerprint != fingerprint) {
      throw const MatrixLocalIdentityPreflightException(
          MatrixLocalIdentityCause.fingerprintMismatch);
    }
    return MatrixLocalIdentityInspection(
      MatrixLocalIdentityStatus.verifiedRetained,
      matrixUserId: userId,
      ed25519Fingerprint: fingerprint,
      requiresAuthenticatedMigration: record.requiresAuthenticatedMigration,
    );
  }
}
