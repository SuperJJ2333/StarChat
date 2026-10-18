import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:olm/olm.dart' as olm;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sql;
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';

class _Secure implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Client extends Client {
  _Client(super.name, {super.databaseBuilder, super.httpClient});
  DatabaseApi? replacementDatabase;
  Encryption? replacementEncryption;
  @override
  DatabaseApi? get database => replacementDatabase ?? super.database;
  @override
  Encryption? get encryption => replacementEncryption ?? super.encryption;
}

class _ControlledEncryption implements Encryption {
  _ControlledEncryption(this.delegate, {this.hold = false, this.fail = false});
  final Encryption delegate;
  final bool hold;
  final bool fail;
  final entered = Completer<void>();
  final release = Completer<void>();
  final exited = Completer<void>();
  var calls = 0;
  @override
  get client => delegate.client;
  @override
  get keyManager => delegate.keyManager;
  @override
  bool get enabled => delegate.enabled;
  @override
  Future<Event> decryptRoomEvent(String roomId, Event event,
      {bool store = false,
      EventUpdateType updateType = EventUpdateType.timeline}) async {
    if (calls++ == 0) {
      entered.complete();
      if (hold) await release.future;
      if (fail) throw StateError('synthetic optional local decode failure');
      final result = await delegate.decryptRoomEvent(roomId, event,
          store: store, updateType: updateType);
      exited.complete();
      return result;
    }
    return delegate.decryptRoomEvent(roomId, event,
        store: store, updateType: updateType);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Database extends MatrixSdkDatabase {
  _Database(super.name, {super.database, super.sqfliteFactory});
  final postLoadEntered = Completer<void>();
  final postLoadRelease = Completer<void>();
  bool hold = false;
  bool failFreshRead = false;
  int injectedReadFailures = 0;
  final limits = <int?>[];
  Future<void> Function(Room)? afterRead;
  @override
  Future<List<Event>> getEventList(Room room,
      {int start = 0, bool onlySending = false, int? limit}) async {
    if (hold && failFreshRead && limit == 40 && limits.contains(40)) {
      failFreshRead = false;
      injectedReadFailures++;
      throw StateError('synthetic optional repair SQL failure');
    }
    final events = await super.getEventList(room,
        start: start, onlySending: onlySending, limit: limit);
    if (hold) {
      limits.add(limit);
      final hook = afterRead;
      afterRead = null;
      await hook?.call(room);
    }
    return events;
  }

  @override
  Future<List<Event>> getUnimportantRoomEventStatesForRoom(
      List<String> events, Room room) async {
    if (hold) {
      if (!postLoadEntered.isCompleted) postLoadEntered.complete();
      await postLoadRelease.future;
    }
    return super.getUnimportantRoomEventStatesForRoom(events, room);
  }
}

class _Fixture {
  _Fixture(
      this.database, this.connection, this.client, this.owner, this.secure);
  final _Database database;
  final sql.Database connection;
  final _Client client;
  final MatrixSdkE2eeClient owner;
  final SecureSessionStore secure;
  static Future<_Fixture> create(String name) async {
    SharedPreferences.setMockInitialValues({});
    await olm.init();
    final secure = SecureSessionStore(_Secure());
    final key = await secure.matrixDatabaseKey();
    final factory =
        sql.createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final connection = await factory.openDatabase(sql.inMemoryDatabasePath,
        options: sql.OpenDatabaseOptions(onConfigure: (db) async {
      await db.execute("PRAGMA key = '$key'");
    }));
    expect(await connection.rawQuery('PRAGMA cipher_version'), isNotEmpty);
    final database =
        _Database(name, database: connection, sqfliteFactory: factory);
    await database.open();
    const user = '@decode:synthetic.test';
    final account = olm.Account()..create();
    final fingerprint =
        (jsonDecode(account.identity_keys()) as Map)['ed25519'] as String;
    await database.insertClient(name, 'https://synthetic.test', 'synthetic',
        null, null, user, 'SYNTHETIC', 'fixture', null, account.pickle(user));
    account.free();
    await secure.saveSession(
        accessToken: 'synthetic',
        refreshToken: 'synthetic',
        matrixUserId: user);
    await secure.saveMatrixBinding(MatrixLocalBinding(
        version: 2,
        matrixUserId: user,
        deviceId: 'SYNTHETIC',
        homeserver: 'https://synthetic.test',
        databaseGeneration: 'generation',
        ed25519Fingerprint: fingerprint));
    final seed = Client(name)..setUserId(user);
    final seedRoom = Room(id: '!decode:synthetic.test', client: seed);
    await connection.insert(
        'box_rooms', {'k': seedRoom.id, 'v': jsonEncode(seedRoom.toJson())});
    for (final entry in <String, Map<String, Object>>{
      EventTypes.Encryption: {'algorithm': AlgorithmTypes.megolmV1AesSha2},
      EventTypes.RoomName: {'name': 'Synthetic decode room'},
    }.entries) {
      await connection.insert('box_preload_room_states', {
        'k': '${seedRoom.id}|${entry.key}',
        'v': jsonEncode({
          '': {
            'event_id': 'state-${entry.key}',
            'type': entry.key,
            'state_key': '',
            'sender': user,
            'origin_server_ts': 1,
            'content': entry.value
          }
        })
      });
    }
    final client = _Client(name,
        databaseBuilder: (_) async => database,
        httpClient: MockClient((_) async => http.Response('{}', 404)))
      ..backgroundSync = false;
    await client.init();
    expect(client.isInitializationPending, isFalse);
    final room = client.getRoomById(seedRoom.id)!;
    final outbound = olm.OutboundGroupSession()..create();
    try {
      await client.encryption!.keyManager.setInboundGroupSession(
          room.id, outbound.session_id(), 'synthetic-sender', {
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'session_key': outbound.session_key()
      });
      for (var index = 0; index < 40; index++) {
        await database.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': 'message-$index',
                  'type': EventTypes.Encrypted,
                  'sender': user,
                  'origin_server_ts': 1000 + index,
                  'content': {
                    'algorithm': AlgorithmTypes.megolmV1AesSha2,
                    'session_id': outbound.session_id(),
                    'sender_key': 'synthetic-sender',
                    'ciphertext': outbound.encrypt(jsonEncode({
                      'room_id': room.id,
                      'type': EventTypes.Message,
                      'content': {
                        'msgtype': 'm.text',
                        'body': 'Decoded local $index'
                      }
                    }))
                  }
                }),
            client);
      }
      client.encryption!.keyManager.clearInboundGroupSessions();
    } finally {
      outbound.free();
    }
    expect(
        (await database.getEventList(room, limit: 40))
            .every((event) => event.type == EventTypes.Encrypted),
        isTrue);
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://synthetic.test'),
        secureSessionStore: secure,
        readContinuityMetadata: (_) async => MatrixClientContinuityMetadata(
            isLoggedIn: true,
            userId: user,
            deviceId: 'SYNTHETIC',
            ed25519Fingerprint: fingerprint,
            databaseGeneration: 'generation'));
    expect(owner.startupAdmission, isNull);
    database.hold = true;
    return _Fixture(database, connection, client, owner, secure);
  }

  Future<void> close() async {
    if (!database.postLoadRelease.isCompleted) {
      database.postLoadRelease.complete();
    }
    await owner.suspend();
    if (connection.isOpen) await connection.close();
  }
}

Future<void> _until(bool Function() test) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!test() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(test(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ready canonical lease decodes persisted E2EE before held postLoad',
      () async {
    final fixture = await _Fixture.create('decode-ready');
    MatrixRoomLease? lease;
    RoomTimelineCapability? timeline;
    var updates = 0;
    final hydrated = Completer<void>();
    try {
      lease = await fixture.owner.openRoomLease('!decode:synthetic.test');
      timeline = await lease.openRoomTimeline(
          cachedFirst: true,
          onUpdate: () => updates++,
          onHydrated: () => hydrated.complete());
      final sameTimeline = timeline;
      await fixture.database.postLoadEntered.future;
      await _until(() => timeline!
          .snapshot()
          .any((event) => event.text == 'Decoded local 39'));
      expect(fixture.database.postLoadRelease.isCompleted, isFalse);
      expect(
          timeline
              .snapshot()
              .where((event) => event.text.startsWith('Decoded local '))
              .length,
          40);
      expect(fixture.database.limits.first, 40);
      expect(updates, greaterThan(0));
      fixture.database.postLoadRelease.complete();
      await hydrated.future.timeout(const Duration(seconds: 3));
      expect(timeline.snapshot().length, 40);
      expect(timeline, same(sameTimeline));
      expect(timeline.snapshot().map((event) => event.id).toSet().length, 40);
    } finally {
      if (!fixture.database.postLoadRelease.isCompleted) {
        fixture.database.postLoadRelease.complete();
      }
      timeline?.dispose();
      await lease?.cancel();
      await fixture.close();
    }
  });

  for (final mutation in ['database', 'room', 'generation', 'cancel']) {
    test('early canonical SQL rejects changed $mutation', () async {
      final fixture = await _Fixture.create('decode-$mutation');
      final room = fixture.client.rooms.single;
      MatrixRoomLease? lease;
      Future<void>? canceling;
      try {
        lease = await fixture.owner.openRoomLease(room.id);
        fixture.database.afterRead = (_) async {
          switch (mutation) {
            case 'database':
              fixture.client.replacementDatabase = _Database('replacement');
            case 'room':
              fixture.client.rooms[0] =
                  Room(id: room.id, client: fixture.client);
            case 'generation':
              room.invalidateHistoryFragment();
            case 'cancel':
              canceling = lease!.cancel();
          }
        };
        await expectLater(
            lease.openRoomTimeline(cachedFirst: true, onUpdate: () {}),
            throwsStateError);
      } finally {
        fixture.client.replacementDatabase = null;
        fixture.client.rooms[0] = room;
        if (!fixture.database.postLoadRelease.isCompleted) {
          fixture.database.postLoadRelease.complete();
        }
        await canceling;
        await lease?.cancel();
        await fixture.close();
      }
    });
  }

  test('expired early display permit continues fresh canonical recovery',
      () async {
    final fixture = await _Fixture.create('decode-permit');
    MatrixRoomLease? lease;
    RoomTimelineCapability? timeline;
    Future<RoomTimelineCapability>? opening;
    try {
      lease = await fixture.owner.openRoomLease('!decode:synthetic.test');
      fixture.database.afterRead = (room) async {
        final ticket = fixture.secure.startupProjectionCoordinator!
            .beginMutation('synthetic-current-row-replacement');
        await ticket.beforeApply;
        await fixture.database.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': 'message-39',
                  'type': EventTypes.Message,
                  'sender': fixture.client.userID,
                  'origin_server_ts': 1039,
                  'content': {
                    'msgtype': 'm.text',
                    'body': 'Canonical replacement'
                  }
                }),
            fixture.client);
        ticket.finish(applied: true);
      };
      var published = false;
      opening = lease
          .openRoomTimeline(cachedFirst: true, onUpdate: () {})
          .then((value) {
        published = true;
        return value;
      });
      await fixture.database.postLoadEntered.future;
      expect(published, isFalse,
          reason: 'the expired pre-mutation SQL batch cannot be published');
      fixture.database.postLoadRelease.complete();
      timeline = await opening.timeout(const Duration(seconds: 3));
      await _until(() => timeline!
          .snapshot()
          .any((event) => event.text == 'Canonical replacement'));
      expect(
          timeline.snapshot().any((event) => event.text == 'Decoded local 39'),
          isFalse);
      expect(timeline.snapshot().map((event) => event.id).toSet().length,
          timeline.snapshot().length);
    } finally {
      if (!fixture.database.postLoadRelease.isCompleted) {
        fixture.database.postLoadRelease.complete();
      }
      timeline ??= await opening;
      timeline?.dispose();
      await lease?.cancel();
      await fixture.close();
    }
  });

  for (final mutation in [
    'database',
    'room',
    'generation',
    'cancel',
    'permit',
    'repair-sql-failure'
  ]) {
    test('in-flight local decode cannot publish after $mutation', () async {
      final fixture = await _Fixture.create('decode-late-$mutation');
      fixture.database.failFreshRead = mutation == 'repair-sql-failure';
      final room = fixture.client.rooms.single;
      final crypto =
          _ControlledEncryption(fixture.client.encryption!, hold: true);
      fixture.client.replacementEncryption = crypto;
      MatrixRoomLease? lease;
      RoomTimelineCapability? timeline;
      Future<void>? canceling;
      final hydrated = Completer<void>();
      var updates = 0;
      try {
        lease = await fixture.owner.openRoomLease(room.id);
        timeline = await lease.openRoomTimeline(
            cachedFirst: true,
            onUpdate: () => updates++,
            onHydrated: () => hydrated.complete());
        await crypto.entered.future.timeout(const Duration(seconds: 2));
        switch (mutation) {
          case 'database':
            fixture.client.replacementDatabase = _Database('replacement');
          case 'room':
            fixture.client.rooms[0] = Room(id: room.id, client: fixture.client);
          case 'generation':
            room.invalidateHistoryFragment();
          case 'cancel':
            canceling = lease.cancel();
          case 'permit':
          case 'repair-sql-failure':
            final ticket = fixture.secure.startupProjectionCoordinator!
                .beginMutation('synthetic-late-row-replacement');
            await ticket.beforeApply;
            await fixture.database.storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: {
                      'event_id': 'message-39',
                      'type': EventTypes.Message,
                      'sender': fixture.client.userID,
                      'origin_server_ts': 1039,
                      'content': {
                        'msgtype': 'm.text',
                        'body': 'Canonical late replacement'
                      }
                    }),
                fixture.client);
            ticket.finish(applied: true);
        }
        crypto.release.complete();
        await crypto.exited.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(Duration.zero);
        expect(updates, 0,
            reason: 'a retired decode must not notify its plaintext result');
        if (mutation == 'cancel') {
          expect(timeline.snapshot, throwsStateError);
        } else {
          expect(timeline.snapshot().any((e) => e.text == 'Decoded local 39'),
              isFalse);
        }
        if (mutation == 'permit' || mutation == 'repair-sql-failure') {
          await fixture.database.postLoadEntered.future
              .timeout(const Duration(seconds: 2));
          fixture.database.postLoadRelease.complete();
          await hydrated.future.timeout(const Duration(seconds: 3));
          expect(
              timeline
                  .snapshot()
                  .any((e) => e.text == 'Canonical late replacement'),
              isTrue);
          expect(timeline.snapshot().any((e) => e.text == 'Decoded local 39'),
              isFalse);
          expect(fixture.database.injectedReadFailures,
              mutation == 'repair-sql-failure' ? 1 : 0);
        }
      } finally {
        if (!crypto.release.isCompleted) crypto.release.complete();
        fixture.client.replacementDatabase = null;
        fixture.client.replacementEncryption = null;
        fixture.client.rooms[0] = room;
        if (!fixture.database.postLoadRelease.isCompleted) {
          fixture.database.postLoadRelease.complete();
        }
        timeline?.dispose();
        await canceling;
        await lease?.cancel();
        await fixture.close();
      }
    });
  }

  test('optional early decode failure still recovers canonical local content',
      () async {
    final fixture = await _Fixture.create('decode-recoverable');
    final crypto =
        _ControlledEncryption(fixture.client.encryption!, fail: true);
    fixture.client.replacementEncryption = crypto;
    MatrixRoomLease? lease;
    RoomTimelineCapability? timeline;
    final hydrated = Completer<void>();
    try {
      lease = await fixture.owner.openRoomLease('!decode:synthetic.test');
      timeline = await lease.openRoomTimeline(
          cachedFirst: true,
          onUpdate: () {},
          onHydrated: () => hydrated.complete());
      await crypto.entered.future.timeout(const Duration(seconds: 2));
      await fixture.database.postLoadEntered.future
          .timeout(const Duration(seconds: 2));
      expect(fixture.database.postLoadRelease.isCompleted, isFalse);
      fixture.database.postLoadRelease.complete();
      await hydrated.future.timeout(const Duration(seconds: 3));
      expect(
          timeline
              .snapshot()
              .where((e) => e.text.startsWith('Decoded local '))
              .length,
          40);
      expect(timeline.snapshot().map((e) => e.id).toSet().length, 40);
      expect(crypto.calls, greaterThan(1));
    } finally {
      fixture.client.replacementEncryption = null;
      if (!fixture.database.postLoadRelease.isCompleted) {
        fixture.database.postLoadRelease.complete();
      }
      timeline?.dispose();
      await lease?.cancel();
      await fixture.close();
    }
  });

  test('disposed timeline cannot publish recovery while lease remains alive',
      () async {
    final fixture = await _Fixture.create('decode-disposed');
    final lease = await fixture.owner.openRoomLease('!decode:synthetic.test');
    var callbacks = 0;
    final timeline = await lease.openRoomTimeline(
        cachedFirst: true,
        onUpdate: () => callbacks++,
        onHydrated: () => callbacks++);
    try {
      await fixture.database.postLoadEntered.future;
      timeline.dispose();
      final before = callbacks;
      fixture.database.postLoadRelease.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(callbacks, before);
      expect(lease.canceled, isFalse);
      expect(fixture.owner.hasCachedRoomDisplay('!decode:synthetic.test'),
          isFalse);
    } finally {
      if (!fixture.database.postLoadRelease.isCompleted) {
        fixture.database.postLoadRelease.complete();
      }
      timeline.dispose();
      await lease.cancel();
      await fixture.close();
    }
  });
}
