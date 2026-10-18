import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption/encryption.dart';
import 'package:matrix/encryption/utils/outbound_group_session.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';

class _Store extends Fake implements DatabaseApi {
  final reads = <Completer<OutboundGroupSession?>>[];
  final entered = Completer<void>();
  @override
  Future<OutboundGroupSession?> getOutboundGroupSession(String id, String key) {
    final result = Completer<OutboundGroupSession?>();
    reads.add(result);
    if (!entered.isCompleted) entered.complete();
    return result.future;
  }
}

class _Client extends Client {
  _Client() : super('load-flight-test');
  _Store store = _Store();
  String account = '@fixture:test';
  String device = 'FIXTURE';
  late final crypto = Encryption(client: this);
  @override
  Encryption get encryption => crypto;
  @override
  DatabaseApi get database => store;
  @override
  String get userID => account;
  @override
  String get deviceID => device;
}

class _EncryptedRoom extends Room {
  _EncryptedRoom(Client client, String id)
      : super(client: client, id: id, membership: Membership.join);
  bool encryptionActive = true;
  @override
  bool get encrypted => encryptionActive;
}

class _Session extends OutboundGroupSession {
  _Session()
      : super(
            devices: {},
            creationTime: DateTime.now(),
            outboundGroupSession: null,
            key: 'fixture');
  bool disposed = false;
  @override
  bool get isValid => !disposed;
  @override
  void dispose() {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final change in ['left', 'hidden', 'unencrypted']) {
    test('wrapper discards held preload when room becomes $change', () async {
      SharedPreferences.setMockInitialValues({});
      final client = _Client();
      final room = _EncryptedRoom(client, '!room:test');
      client.rooms.add(room);
      final wrapper = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://test'),
          readContinuityMetadata: (active) async =>
              MatrixClientContinuityMetadata(
                  isLoggedIn: true,
                  userId: active.userID,
                  deviceId: active.deviceID,
                  ed25519Fingerprint: 'fixture',
                  databaseGeneration: 'fixture'),
          suspendClient: (_) async {});
      wrapper.prioritizeRoomDisplay(room.id);
      await client.store.entered.future.timeout(const Duration(seconds: 3));
      switch (change) {
        case 'left':
          room.membership = Membership.leave;
        case 'hidden':
          room.roomAccountData[conversationPreferenceType] = BasicRoomEvent(
              type: conversationPreferenceType, content: {'hidden': true});
        case 'unencrypted':
          room.encryptionActive = false;
      }
      final old = _Session();
      client.store.reads.single.complete(old);
      await Future<void>.delayed(Duration.zero);
      try {
        expect(old.disposed, isTrue);
        expect(
            client.crypto.keyManager.getOutboundGroupSession(room.id), isNull);
      } finally {
        await wrapper.suspend();
        client.crypto.keyManager.dispose();
        await client.dispose();
      }
    });
  }
  test('wrapper suspension revokes held warmup before manager disposal',
      () async {
    SharedPreferences.setMockInitialValues({});
    final client = _Client();
    client.rooms.add(_EncryptedRoom(client, '!room:test'));
    final old = _Session();
    final wrapper = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: true,
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fixture',
                databaseGeneration: 'fixture'),
        suspendClient: (_) async {
          // This callback runs only after operations drain. The optional load
          // must already have rejected its late result before disposal.
          expect(old.disposed, isTrue);
          expect(client.crypto.keyManager.getOutboundGroupSession('!room:test'),
              isNull);
        });
    wrapper.prioritizeRoomDisplay('!room:test');
    await client.store.entered.future.timeout(const Duration(seconds: 3));
    final suspension = wrapper.suspend();
    client.store.reads.single.complete(old);
    await suspension;
    client.crypto.keyManager.dispose();
    await client.dispose();
  });
  test('prewarm and two send-side loads join one unfinished database load',
      () async {
    final client = _Client();
    final manager = Encryption(client: client).keyManager;
    var settled = 0;
    final a = manager.loadOutboundGroupSession('!room:test');
    final b =
        manager.loadOutboundGroupSession('!room:test').then((_) => settled++);
    final c =
        manager.loadOutboundGroupSession('!room:test').then((_) => settled++);
    await Future<void>.delayed(Duration.zero);
    expect(settled, 0);
    expect(client.store.reads, hasLength(1));
    final session = _Session();
    client.store.reads.single.complete(session);
    await Future.wait([a, b, c]);
    expect(manager.getOutboundGroupSession('!room:test'), same(session));
    manager.dispose();
  });

  test('old finally cannot remove the replacement load or replace its session',
      () async {
    final client = _Client();
    final manager = Encryption(client: client).keyManager;
    final a = manager.loadOutboundGroupSession('!room:test');
    manager.clearOutboundGroupSessions();
    final b = manager.loadOutboundGroupSession('!room:test');
    final old = _Session();
    client.store.reads.first.complete(old);
    await a;
    var settled = false;
    final c = manager
        .loadOutboundGroupSession('!room:test')
        .then((_) => settled = true);
    await Future<void>.delayed(Duration.zero);
    expect(client.store.reads, hasLength(2));
    expect(settled, isFalse);
    final newer = _Session();
    client.store.reads.last.complete(newer);
    await Future.wait([b, c]);
    expect(old.disposed, isTrue);
    expect(manager.getOutboundGroupSession('!room:test'), same(newer));
    manager.dispose();
  });

  test('creation waiting for first sync rejects a late obsolete preload',
      () async {
    final client = _Client();
    final sync = Completer<void>();
    client.firstSyncReceived = sync.future;
    final manager = Encryption(client: client).keyManager;
    final pending = manager.loadOutboundGroupSession('!room:test');
    final creation = manager.createOutboundGroupSession('!room:test');
    final rejected = expectLater(creation, throwsA(isA<Exception>()));
    await Future<void>.delayed(Duration.zero);
    final old = _Session();
    client.store.reads.single.complete(old);
    await pending;
    expect(old.disposed, isTrue);
    expect(manager.getOutboundGroupSession('!room:test'), isNull);
    sync.complete();
    await rejected;
    manager.dispose();
  });

  test('revoked optional publication predicate discards native result',
      () async {
    final client = _Client();
    final manager = Encryption(client: client).keyManager;
    var active = true;
    final pending = manager.loadOutboundGroupSession('!room:test',
        canPublish: () => active);
    active = false;
    final old = _Session();
    client.store.reads.single.complete(old);
    await pending;
    expect(old.disposed, isTrue);
    expect(manager.getOutboundGroupSession('!room:test'), isNull);
    final retry = manager.loadOutboundGroupSession('!room:test');
    expect(client.store.reads, hasLength(2));
    client.store.reads.last.complete(null);
    await retry;
    manager.dispose();
  });

  test('failed load can retry and absent record never creates a session',
      () async {
    final client = _Client();
    final manager = Encryption(client: client).keyManager;
    final a = manager.loadOutboundGroupSession('!room:test');
    final check = expectLater(a, throwsStateError);
    client.store.reads.single.completeError(StateError('fixture'));
    await check;
    final b = manager.loadOutboundGroupSession('!room:test');
    expect(client.store.reads, hasLength(2));
    client.store.reads.last.complete(null);
    await b;
    await manager.loadOutboundGroupSession('!room:test');
    expect(client.store.reads, hasLength(2));
    expect(manager.getOutboundGroupSession('!room:test'), isNull);
    manager.dispose();
  });

  for (final boundary in [
    'clear',
    'dispose',
    'account',
    'device',
    'database',
    'room-wipe'
  ]) {
    test('late load is rejected and released after $boundary', () async {
      final client = _Client();
      final manager = Encryption(client: client).keyManager;
      final pending = manager.loadOutboundGroupSession('!room:test');
      final oldStore = client.store;
      switch (boundary) {
        case 'clear':
          manager.clearOutboundGroupSessions();
        case 'dispose':
          manager.dispose();
        case 'account':
          client.account = '@other:test';
        case 'device':
          client.device = 'OTHER';
        case 'database':
          client.store = _Store();
        case 'room-wipe':
          await manager.clearOrUseOutboundGroupSession('!room:test',
              wipe: true);
      }
      final old = _Session();
      oldStore.reads.single.complete(old);
      await pending;
      expect(manager.getOutboundGroupSession('!room:test'), isNull);
      expect(old.disposed, isTrue);
      manager.dispose();
    });
  }
}
