import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_recovery_vault.dart';
import 'package:liuhetong_mobile/features/matrix/recent_history_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/utils/session_key.dart';
import 'package:matrix/matrix.dart';
import 'package:olm/olm.dart' as olm;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Client extends Client {
  _Client({DatabaseApi? database, http.Client? transport})
      : super('recovery-crypto',
            databaseBuilder: database == null ? null : (_) => database,
            httpClient: transport);
  @override
  String get userID => '@synthetic:example.test';
  @override
  String get deviceID => 'SYNTHETIC';
  late final crypto = Encryption(client: this);
  @override
  Encryption get encryption => crypto;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(olm.init);
  test('SDK recovery admission is revoked when the captured homeserver changes',
      () async {
    final server = _VaultServer();
    final client = await _open(server);
    final matrix = MatrixSdkE2eeClient(client, homeserver: client.homeserver!);
    final owner = client.recoveryOwner!;
    expect(owner.active, isTrue);
    client.homeserver = Uri.parse('https://different.example.test');
    expect(owner.active, isFalse);
    expect(() => owner.write(() async => fail('wrong endpoint write')),
        throwsStateError);
    await matrix.suspend();
    server.decoder.free();
  });
  test('actual timed-out vault PUT stays admitted until the transport settles',
      () async {
    final server = _VaultServer(), secure = _Secrets();
    final store = SecureSessionStore(secure);
    await store.saveSession(
        accessToken: _token,
        refreshToken: 'synthetic',
        matrixUserId: '@synthetic:example.test');
    final client = await _open(server);
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: client.homeserver!,
        lifecycleDrainTimeout: const Duration(milliseconds: 20));
    final vault = MatrixRecoveryVault(
        client: client,
        owner: client.recoveryOwner!,
        store: store,
        status: VaultSyncStatus());
    final entered = Completer<void>(), release = Completer<void>();
    server.beforeEnrollment = () async {
      entered.complete();
      await release.future;
    };
    final run = vault.initialize();
    final responseDeadline = expectLater(run, throwsA(isA<TimeoutException>()));
    await entered.future;
    await responseDeadline;
    expect(client.recoveryOwner!.pendingWrites, 1);
    await expectLater(matrix.suspend(), throwsA(isA<TimeoutException>()));
    expect((client.database! as MatrixSdkDatabase).database!.isOpen, isTrue);
    release.complete();
    await client.recoveryOwner!.drain();
    expect(secure.values.keys.any((k) => k.endsWith('.material')), isFalse);
    expect(secure.values.keys.any((k) => k.endsWith('.enrollment')), isTrue);
    expect(vault.status.protected, 0);
    await matrix.suspend();
    server.decoder.free();
  });
  test(
      'actual history transaction drains before suspend and cannot publish late',
      () async {
    final server = _VaultServer();
    final client = await _open(server, held: true);
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: client.homeserver!,
        lifecycleDrainTimeout: const Duration(milliseconds: 20));
    final db = client.database! as _HeldDatabase;
    final room = Room(
        id: '!held-history:example.test',
        client: client,
        membership: Membership.join);
    client.rooms.add(room);
    server.history = {
      'event_id': r'$held-history',
      'type': EventTypes.Message,
      'sender': client.userID,
      'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
      'content': {'msgtype': MessageTypes.Text, 'body': 'synthetic'}
    };
    db.boundary = 'history';
    var changes = 0;
    final status = VaultSyncStatus();
    final coordinator = RecentHistoryCoordinator(
        client: client,
        owner: client.recoveryOwner!,
        databaseGeneration: 'held-generation',
        status: status,
        onChanged: () => changes++);
    final run = coordinator.runOnce();
    final failure = expectLater(run, throwsStateError);
    await db.entered.future;
    await expectLater(matrix.suspend(), throwsA(isA<TimeoutException>()));
    expect(db.database!.isOpen, isTrue);
    db.release.complete();
    await failure;
    await client.recoveryOwner!.drain();
    expect(await db.getEventById(r'$held-history', room), isNotNull);
    expect(changes, 0);
    expect(status.downloaded, 0);
    await matrix.suspend();
    server.decoder.free();
  });
  test('missing-key continuation walks have only one query in flight',
      () async {
    final server = _VaultServer(), store = SecureSessionStore(_Secrets());
    await store.saveSession(
        accessToken: _token,
        refreshToken: 'synthetic',
        matrixUserId: '@synthetic:example.test');
    final client = await _open(server);
    final vault = MatrixRecoveryVault(
        client: client,
        owner: client.recoveryOwner!,
        store: store,
        status: VaultSyncStatus());
    final entered = Completer<void>(), release = Completer<void>();
    server.beforeQuery = () async {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    try {
      final one =
          vault.restoreMissing({('!one:example.test', 'one'): 'sender'});
      final two =
          vault.restoreMissing({('!two:example.test', 'two'): 'sender'});
      await entered.future;
      expect(server.queryCount, 1);
      release.complete();
      expect(await one, 0);
      expect(await two, 0);
      expect(server.queryCount, 2);
    } finally {
      await client.dispose();
      server.decoder.free();
    }
  });
  test(
      'held durable receipt never publishes protection or deletes retry journal after revoke',
      () async {
    final server = _VaultServer(), secure = _Secrets();
    final isolated = SecureSessionStore(secure);
    await isolated.saveSession(
        accessToken: _token,
        refreshToken: 'synthetic',
        matrixUserId: '@synthetic:example.test');
    final client = await _open(server, held: true),
        native = olm.OutboundGroupSession()..create();
    final db = client.database! as _HeldDatabase;
    await client.crypto.keyManager.setInboundGroupSession(
        '!target:example.test', native.session_id(), 'sender', {
      'algorithm': AlgorithmTypes.megolmV1AesSha2,
      'session_key': native.session_key()
    });
    final vault = MatrixRecoveryVault(
        client: client,
        owner: client.recoveryOwner!,
        store: isolated,
        status: VaultSyncStatus());
    db.boundary = 'receipt';
    final run = vault.archiveAvailable();
    await db.entered.future;
    final failure = expectLater(run, throwsStateError);
    client.recoveryOwner!.revoke();
    var settled = false;
    final drain = client.recoveryOwner!.drain().then((_) => settled = true);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    db.release.complete();
    await failure;
    await drain;
    expect(vault.status.protected, 0);
    expect(secure.values.keys.any((k) => k.endsWith('.pending')), isTrue);
    native.free();
    client.crypto.keyManager.clearInboundGroupSessions();
    await client.dispose();
    server.decoder.free();
  });
  test('actual SDK initial sync adopts the authorized identity before key work',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('login-owner',
        database: sql, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    late Client client;
    bool? admittedAtInitialSync;
    final transport = MockClient((request) async {
      if (request.url.path.endsWith('/versions')) {
        return http.Response('{"versions":["v1.11"]}', 200);
      }
      if (request.url.path.endsWith('/keys/upload')) {
        return http.Response(
            jsonEncode({
              'one_time_key_counts': {
                'signed_curve25519':
                    (jsonDecode(request.body)['one_time_keys'] as Map?)
                            ?.length ??
                        0
              }
            }),
            200);
      }
      if (request.url.path.endsWith('/filter')) {
        return http.Response('{"filter_id":"synthetic"}', 200);
      }
      if (request.url.path.endsWith('/keys/query')) {
        return http.Response('{"device_keys":{}}', 200);
      }
      if (request.url.path.endsWith('/sync')) {
        admittedAtInitialSync = client.recoveryOwner?.active;
        return http.Response('{"next_batch":"synthetic-head","rooms":{}}', 200);
      }
      return http.Response('{}', 200);
    });
    client =
        Client('login-owner', databaseBuilder: (_) => db, httpClient: transport)
          ..backgroundSync = false;
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://example.test'));
    try {
      await client.init(
          newToken: 'synthetic',
          newHomeserver: Uri.parse('https://example.test'),
          newUserID: '@synthetic:example.test',
          newDeviceID: 'NEW',
          newDeviceName: 'synthetic');
      expect(admittedAtInitialSync, isTrue);
      expect(client.recoveryOwner!.active, isTrue);
      expect(matrix.userId, '@synthetic:example.test');
    } finally {
      await client.recoveryOwner!.drain();
      await client.dispose();
    }
  });
  test(
      'automatic terminal history stays partial then replays after a key becomes available',
      () async {
    final server = _VaultServer(), store = SecureSessionStore(_Secrets());
    await store.saveSession(
        accessToken: _token,
        refreshToken: 'synthetic',
        matrixUserId: '@synthetic:example.test');
    final source = await _open(server),
        native = olm.OutboundGroupSession()..create();
    final room = Room(
        id: '!target:example.test',
        client: source,
        membership: Membership.join);
    source.rooms.add(room);
    final id = native.session_id();
    await source.crypto.keyManager.setInboundGroupSession(
        room.id, id, 'sender', {
      'algorithm': AlgorithmTypes.megolmV1AesSha2,
      'session_key': native.session_key()
    });
    final event = {
      'event_id': r'$automatic',
      'sender': source.userID,
      'origin_server_ts': 1000,
      'type': EventTypes.Encrypted,
      'content': <String, dynamic>{
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'session_id': id,
        'sender_key': 'sender',
        'ciphertext': native.encrypt(jsonEncode({
          'room_id': room.id,
          'type': EventTypes.Message,
          'content': {'msgtype': MessageTypes.Text, 'body': 'synthetic'}
        }))
      }
    };
    final sourceVault = MatrixRecoveryVault(
        client: source,
        owner: source.recoveryOwner!,
        store: store,
        status: VaultSyncStatus());
    await sourceVault.archiveAvailable();
    final candidate = server.candidate;
    server.candidate = null;
    server.history = event;
    source.crypto.keyManager.clearInboundGroupSessions();
    await source.dispose();
    native.free();
    final fresh = await _open(server), status = VaultSyncStatus();
    final target =
        Room(id: room.id, client: fresh, membership: Membership.join);
    fresh.rooms.add(target);
    final vault = MatrixRecoveryVault(
        client: fresh,
        owner: fresh.recoveryOwner!,
        store: store,
        status: status);
    final coordinator = RecentHistoryCoordinator(
        client: fresh,
        owner: fresh.recoveryOwner!,
        databaseGeneration: 'fresh',
        status: status,
        vault: vault,
        now: DateTime.fromMillisecondsSinceEpoch(10000000));
    try {
      await coordinator.runOnce();
      expect([status.downloaded, status.decrypted, status.missing], [1, 0, 1]);
      expect(status.phase, VaultSyncPhase.partial);
      server.candidate = candidate;
      await coordinator.runOnce();
      expect([status.downloaded, status.decrypted, status.missing], [1, 1, 0]);
      expect(status.phase, VaultSyncPhase.ready);
      expect(server.historyRequests, 1,
          reason:
              'completed coverage retries ciphertext from bounded durable storage');
      expect((await fresh.database!.getEventById(r'$automatic', target))!.type,
          EventTypes.Message);
    } finally {
      coordinator.revoke();
      await fresh.recoveryOwner!.drain();
      fresh.crypto.keyManager.clearInboundGroupSessions();
      await fresh.dispose();
      server.decoder.free();
    }
  });

  for (final mode in [
    'match',
    'mismatch',
    'revoked',
    'revoked-metadata',
    'wrong-sender',
    'wrong-session',
    'tamper'
  ]) {
    test('automatic needed native backup $mode uses validated SDK import',
        () async {
      final server = _VaultServer();
      final client = await _open(server);
      final native = olm.OutboundGroupSession()..create();
      final inbound = olm.InboundGroupSession()..create(native.session_key());
      final room = Room(
          id: '!native:example.test',
          client: client,
          membership: Membership.join);
      client.rooms.add(room);
      final id = native.session_id();
      final wrongNative = olm.OutboundGroupSession()..create();
      final wrongInbound = olm.InboundGroupSession()
        ..create(wrongNative.session_key());
      final pk = olm.PkEncryption()..set_recipient_key(server.public);
      final encrypted = pk.encrypt(jsonEncode({
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'sender_key': mode == 'wrong-sender' ? 'wrong-sender' : 'sender',
        'sender_claimed_keys': <String, String>{},
        'forwarding_curve25519_key_chain': <String>[],
        'session_key': mode == 'wrong-session'
            ? wrongInbound.export_session(0)
            : inbound.export_session(0)
      }));
      pk.free();
      inbound.free();
      wrongInbound.free();
      wrongNative.free();
      server.nativeSession = {
        'first_message_index': 0,
        'forwarded_count': 0,
        'is_verified': false,
        'session_data': {
          'ephemeral': encrypted.ephemeral,
          'mac': encrypted.mac,
          'ciphertext': encrypted.ciphertext
        }
      };
      if (mode == 'tamper') {
        (server.nativeSession!['session_data'] as Map)['mac'] = 'invalid';
      }
      client.accountData[EventTypes.MegolmBackup] =
          BasicEvent(type: EventTypes.MegolmBackup, content: {
        'encrypted': {
          'cached': {'ciphertext': 'synthetic-cache'}
        }
      });
      await client.database!.storeSSSSCache(
          EventTypes.MegolmBackup,
          'cached',
          'synthetic-cache',
          base64.encode(server.decoder.get_private_key()).replaceAll('=', ''));
      if (mode == 'mismatch') server.nativePublic = 'different';
      final nativeEntered = Completer<void>(),
          nativeRelease = Completer<void>();
      Future<void> holdNative() async {
        nativeEntered.complete();
        await nativeRelease.future;
      }

      if (mode == 'revoked') server.beforeNative = holdNative;
      if (mode == 'revoked-metadata') server.beforeNativeInfo = holdNative;
      server.history = {
        'event_id': r'$native-needed',
        'sender': client.userID,
        'origin_server_ts': 1000,
        'type': EventTypes.Encrypted,
        'content': {
          'algorithm': AlgorithmTypes.megolmV1AesSha2,
          'session_id': id,
          'sender_key': 'sender',
          'ciphertext': native.encrypt(jsonEncode({
            'room_id': room.id,
            'type': EventTypes.Message,
            'content': {'msgtype': MessageTypes.Text, 'body': 'synthetic'}
          }))
        }
      };
      final store = SecureSessionStore(_Secrets());
      await store.saveSession(
          accessToken: _token,
          refreshToken: 'synthetic',
          matrixUserId: client.userID);
      final status = VaultSyncStatus(),
          vault = MatrixRecoveryVault(
              client: client,
              owner: client.recoveryOwner!,
              store: store,
              status: VaultSyncStatus());
      final coordinator = RecentHistoryCoordinator(
          client: client,
          owner: client.recoveryOwner!,
          databaseGeneration: 'native',
          status: status,
          vault: vault,
          now: DateTime.fromMillisecondsSinceEpoch(10000000));
      try {
        if (mode.startsWith('revoked')) {
          final run = coordinator.runOnce();
          final failure = expectLater(run, throwsStateError);
          await nativeEntered.future;
          final captured = client.recoveryOwner!;
          captured.revoke();
          client.recoveryOwner =
              RecoveryOperationOwner(identity: Object(), isCurrent: () => true);
          nativeRelease.complete();
          await failure;
          expect(await client.database!.getInboundGroupSession(room.id, id),
              isNull);
        } else {
          await coordinator.runOnce();
          expect(status.decrypted, mode == 'match' ? 1 : 0);
          expect(server.nativeKeyReads, mode == 'mismatch' ? 0 : 1);
          if (mode == 'match') expect(server.candidate, isNotNull);
        }
      } finally {
        coordinator.revoke();
        await client.recoveryOwner!.drain();
        client.crypto.keyManager.clearInboundGroupSessions();
        native.free();
        await client.dispose();
        server.decoder.free();
      }
    });
  }
  test(
      'failed actual replay index leaves ciphertext durable and retries after cache restart',
      () async {
    final server = _VaultServer();
    final client = await _open(server, held: true);
    final db = client.database! as _HeldDatabase;
    final native = olm.OutboundGroupSession()..create();
    final room = Room(
        id: '!failed-index:example.test',
        client: client,
        membership: Membership.join);
    client.rooms.add(room);
    final id = native.session_id();
    await client.crypto.keyManager.setInboundGroupSession(
        room.id, id, 'sender', {
      'algorithm': AlgorithmTypes.megolmV1AesSha2,
      'session_key': native.session_key()
    });
    server.history = {
      'event_id': r'$failed-index',
      'sender': client.userID,
      'origin_server_ts': 1000,
      'type': EventTypes.Encrypted,
      'content': {
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'session_id': id,
        'sender_key': 'sender',
        'ciphertext': native.encrypt(jsonEncode({
          'room_id': room.id,
          'type': EventTypes.Message,
          'content': {'msgtype': MessageTypes.Text, 'body': 'synthetic'}
        }))
      }
    };
    for (var page = 0; page < 20; page++) {
      await db.commitRecoveryHistoryPage(room, 'old-seed', page, [
        for (var i = 0; i < 80; i++)
          {
            'event_id': '\$old-${page * 80 + i}',
            'type': EventTypes.Encrypted,
            'sender': client.userID,
            'origin_server_ts': -40000000000,
            'content': {
              'session_id': 'old-session-${page * 80 + i}',
              'sender_key': 'old-sender'
            }
          }
      ], {
        'revision': page + 1
      });
    }
    db.eventReads.clear();
    db.failIndexes = true;
    final errors = <SdkError>[];
    final errorSubscription =
        client.onEncryptionError.stream.listen(errors.add);
    final failedForeground = await client.crypto.decryptRoomEvent(
        room.id, Event.fromJson(server.history!, room),
        store: true, updateType: EventUpdateType.history);
    expect(failedForeground.type, EventTypes.Encrypted);
    final coordinator = RecentHistoryCoordinator(
        client: client,
        owner: client.recoveryOwner!,
        databaseGeneration: 'failed-index',
        status: VaultSyncStatus(),
        now: DateTime.fromMillisecondsSinceEpoch(10000000));
    try {
      await expectLater(coordinator.runOnce(), throwsA(isA<StateError>()));
      expect((await db.getEventById(r'$failed-index', room))!.type,
          EventTypes.Encrypted);
      expect(
          client.crypto.keyManager.getInboundGroupSession(room.id, id)!.indexes,
          isEmpty);
      db.failIndexes = false;
      client.crypto.keyManager.clearInboundGroupSessions();
      await coordinator.runOnce();
      expect((await db.getEventById(r'$failed-index', room))!.type,
          EventTypes.Message);
      expect(db.eventReads.any((id) => id.startsWith(r'$old-')), isFalse);
      expect(errors.map((error) => error.exception.toString()),
          everyElement(contains('E2EE_RECOVERY_INDEX_STORAGE_FAILED')));
      expect(errors, isNotEmpty);
      client.crypto.keyManager.clearInboundGroupSessions();
      expect(
          (await client.crypto.keyManager.loadInboundGroupSession(room.id, id))!
              .indexes,
          isNotEmpty);
    } finally {
      await errorSubscription.cancel();
      coordinator.revoke();
      await client.recoveryOwner!.drain();
      native.free();
      client.crypto.keyManager.clearInboundGroupSessions();
      await client.dispose();
      server.decoder.free();
    }
  });
  test(
      'CAS reconciliation protects a new operation while preserving exact ciphertext',
      () async {
    final server = _VaultServer()..conflictUpload = true;
    final store = SecureSessionStore(_Secrets());
    await store.saveSession(
        accessToken: _token,
        refreshToken: 'synthetic',
        matrixUserId: '@synthetic:example.test');
    final client = await _open(server),
        native = olm.OutboundGroupSession()..create();
    final room = Room(id: '!target:example.test', client: client);
    client.rooms.add(room);
    try {
      await client.crypto.keyManager.setInboundGroupSession(
          room.id, native.session_id(), 'sender', {
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'session_key': native.session_key()
      });
      final vault = MatrixRecoveryVault(
          client: client,
          owner: client.recoveryOwner!,
          store: store,
          status: VaultSyncStatus());
      await expectLater(
          vault.archiveAvailable(),
          throwsA(isA<VaultFailure>()
              .having((e) => e.code, 'code', 'retry_conflict')));
      expect(vault.status.protected, 0);
      await vault.archiveAvailable();
      expect(server.uploadDigests.length, 2);
      expect(server.uploadDigests.toSet().length, 2,
          reason: 'rejected CAS requires new operation and expected revision');
      expect(server.payloadDigests.toSet().length, 1,
          reason: 'reconciliation must retain original encrypted payload');
      expect(vault.status.protected, 1);
    } finally {
      native.free();
      client.crypto.keyManager.clearInboundGroupSessions();
      await client.dispose();
      server.decoder.free();
    }
  });
  test('service unavailable does not enroll or persist replacement material',
      () async {
    final server = _VaultServer()..unavailable = true;
    final secure = _Secrets();
    // Use the same genuine storage adapter contract with an isolated key store.
    final isolated = SecureSessionStore(secure);
    await isolated.saveSession(
        accessToken: _token,
        refreshToken: 'synthetic',
        matrixUserId: '@synthetic:example.test');
    final client = await _open(server);
    try {
      final vault = MatrixRecoveryVault(
          client: client,
          owner: client.recoveryOwner!,
          store: isolated,
          status: VaultSyncStatus());
      await expectLater(
          vault.initialize(),
          throwsA(isA<VaultFailure>()
              .having((e) => e.code, 'code', 'M_VAULT_UNAVAILABLE')));
      expect(server.enrolled, isFalse);
      expect(secure.values.keys.any((key) => key.contains('recovery_vault')),
          isFalse);
    } finally {
      await client.dispose();
      server.decoder.free();
    }
  });
  test(
      'held genuine secure material write drains after revoke and never starts a query',
      () async {
    final server = _VaultServer();
    final secure = _Secrets();
    final store = SecureSessionStore(secure);
    await store.saveSession(
        accessToken: _token,
        refreshToken: 'synthetic',
        matrixUserId: '@synthetic:example.test');
    final client = await _open(server);
    final entered = Completer<void>(), release = Completer<void>();
    secure.beforeWrite = (key) async {
      if (key.endsWith('.material')) {
        entered.complete();
        await release.future;
      }
    };
    final vault = MatrixRecoveryVault(
        client: client,
        owner: client.recoveryOwner!,
        store: store,
        status: VaultSyncStatus());
    final run = vault.restoreMissing(
        {('!target:example.test', 'synthetic-session'): 'sender'});
    await entered.future;
    final failed = expectLater(run, throwsStateError);
    client.recoveryOwner!.revoke();
    var drained = false;
    final drain = client.recoveryOwner!.drain().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    expect(client.recoveryOwner!.pendingWrites, 1);
    release.complete();
    await failed;
    await drain;
    expect(server.queryCount, 0);
    await client.dispose();
    server.decoder.free();
  });
  test('Business family is pinned before a held first secure read', () async {
    final server = _VaultServer(), secure = _Secrets();
    final store = SecureSessionStore(secure);
    await store.saveSession(
        accessToken: _token,
        refreshToken: 'synthetic',
        matrixUserId: '@synthetic:example.test');
    final client = await _open(server);
    final vault = MatrixRecoveryVault(
        client: client,
        owner: client.recoveryOwner!,
        store: store,
        status: VaultSyncStatus());
    final entered = Completer<void>(), release = Completer<void>();
    secure.beforeRead = (key) async {
      if (key == 'liuhetong.business_session.v1') {
        entered.complete();
        await release.future;
      }
    };
    final run = vault.initialize();
    await entered.future;
    final failed = expectLater(run, throwsA(isA<VaultFailure>()));
    await store.clearBusinessSession();
    release.complete();
    await failed;
    expect(server.enrolled, isFalse);
    expect(secure.values.keys.any((key) => key.endsWith('.material')), isFalse);
    await client.dispose();
    server.decoder.free();
  });
  test(
      'actual native exporter disposes each session on success invalid and throwing payload',
      () async {
    final server = _VaultServer();
    final client = await _open(server);
    final native = olm.OutboundGroupSession()..create();
    final room = Room(id: '!target:example.test', client: client);
    client.rooms.add(room);
    await client.crypto.keyManager.setInboundGroupSession(
        room.id, native.session_id(), 'sender', {
      'algorithm': AlgorithmTypes.megolmV1AesSha2,
      'session_key': native.session_key()
    });
    final stored =
        (await client.database!.getInboundGroupSessionsPage()).single;
    final args = GenerateUploadKeysArgs(
        pubkey: server.public,
        userId: client.userID,
        dbSessions: [
          DbInboundGroupSessionBundle(dbSession: stored, verified: false)
        ]);
    for (final mode in ['success', 'invalid', 'throw']) {
      SessionKey? allocated;
      RoomKeys export() =>
          generateUploadKeysImplementation(args, sessionFromDb: (record, key) {
            final session = SessionKey.fromDb(record, key);
            allocated = session;
            if (mode == 'invalid') session.dispose();
            if (mode == 'throw') {
              session.content['forwarding_curve25519_key_chain'] = 42;
            }
            return session;
          });
      if (mode == 'throw') {
        expect(export, throwsA(isA<TypeError>()));
      } else {
        export();
      }
      expect(allocated!.inboundGroupSession, isNull,
          reason: 'actual native handle freed on $mode');
    }
    native.free();
    client.crypto.keyManager.clearInboundGroupSessions();
    await client.dispose();
    server.decoder.free();
  });
  for (final boundary in ['import', 'index', 'outbound']) {
    test('actual SDK $boundary write remains admitted until SQLite settles',
        () async {
      final server = _VaultServer();
      final client = await _open(server, held: true);
      final matrix = MatrixSdkE2eeClient(client,
          homeserver: client.homeserver!,
          lifecycleDrainTimeout: const Duration(milliseconds: 20));
      final db = client.database! as _HeldDatabase;
      final room = Room(id: '!target:example.test', client: client);
      client.rooms.add(room);
      final native = olm.OutboundGroupSession()..create();
      final id = native.session_id();
      if (boundary != 'import') {
        await client.crypto.keyManager.setInboundGroupSession(
            room.id, id, 'sender', {
          'algorithm': AlgorithmTypes.megolmV1AesSha2,
          'session_key': native.session_key()
        });
      }
      final inbound = olm.InboundGroupSession()..create(native.session_key());
      if (boundary == 'outbound') {
        await db.storeOutboundGroupSession(
            room.id, native.pickle(client.userID), '{}', 1);
        await client.crypto.keyManager.loadOutboundGroupSession(room.id);
      }
      final payload = {
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'sender_key': 'sender',
        'forwarding_curve25519_key_chain': <String>[],
        'sender_claimed_keys': <String, String>{},
        'session_key': inbound.export_session(0)
      };
      inbound.free();
      db.boundary = boundary;
      Future<bool>? imported;
      if (boundary == 'import') {
        imported = client.crypto.keyManager
            .importRecoverySession(room.id, id, 'sender', payload);
      } else {
        final event = Event.fromJson({
          'event_id': r'$held',
          'sender': client.userID,
          'origin_server_ts': 1,
          'type': EventTypes.Encrypted,
          'content': <String, dynamic>{
            'algorithm': AlgorithmTypes.megolmV1AesSha2,
            'session_id': id,
            'sender_key': 'sender',
            'ciphertext': native.encrypt(jsonEncode({
              'room_id':
                  boundary == 'outbound' ? '!wrong:example.test' : room.id,
              'type': EventTypes.Message,
              'content': {'msgtype': MessageTypes.Text, 'body': 'synthetic'}
            }))
          }
        }, room);
        client.crypto.decryptRoomEventSync(room.id, event);
      }
      await db.entered.future;
      final failure =
          imported == null ? null : expectLater(imported, throwsStateError);
      await expectLater(matrix.suspend(), throwsA(isA<TimeoutException>()));
      expect(db.database!.isOpen, isTrue,
          reason: 'a response deadline cannot close an in-use SQLite handle');
      var drained = false;
      final drain = client.recoveryOwner!.drain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      expect(client.recoveryOwner!.pendingWrites, 1);
      db.release.complete();
      await failure;
      await drain;
      expect(client.recoveryOwner!.pendingWrites, 0);
      native.free();
      client.crypto.keyManager.clearInboundGroupSessions();
      await matrix.suspend();
      server.decoder.free();
    });
  }
  test(
      'standard SDK archive survives response loss and restores fresh device real Megolm',
      () async {
    final server = _VaultServer();
    final secure = _Secrets();
    final store = SecureSessionStore(secure);
    await store.saveSession(
        accessToken: _token,
        refreshToken: 'synthetic-refresh',
        matrixUserId: '@synthetic:example.test');
    final source = await _open(server);
    final room = Room(id: '!target:example.test', client: source);
    source.rooms.add(room);
    final outbound = olm.OutboundGroupSession()..create();
    final sessionId = outbound.session_id();
    final initialSessionKey = outbound.session_key();
    final ciphertext = outbound.encrypt(jsonEncode({
      'room_id': room.id,
      'type': EventTypes.Message,
      'content': {'msgtype': MessageTypes.Text, 'body': 'synthetic fixture'}
    }));
    try {
      await source.crypto.keyManager.setInboundGroupSession(
          room.id, sessionId, 'sender', {
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'session_key': initialSessionKey
      });
      final status = VaultSyncStatus();
      final vault = MatrixRecoveryVault(
          client: source,
          owner: source.recoveryOwner!,
          store: store,
          status: status);
      server.loseUploadResponse = true;
      await expectLater(
          vault.archiveAvailable(), throwsA(isA<http.ClientException>()));
      expect(status.protected, 0);
      await vault.archiveAvailable();
      expect(server.uploadDigests.length, 2);
      expect(server.uploadDigests.toSet().length, 1,
          reason: 'same protected ciphertext/op must replay');
      expect(status.protected, 1);
      source.crypto.keyManager.clearInboundGroupSessions();
      await source.dispose();
      final fresh = await _open(server);
      final freshRoom = Room(id: room.id, client: fresh);
      fresh.rooms.add(freshRoom);
      try {
        final restored = MatrixRecoveryVault(
            client: fresh,
            owner: fresh.recoveryOwner!,
            store: store,
            status: VaultSyncStatus());
        expect(
            await restored.restoreMissing({(room.id, sessionId): 'sender'}), 1);
        final event = Event.fromJson({
          'event_id': r'$restored',
          'sender': '@synthetic:example.test',
          'origin_server_ts': 1000,
          'type': EventTypes.Encrypted,
          'content': <String, dynamic>{
            'algorithm': AlgorithmTypes.megolmV1AesSha2,
            'session_id': sessionId,
            'sender_key': 'sender',
            'ciphertext': ciphertext
          }
        }, freshRoom);
        final decrypted = fresh.crypto.decryptRoomEventSync(room.id, event);
        expect(decrypted.type, EventTypes.Message);
        expect(decrypted.body == 'synthetic fixture', isTrue);
        expect(server.nativeRequests, 0,
            reason: 'locked native backup/SSSS/cross signing unchanged');
        final prior =
            fresh.crypto.keyManager.getInboundGroupSession(room.id, sessionId);
        expect(
            await restored
                .restoreMissing({(room.id, sessionId): 'wrong-sender'}),
            0);
        expect(
            fresh.crypto.keyManager.getInboundGroupSession(room.id, sessionId),
            same(prior));
        expect(
            await restored
                .restoreMissing({(room.id, 'renamed-session'): 'sender'}),
            0);
        expect(
            fresh.crypto.keyManager
                .getInboundGroupSession(room.id, 'renamed-session'),
            isNull);
        expect(
            await restored.restoreMissing(
                {('!relabelled:example.test', sessionId): 'sender'}),
            0);
        expect(
            (await fresh.database!.getInboundGroupSession(room.id, sessionId))!
                .roomId,
            room.id);
        final data =
            Map<String, dynamic>.from(server.candidate!['session_data']);
        server.candidate!['session_data'] = {...data, 'mac': 'AAAA'};
        expect(
            await restored.restoreMissing({(room.id, sessionId): 'sender'}), 0);
        expect(
            fresh.crypto.keyManager.getInboundGroupSession(room.id, sessionId),
            same(prior));
        server.materialOwner = '@other:example.test';
        final invalid = MatrixRecoveryVault(
            client: fresh,
            owner: fresh.recoveryOwner!,
            store: store,
            status: VaultSyncStatus());
        await expectLater(
            invalid.initialize(),
            throwsA(isA<VaultFailure>()
                .having((e) => e.code, 'code', 'invalid_binding')));
        expect(
            fresh.crypto.keyManager.getInboundGroupSession(room.id, sessionId),
            same(prior));
      } finally {
        await fresh.recoveryOwner!.drain();
        fresh.crypto.keyManager.clearInboundGroupSessions();
        await fresh.dispose();
      }
    } finally {
      outbound.free();
      server.decoder.free();
    }
  });
  for (final binding in <String?>['!other:example.test', null]) {
    test('Megolm rejects wrong or missing room binding before replay index',
        () async {
      final client = _Client();
      final room = Room(id: '!target:example.test', client: client);
      final outbound = olm.OutboundGroupSession()..create();
      try {
        final manager = client.crypto.keyManager;
        await manager
            .setInboundGroupSession(room.id, outbound.session_id(), 'sender', {
          'algorithm': AlgorithmTypes.megolmV1AesSha2,
          'session_key': outbound.session_key(),
        });
        final encrypted = Event.fromJson({
          'event_id': r'$synthetic',
          'sender': '@synthetic:example.test',
          'origin_server_ts': 1000,
          'type': EventTypes.Encrypted,
          'content': {
            'algorithm': AlgorithmTypes.megolmV1AesSha2,
            'session_id': outbound.session_id(),
            'sender_key': 'sender',
            'ciphertext': outbound.encrypt(jsonEncode({
              if (binding != null) 'room_id': binding,
              'type': EventTypes.Message,
              'content': {
                'msgtype': MessageTypes.Text,
                'body': 'synthetic fixture'
              },
            })),
          },
        }, room);
        final decoded = client.crypto.decryptRoomEventSync(room.id, encrypted);
        expect(decoded.type, EventTypes.Encrypted);
        expect(
            manager
                .getInboundGroupSession(room.id, outbound.session_id())!
                .indexes,
            isEmpty);
        manager.clearInboundGroupSessions();
      } finally {
        outbound.free();
      }
    });
  }
}

final _token = 'x.${base64Url.encode(utf8.encode(jsonEncode({
          'sub': 'synthetic-business',
          'family_id': 'synthetic-family',
          'device_id': 'synthetic-device'
        }))).replaceAll('=', '')}.x';

class _Secrets implements SecureKeyValueStore {
  final values = <String, String>{};
  Future<void> Function(String)? beforeRead, beforeWrite;
  @override
  Future<String?> read(String key) async {
    await beforeRead?.call(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await beforeWrite?.call(key);
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Future<_Client> _open(_VaultServer server, {bool held = false}) async {
  final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  final db = held
      ? _HeldDatabase(sql)
      : MatrixSdkDatabase('vault',
          database: sql, sqfliteFactory: databaseFactoryFfi);
  await db.open();
  final client = _Client(database: db, transport: MockClient(server.call));
  await client.init();
  client.homeserver = Uri.parse('https://example.test');
  client.accessToken = 'synthetic-matrix';
  client.recoveryOwner =
      RecoveryOperationOwner(identity: client, isCurrent: () => true);
  return client;
}

class _HeldDatabase extends MatrixSdkDatabase {
  _HeldDatabase(Database sql)
      : super('vault', database: sql, sqfliteFactory: databaseFactoryFfi);
  String? boundary;
  bool failIndexes = false;
  final eventReads = <String>[];
  @override
  Future<Event?> getEventById(String id, Room room) {
    eventReads.add(id);
    return super.getEventById(id, room);
  }

  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<bool> commitRecoveryHistoryPage(
      Room room,
      String key,
      int expectedRevision,
      List<Map<String, dynamic>> events,
      Map<String, dynamic> checkpoint) async {
    await hold('history');
    return super.commitRecoveryHistoryPage(
        room, key, expectedRevision, events, checkpoint);
  }

  @override
  Future<void> storeRecoveryRecord(
      String key, Map<String, dynamic> value) async {
    await hold('receipt');
    await super.storeRecoveryRecord(key, value);
  }

  Future<void> hold(String name) async {
    if (boundary == name) {
      entered.complete();
      await release.future;
    }
  }

  @override
  Future<void> storeInboundGroupSession(
      String room,
      String session,
      String pickle,
      String content,
      String indexes,
      String allowed,
      String sender,
      String claimed) async {
    await hold('import');
    await super.storeInboundGroupSession(
        room, session, pickle, content, indexes, allowed, sender, claimed);
  }

  @override
  Future<void> updateInboundGroupSessionIndexes(
      String indexes, String room, String session) async {
    await hold('index');
    if (failIndexes) throw StateError('synthetic storage failure');
    await super.updateInboundGroupSessionIndexes(indexes, room, session);
  }

  @override
  Future<void> removeOutboundGroupSession(String room) async {
    await hold('outbound');
    await super.removeOutboundGroupSession(room);
  }
}

class _VaultServer {
  final decoder = olm.PkDecryption();
  late final String public = decoder.generate_key();
  late final descriptor = <String, dynamic>{
    'version': '11111111-1111-4111-8111-111111111111',
    'algorithm': MatrixRecoveryVault.algorithm,
    'public_key': public,
    'public_fingerprint':
        sha256.convert(base64.decode(base64.normalize(public))).toString(),
    'revision': 1
  };
  bool enrolled = false,
      loseUploadResponse = false,
      conflictUpload = false,
      unavailable = false;
  String materialOwner = '@synthetic:example.test';
  int nativeRequests = 0, queryCount = 0;
  int nativeKeyReads = 0;
  String? nativePublic;
  Map<String, dynamic>? nativeSession;
  Future<void> Function()? beforeNative;
  Future<void> Function()? beforeNativeInfo;
  int historyRequests = 0;
  Map<String, dynamic>? history;
  Future<void> Function()? beforeQuery;
  Future<void> Function()? beforeEnrollment;
  final uploadDigests = <String>[];
  final payloadDigests = <String>[];
  Map<String, dynamic>? candidate;
  Future<http.Response> call(http.Request request) async {
    final path = request.url.path;
    if (history != null && path.endsWith('/timestamp_to_event')) {
      return http.Response('{"errcode":"M_UNRECOGNIZED"}', 404);
    }
    if (history != null && path.endsWith('/messages')) {
      historyRequests++;
      return http.Response(
          jsonEncode({
            'start': request.url.queryParameters['from'] ?? 'head',
            'chunk': [history]
          }),
          200);
    }
    if (nativeSession != null && path.contains('/room_keys/')) {
      if (path.endsWith('/version')) {
        await beforeNativeInfo?.call();
        return http.Response(
            jsonEncode({
              'version': 'native-v1',
              'algorithm': MatrixRecoveryVault.algorithm,
              'auth_data': {'public_key': nativePublic ?? public},
              'count': 1,
              'etag': 'synthetic'
            }),
            200);
      }
      nativeKeyReads++;
      await beforeNative?.call();
      return http.Response(jsonEncode(nativeSession), 200);
    }
    expect(request.headers['X-StarChat-Session'], isNotNull);
    if (unavailable) {
      return http.Response('{"errcode":"M_VAULT_UNAVAILABLE"}', 503);
    }
    if (!path.startsWith(MatrixRecoveryVault.base)) {
      nativeRequests++;
      return http.Response('{"errcode":"M_NOT_FOUND"}', 404);
    }
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    Map<String, dynamic> result;
    if (path.endsWith('/status')) {
      result = {
        'state': enrolled ? 'available' : 'absent',
        'collection': enrolled ? descriptor : null
      };
    } else if (path.contains('/enrollments/')) {
      await beforeEnrollment?.call();
      enrolled = true;
      result = descriptor;
    } else if (path.endsWith('/material')) {
      result = {
        ...descriptor,
        'server': 'example.test',
        'owner': materialOwner,
        'private_key':
            base64.encode(decoder.get_private_key()).replaceAll('=', '')
      };
    } else if (path.endsWith('/sessions/query')) {
      queryCount++;
      await beforeQuery?.call();
      final pair = (body['pairs'] as List).single as Map;
      final returned = candidate == null
          ? null
          : {
              ...candidate!,
              'room_id': pair['room_id'],
              'session_id': pair['session_id']
            };
      result = {
        'version': descriptor['version'],
        'revision': 2,
        'candidates': returned == null
            ? []
            : [
                {
                  ...returned,
                  'revision': 1,
                  'candidate_revision': 1,
                  'digest': MatrixRecoveryVault.candidateDigest(
                      '@synthetic:example.test',
                      descriptor['version'],
                      returned)
                }
              ],
        'missing': [],
        'continuation': null
      };
    } else {
      uploadDigests.add(sha256
          .convert(utf8.encode('${request.url.path}|${request.body}'))
          .toString());
      payloadDigests.add(sha256
          .convert(utf8.encode(
              jsonEncode((body['sessions'] as List).single['session_data'])))
          .toString());
      if (conflictUpload) {
        conflictUpload = false;
        final item = (body['sessions'] as List).single;
        return http.Response(
            jsonEncode({
              'errcode': 'M_REVISION_CONFLICT',
              'conflicts': [
                {
                  'room_id': item['room_id'],
                  'session_id': item['session_id'],
                  'revision': 2
                }
              ]
            }),
            409);
      }
      candidate = Map<String, dynamic>.from((body['sessions'] as List).single)
        ..remove('expected_revision');
      result = {
        'version': descriptor['version'],
        'revision': 2,
        'receipts': [
          {
            'room_id': candidate!['room_id'],
            'session_id': candidate!['session_id'],
            'revision': 1,
            'candidate_revision': 1,
            'digest': MatrixRecoveryVault.candidateDigest(
                '@synthetic:example.test', descriptor['version'], candidate!)
          }
        ]
      };
      if (loseUploadResponse) {
        loseUploadResponse = false;
        throw http.ClientException('synthetic response loss');
      }
    }
    return http.Response(jsonEncode(result), 200);
  }
}
