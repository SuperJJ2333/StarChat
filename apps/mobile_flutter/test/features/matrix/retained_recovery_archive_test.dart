import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:olm/olm.dart' as olm;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Secrets implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Fresh extends Client {
  _Fresh(this.storage, this.identity)
      : super('fresh-archive',
            httpClient: MockClient((_) async => throw StateError(
                'No old or fresh credential network during local migration')));
  final MatrixSdkDatabase storage;
  final String identity;
  @override
  String get userID => identity;
  @override
  String get deviceID => 'FRESH';
  @override
  DatabaseApi get database => storage;
  late final crypto = Encryption(client: this);
  @override
  Encryption get encryption => crypto;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await olm.init();
    final factory =
        createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final probe = await factory.openDatabase(inMemoryDatabasePath);
    try {
      final rows = await probe.rawQuery('PRAGMA cipher_version');
      expect(
          rows.isNotEmpty &&
              (rows.single['cipher_version'] as String).startsWith('4.10.0'),
          isTrue,
          reason:
              'requires the SQLCipher 4.10.0 source pinned by sqlcipher_flutter_libs 0.6.8');
    } finally {
      await probe.close();
    }
  });
  for (final missingOriginalOlm in [false, true]) {
    test(
        'verified SQLCipher archive restores surviving Megolm; old Olm missing=$missingOriginalOlm',
        () async {
      const home = 'https://example.test',
          user = '@synthetic:example.test',
          roomId = '!synthetic:example.test';
      final artifacts = p.normalize(p.absolute(
          '../../docs/verification/artifacts/2026-10-03/search-camera-history'));
      final directory =
          await Directory(artifacts).createTemp('task-3b-archive-');
      final store = SecureSessionStore(_Secrets());
      await store.selectMatrixAccount(home, user);
      final scope = await store.matrixStorageScope(),
          cipher = await store.matrixDatabaseKey();
      final account = olm.Account()..create();
      final fingerprint =
          jsonDecode(account.identity_keys())['ed25519'] as String;
      await store.saveMatrixBinding(MatrixLocalBinding(
          version: 2,
          matrixUserId: user,
          deviceId: 'OLD',
          homeserver: home,
          databaseGeneration: 'old-generation',
          ed25519Fingerprint: fingerprint));
      final snapshot = await store.peekActiveMatrixIdentity();
      final path = p.join(directory.path, 'liuhetong_matrix_$scope.sqlite');
      final sqlFactory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final helper = SQfLiteEncryptionHelper(
          factory: sqlFactory, path: path, cipher: cipher);
      final sql = await sqlFactory.openDatabase(path,
          options: OpenDatabaseOptions(onConfigure: helper.applyPragmaKey));
      final old =
          MatrixSdkDatabase('old', database: sql, sqfliteFactory: sqlFactory);
      await old.open();
      final outbound = olm.OutboundGroupSession()..create();
      final inbound = olm.InboundGroupSession()..create(outbound.session_key());
      final session = outbound.session_id();
      final ciphertext = outbound.encrypt(jsonEncode({
        'room_id': roomId,
        'type': EventTypes.Message,
        'content': {
          'msgtype': MessageTypes.Text,
          'body': 'synthetic-archive-fixture'
        }
      }));
      await old.insertClient(
          'old',
          home,
          'revoked-synthetic-old',
          null,
          null,
          user,
          'OLD',
          'old',
          null,
          missingOriginalOlm ? null : account.pickle(user));
      await old.storeInboundGroupSession(
          roomId,
          session,
          inbound.pickle(user),
          jsonEncode({'algorithm': AlgorithmTypes.megolmV1AesSha2}),
          '{}',
          '{}',
          'sender',
          '{}');
      await sql.close();
      inbound.free();
      outbound.free();
      account.free();
      await store.prepareFreshDeviceForConfirmedRecovery(
          expectedHomeserver: home,
          expectedUserId: user,
          expectedSnapshot: snapshot,
          scopeHasDatabaseFiles: (candidate) =>
              File(p.join(directory.path, 'liuhetong_matrix_$candidate.sqlite'))
                  .exists());
      final freshSql = await sqlFactory.openDatabase(inMemoryDatabasePath);
      final freshDb = MatrixSdkDatabase('fresh',
          database: freshSql, sqfliteFactory: sqlFactory);
      await freshDb.open();
      final fresh = _Fresh(freshDb, user)
        ..homeserver = Uri.parse(home)
        ..accessToken = 'synthetic-new-authorized';
      final owner =
          RecoveryOperationOwner(identity: fresh, isCurrent: () => true);
      fresh.recoveryOwner = owner;
      final factory = MatrixClientFactory(
          sessionStore: store,
          homeserver: Uri.parse(home),
          supportDirectoryPath: () async => directory.path);
      final decoder = olm.PkDecryption();
      final public = decoder.generate_key();
      var pages = 0;
      try {
        await factory.migrateRecoveryArchives(fresh, owner, (read) async {
          final rows = await read(null);
          pages++;
          expect(rows.length, 1);
          expect((await read(rows.last.sessionId)).length, 0);
          final encrypted = generateUploadKeysImplementation(
              GenerateUploadKeysArgs(pubkey: public, userId: user, dbSessions: [
            DbInboundGroupSessionBundle(dbSession: rows.single, verified: false)
          ]));
          final data = encrypted.rooms[roomId]!.sessions[session]!.sessionData;
          final payload = Map<String, dynamic>.from(jsonDecode(decoder.decrypt(
              data['ephemeral'] as String,
              data['mac'] as String,
              data['ciphertext'] as String)));
          expect(
              payload.containsKey('room_id') ||
                  payload.containsKey('session_id'),
              isFalse);
          expect(
              await fresh.crypto.keyManager
                  .importRecoverySession(roomId, session, 'sender', payload),
              isTrue);
        });
        expect(pages, 1);
        final room = Room(id: roomId, client: fresh);
        final event = Event.fromJson({
          'event_id': r'$archive-fixture',
          'sender': user,
          'origin_server_ts': 1,
          'type': EventTypes.Encrypted,
          'content': <String, dynamic>{
            'algorithm': AlgorithmTypes.megolmV1AesSha2,
            'session_id': session,
            'sender_key': 'sender',
            'ciphertext': ciphertext
          }
        }, room);
        final decoded = fresh.crypto.decryptRoomEventSync(roomId, event);
        expect(
            decoded.type == EventTypes.Message &&
                decoded.body == 'synthetic-archive-fixture',
            isTrue);
        final foreign = _Fresh(freshDb, '@other:example.test')
          ..homeserver = Uri.parse(home);
        var foreignPages = 0;
        await factory.migrateRecoveryArchives(foreign,
            RecoveryOperationOwner(identity: foreign, isCurrent: () => true),
            (_) async {
          foreignPages++;
        });
        expect(foreignPages, 0);
      } finally {
        await owner.drain();
        fresh.crypto.keyManager.clearInboundGroupSessions();
        decoder.free();
        await freshSql.close();
        final resolved = p.normalize(p.absolute(directory.path));
        if (!p.isWithin(artifacts, resolved) ||
            !p.basename(resolved).startsWith('task-3b-archive-')) {
          throw StateError('Unexpected fixture directory');
        }
        await directory.delete(recursive: true);
      }
    });
  }
}
