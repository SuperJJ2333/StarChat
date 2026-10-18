import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sql;
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

class _Secure implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Database extends MatrixSdkDatabase {
  _Database(super.name, {super.database, super.sqfliteFactory});
  final limits = <int?>[];
  Future<void> Function(Room, int?)? beforeRead;
  Future<void> Function(Room)? afterFirstDeepRead;
  bool notified = false;
  Future<void> Function()? beforeStoreBatch;
  @override
  Future<void> storePrevBatch(String value) async {
    await beforeStoreBatch?.call();
    await super.storePrevBatch(value);
  }

  @override
  Future<List<Event>> getEventList(Room room,
      {int start = 0, bool onlySending = false, int? limit}) async {
    limits.add(limit);
    await beforeRead?.call(room, limit);
    final events = await super.getEventList(room,
        start: start, onlySending: onlySending, limit: limit);
    if (limit == 40 && !notified) {
      notified = true;
      await afterFirstDeepRead?.call(room);
    }
    return events;
  }

  void reset() {
    limits.clear();
    notified = false;
    afterFirstDeepRead = null;
  }
}

class _Client extends Client {
  _Client(super.name, this.db, this.user, {http.Client? transport})
      : super(
            httpClient: transport ??
                MockClient((request) async => http.Response(
                    jsonEncode({
                      'user_id': user,
                      'device_id': 'SYNTHETIC',
                      'access_token': 'synthetic-refreshed'
                    }),
                    200)));
  @override
  void startSyncImmediately() {}
  var aborts = 0;
  @override
  Future<void> abortSync() {
    aborts++;
    return super.abortSync();
  }

  @override
  Future<(DiscoveryInformation?, GetVersionsResponse, List<LoginFlow>)>
      checkHomeserver(Uri homeserverUrl,
              {bool checkWellKnown = true,
              Set<String>? overrideSupportedVersions}) async =>
          (null, GetVersionsResponse(versions: const []), const <LoginFlow>[]);
  final _Database db;
  final String user;
  @override
  _Database get database => db;
  @override
  bool isLogged() => true;
  @override
  String get userID => user;
  @override
  String get deviceID => 'SYNTHETIC';
  @override
  Future<void> get initializationCompleted => Future<void>.value();
  final localRooms = <Room>[];
  @override
  List<Room> get rooms => localRooms;
}

class _Room extends Room {
  _Room(_Client client, int index)
      : super(id: '!stage-$index:synthetic.test', client: client) {
    setState(Event(
        room: this,
        eventId: 'power-$index',
        type: EventTypes.RoomPowerLevels,
        stateKey: '',
        senderId: client.userID,
        originServerTs: DateTime.utc(2026),
        content: {
          'events': {
            'com.changliao.group.settings': 50,
            'com.changliao.group.announcement': 50
          }
        }));
    setState(Event(
        room: this,
        eventId: 'member-$index',
        type: EventTypes.RoomMember,
        stateKey: client.userID,
        senderId: client.userID,
        originServerTs: DateTime.utc(2026),
        content: {'membership': 'join', 'displayname': 'Synthetic sender'}));
  }
  @override
  String get name => 'Synthetic staged room';
}

typedef _Readable = (StartupProjectionAdmission, StartupProjection);

class _Fixture {
  _Fixture(this.directory, this.sqlDatabase, this.database, this.client,
      this.secure, this.owner)
      : cache = StartupProjectionStore(directory);
  final Directory directory;
  final sql.Database sqlDatabase;
  final _Database database;
  final _Client client;
  final SecureSessionStore secure;
  final MatrixSdkE2eeClient owner;
  final StartupProjectionStore cache;

  static Future<_Fixture> create(String name,
      {bool display = false,
      bool pending = false,
      http.Client? transport,
      Future<void> Function(Client)? suspendClient,
      Future<Client> Function()? resumeClient,
      Future<void> Function(String, String)? selectClientAccount,
      Future<void> Function(Room, int?)? beforeRead}) async {
    SharedPreferences.setMockInitialValues({});
    final root = Directory(
            '../../docs/verification/artifacts/2026-10-18/room-entry-readiness/fixtures')
        .absolute;
    await root.create(recursive: true);
    final directory = await root.createTemp('staged-');
    final secure = SecureSessionStore(_Secure());
    final key = await secure.matrixDatabaseKey();
    await secure.registrationDeviceKey();
    final factory =
        sql.createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final connection = await factory.openDatabase(sql.inMemoryDatabasePath,
        options: sql.OpenDatabaseOptions(onConfigure: (db) async {
      await db.execute("PRAGMA key = '$key'");
    }));
    final database =
        _Database(name, database: connection, sqfliteFactory: factory);
    database.beforeRead = beforeRead;
    await database.open();
    final client =
        _Client(name, database, '@$name:synthetic.test', transport: transport);
    await secure.saveSession(
        accessToken: 'synthetic',
        refreshToken: 'synthetic',
        matrixUserId: client.userID);
    await secure.saveMatrixBinding(MatrixLocalBinding(
        version: 2,
        matrixUserId: client.userID,
        deviceId: client.deviceID,
        homeserver: 'https://synthetic.test',
        databaseGeneration: 'generation',
        ed25519Fingerprint: 'fingerprint'));
    for (var roomIndex = 0; roomIndex < 3; roomIndex++) {
      final room = _Room(client, roomIndex);
      client.localRooms.add(room);
      for (var index = 0; index < 40; index++) {
        final event = {
          'event_id': 'message-$roomIndex-$index',
          'type': EventTypes.Message,
          'sender': client.userID,
          'origin_server_ts': 1000 * roomIndex + index,
          'content': {'msgtype': 'm.text', 'body': 'Synthetic staged $index'}
        };
        await database.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: event),
            client);
        room.lastEvent = Event.fromJson(event, room);
      }
    }
    StartupProjectionAdmission? displayAdmission;
    StartupProjection? displayProjection;
    if (display) {
      final seed = StartupProjectionStore(directory);
      final installation = await seed.primeInstallation();
      final identity =
          (await secure.prepareStartupProjectionHead(installation))!;
      final prepared = await seed.prepare(identity, StartupProjection([]));
      expect(
          await secure.commitStartupProjectionHead(
              identity, prepared.digest, prepared.length),
          isTrue);
      displayAdmission =
          (await secure.readStartupProjectionAdmission(installation))!;
      displayProjection = (await seed.read(displayAdmission))!;
    }
    if (pending) {
      await secure.saveSession(
          accessToken: 'synthetic',
          refreshToken: 'synthetic',
          matrixUserId: client.userID,
          pendingRefreshOperation: StartupProjectionStore.randomEpoch());
    }
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://synthetic.test'),
        suspendClient: suspendClient,
        resumeClient: resumeClient,
        selectClientAccount: selectClientAccount,
        secureSessionStore: secure,
        startupAdmission: displayAdmission,
        startupProjection: displayProjection,
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: true,
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fingerprint',
                databaseGeneration: 'generation'));
    return _Fixture(directory, connection, database, client, secure, owner);
  }

  Future<_Readable?> read() async {
    final installation = await cache.readInstallation();
    if (installation == null) return null;
    final admission = await secure.readStartupProjectionAdmission(installation);
    if (admission == null) return null;
    final value = await cache.read(admission);
    return value == null ? null : (admission, value);
  }

  Future<void> close() async {
    await owner.suspend();
    if (sqlDatabase.isOpen) await sqlDatabase.close();
    await directory.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('retained broker adoption waits for an actual SDK SQL transaction',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var logins = 0;
    final transport = MockClient((request) async {
      if (request.url.path.endsWith('/filter')) {
        return http.Response('{"filter_id":"filter"}', 200);
      }
      if (request.url.path.endsWith('/login')) {
        logins++;
        return http.Response(
            '{"user_id":"@transaction:synthetic.test","device_id":"SYNTHETIC","access_token":"adopted"}',
            200);
      }
      return http.Response('{"next_batch":"old-transaction"}', 200);
    });
    final fixture = await _Fixture.create('transaction', transport: transport);
    fixture.client.homeserver = Uri.parse('https://synthetic.test');
    fixture.client.accessToken = 'synthetic-old';
    fixture.database.beforeStoreBatch = () async {
      entered.complete();
      await release.future;
    };
    fixture.client.backgroundSync = false;
    final syncing = fixture.client.oneShotSync();
    Future<void>? login;
    try {
      await entered.future.timeout(const Duration(seconds: 3));
      login = fixture.owner.loginWithTokenForExpectedIdentity(
          expectedMatrixUserId: fixture.client.userID,
          loginToken: 'synthetic-grant',
          homeserver: Uri.parse('https://synthetic.test'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fixture.client.aborts, 1);
      expect(logins, 0,
          reason: 'the retiring transaction must drain before broker login');
      expect(fixture.client.accessToken, 'synthetic-old');
      release.complete();
      await Future.wait([syncing, login]);
      expect(logins, 1);
      expect(fixture.client.accessToken, 'adopted');
    } finally {
      if (!release.isCompleted) release.complete();
      await syncing;
      await login;
      fixture.database.beforeStoreBatch = null;
      await fixture.close();
      transport.close();
    }
  });
  test('selected accounts rebuild encrypted shallow heads while deep SQL waits',
      () async {
    late _Fixture fixture;
    late _Client next;
    fixture = await _Fixture.create('switch-a',
        suspendClient: (_) async {},
        resumeClient: () async => next,
        selectClientAccount: (home, user) async {
          await fixture.secure.selectMatrixAccount(home, user);
          await fixture.secure.saveSession(
              accessToken: 'synthetic',
              refreshToken: 'synthetic',
              matrixUserId: user);
          await fixture.secure.matrixDatabaseKey();
          await fixture.secure.registrationDeviceKey();
          await fixture.secure.saveMatrixBinding(MatrixLocalBinding(
              version: 2,
              matrixUserId: user,
              deviceId: 'SYNTHETIC',
              homeserver: home,
              databaseGeneration: 'generation',
              ed25519Fingerprint: 'fingerprint'));
        });
    final factory =
        sql.createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final bConnection = await factory.openDatabase(sql.inMemoryDatabasePath,
        options: sql.OpenDatabaseOptions(onConfigure: (db) async {
      await db.execute("PRAGMA key = 'synthetic-B-encryption-key'");
    }));
    final bDatabase =
        _Database('switch-b', database: bConnection, sqfliteFactory: factory);
    await bDatabase.open();
    final b = _Client('switch-b', bDatabase, '@switch-b:synthetic.test');
    final bRoom = _Room(b, 0);
    b.localRooms.add(bRoom);
    final event = {
      'event_id': 'message-B',
      'type': EventTypes.Message,
      'sender': b.userID,
      'origin_server_ts': 99999,
      'content': {'msgtype': 'm.text', 'body': 'Synthetic B only'}
    };
    await bDatabase.storeEventUpdate(
        EventUpdate(
            roomID: bRoom.id, type: EventUpdateType.timeline, content: event),
        b);
    bRoom.lastEvent = Event.fromJson(event, bRoom);
    try {
      for (final selected in [b, fixture.client]) {
        final previous = fixture.secure.startupProjectionCoordinator!;
        final oldPermit = previous.beginDisplayCapture()!;
        final oldSettled =
            (selected == b ? fixture.client : b).onLocalDisplayApplySettled;
        next = selected;
        await fixture.owner.selectAccount(
            selected.userID, Uri.parse('https://synthetic.test'));
        expect(previous.isDisplayCurrent(oldPermit), isFalse);
        expect(
            fixture.secure.startupProjectionCoordinator!.canCapture, isFalse);
        await fixture.owner.loginWithTokenForExpectedIdentity(
            expectedMatrixUserId: selected.userID,
            loginToken: 'synthetic-grant',
            homeserver: Uri.parse('https://synthetic.test'));
        final database = selected.db;
        database.reset();
        final entered = Completer<void>();
        final release = Completer<void>();
        database.afterFirstDeepRead = (_) async {
          entered.complete();
          await release.future;
        };
        final capture = fixture.owner.primeStartupProjection(fixture.cache);
        try {
          await entered.future.timeout(const Duration(seconds: 10));
          final head = (await fixture.read())!;
          expect(head.$1.userId, selected.userID);
          expect(head.$2.rooms.first.events, isNotEmpty);
          expect(fixture.owner.hasCachedRoomDisplay(bRoom.id), isTrue);
          final bodies =
              head.$2.rooms.expand((r) => r.events).map((e) => e.body).toList();
          expect(bodies.contains('Synthetic B only'), selected == b,
              reason:
                  'identical room IDs must not expose another account rows');
          oldSettled?.call(SyncUpdate(nextBatch: 'retired-callback'));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect((await fixture.read())!.$1.userId, selected.userID);
          expect(release.isCompleted, isFalse);
        } finally {
          release.complete();
          await capture;
          database.afterFirstDeepRead = null;
        }
      }
    } finally {
      await fixture.close();
      if (bConnection.isOpen) await bConnection.close();
    }
  });
  test('pending writer rejection releases independent display repair',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var held = false;
    final fixture = await _Fixture.create('staged-pending',
        display: true, pending: true, beforeRead: (_, limit) async {
      if (limit == 8 && !held) {
        held = true;
        entered.complete();
        await release.future;
      }
    });
    try {
      await entered.future.timeout(const Duration(seconds: 10));
      final writing = fixture.owner.primeStartupProjection(fixture.cache);
      release.complete();
      await writing.timeout(const Duration(seconds: 10));
      for (var attempt = 0;
          attempt < 200 &&
              !fixture.client.rooms
                  .every((r) => fixture.owner.hasCachedRoomDisplay(r.id));
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
          fixture.client.rooms
              .every((r) => fixture.owner.hasCachedRoomDisplay(r.id)),
          isTrue);
      expect(fixture.database.limits, everyElement(8));
      expect(await fixture.read(), isNull,
          reason: 'display repair must not bypass pending writer admission');
    } finally {
      if (!release.isCompleted) release.complete();
      await fixture.close();
    }
  });
  test('existing display flight hands over to quick writer without deadlock',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final deepEntered = Completer<void>();
    final deepRelease = Completer<void>();
    var held = false;
    final fixture = await _Fixture.create('staged-display-flight',
        display: true, beforeRead: (_, limit) async {
      if (limit == 8 && !held) {
        held = true;
        entered.complete();
        await release.future;
      }
    });
    fixture.database.afterFirstDeepRead = (_) async {
      deepEntered.complete();
      await deepRelease.future;
    };
    Future<void>? writing;
    try {
      await entered.future.timeout(const Duration(seconds: 10));
      writing = fixture.owner.primeStartupProjection(fixture.cache);
      fixture.client
          .onLocalDisplayApplySettled!(SyncUpdate(nextBatch: 'synthetic'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fixture.database.limits, [8]);
      release.complete();
      await deepEntered.future.timeout(const Duration(seconds: 10));
      final quick = (await fixture.read())!;
      expect(quick.$2.rooms.every((r) => r.events.length == 8), isTrue);
      expect(
          fixture.client.rooms
              .every((r) => fixture.owner.hasCachedRoomDisplay(r.id)),
          isTrue);
      expect(deepRelease.isCompleted, isFalse);
      deepRelease.complete();
      await writing.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
          (await fixture.read())!.$2.rooms.every((r) => r.events.length == 40),
          isTrue);
    } finally {
      if (!release.isCompleted) release.complete();
      if (!deepRelease.isCompleted) deepRelease.complete();
      await writing;
      await fixture.close();
    }
  });
  test('committed encrypted shallow head is readable while deep SQL is held',
      () async {
    final fixture = await _Fixture.create('staged-held');
    final entered = Completer<void>();
    final release = Completer<void>();
    fixture.database.afterFirstDeepRead = (_) async {
      entered.complete();
      await release.future;
    };
    final capture = fixture.owner.primeStartupProjection(fixture.cache);
    try {
      await entered.future.timeout(const Duration(seconds: 10));
      final quick = await fixture.read();
      expect(quick, isNotNull,
          reason: 'a committed head must precede unfinished deep SQL');
      expect(quick!.$2.rooms, hasLength(3));
      expect(
          quick.$2.rooms.every(
              (room) => room.events.length == 8 && room.coverage == 'partial'),
          isTrue);
      expect(
          File('${fixture.directory.path}/${quick.$1.digest}.cfsp')
              .existsSync(),
          isTrue);
      expect(release.isCompleted, isFalse);
      release.complete();
      await capture;
      final complete = (await fixture.read())!;
      expect(
          complete.$2.rooms.every((room) => room.events.length == 40), isTrue);
      expect(complete.$1.digest, isNot(quick.$1.digest));
    } finally {
      if (!release.isCompleted) release.complete();
      await capture;
      await fixture.close();
    }
  });
  for (final scenario in [
    'deep-read-failure',
    'deep-prepare-failure',
    'privacy',
    'account',
    'room',
    'generation'
  ]) {
    test('real SQLCipher shallow head survives or revokes correctly: $scenario',
        () async {
      final fixture = await _Fixture.create('staged-$scenario');
      _Readable? quick;
      Object? failure;
      final candidate = Directory('${fixture.directory.path}/candidate');
      fixture.database.afterFirstDeepRead = (room) async {
        quick = await fixture.read();
        switch (scenario) {
          case 'deep-read-failure':
            throw StateError('synthetic deep read failure');
          case 'deep-prepare-failure':
            await candidate.create();
          case 'privacy':
            await fixture.secure.startupProjectionCoordinator!
                .runMutation('synthetic-privacy', () async {});
          case 'account':
            await fixture.secure.saveSession(
                accessToken: 'synthetic',
                refreshToken: 'synthetic',
                matrixUserId: '@replacement:synthetic.test');
          case 'room':
            final index = fixture.client.localRooms.indexOf(room);
            fixture.client.localRooms[index] =
                Room.fromJson(room.toJson(), fixture.client);
          case 'generation':
            room.invalidateHistoryFragment();
        }
      };
      try {
        try {
          await fixture.owner.primeStartupProjection(fixture.cache);
        } catch (error) {
          failure = error;
        }
        expect(quick, isNotNull,
            reason: 'first committed AEAD head precedes the deep read');
        expect(quick!.$2.rooms, hasLength(3));
        expect(
            quick!.$2.rooms.every((room) =>
                room.events.isNotEmpty &&
                room.events.length <= 8 &&
                room.coverage == 'partial'),
            isTrue);
        if (scenario.startsWith('deep-')) {
          expect(failure, isA<StateError>());
        } else {
          expect(failure, isNull);
        }
        if (await candidate.exists()) await candidate.delete();
        final after = await fixture.read();
        if (scenario == 'privacy' || scenario == 'account') {
          expect(after, isNull,
              reason: 'revocation cannot retain the earlier quick admission');
        } else {
          expect(after, isNotNull);
          expect(after!.$1.digest, quick!.$1.digest,
              reason: 'failed or stale deep work cannot replace the head');
          expect(
              File('${fixture.directory.path}/${quick!.$1.digest}.cfsp')
                  .existsSync(),
              isTrue);
        }
      } finally {
        if (await candidate.exists()) await candidate.delete();
        await fixture.close();
      }
    });
  }
  test('complete head is not downgraded, new revision performs quick pass',
      () async {
    final fixture = await _Fixture.create('staged-depth');
    try {
      await fixture.owner.primeStartupProjection(fixture.cache);
      final complete = (await fixture.read())!;
      expect(
          complete.$2.rooms.every((room) => room.events.length == 40), isTrue);
      expect(fixture.database.limits, [8, 8, 8, 40, 40, 40]);
      fixture.database.reset();
      _Readable? atNextDeep;
      fixture.database.afterFirstDeepRead = (_) async {
        atNextDeep = await fixture.read();
      };
      await fixture.owner.primeStartupProjection(fixture.cache);
      expect(fixture.database.limits, [40, 40, 40]);
      expect(atNextDeep!.$1.digest, complete.$1.digest);
      expect(atNextDeep!.$2.rooms.every((room) => room.events.length == 40),
          isTrue);
      await fixture.secure.startupProjectionCoordinator!
          .runMutation('synthetic-new-revision', () async {});
      fixture.database.reset();
      await fixture.owner.primeStartupProjection(fixture.cache);
      expect(fixture.database.limits, [8, 8, 8, 40, 40, 40]);
      expect(
          (await fixture.read())!
              .$2
              .rooms
              .every((room) => room.events.length == 40),
          isTrue);
    } finally {
      await fixture.close();
    }
  });
}
