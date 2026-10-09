import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'matrix_client_factory_test.dart'
    show MatrixTestPaths, SnapshotClient, SnapshotRoom;
import 'conversation_list_restart_recovery_test.dart' show DirectSnapshotRoom;

class _HeldCounts extends MatrixSdkDatabase {
  _HeldCounts() : super('synthetic-cache-first');
  final release = Completer<void>();
  int calls = 0;
  @override
  Future<int> getTimelineEventCount(Room room) async {
    calls++;
    await release.future;
    return 1000000;
  }
}

class _CachedClient extends SnapshotClient {
  _CachedClient(this.store);
  final _HeldCounts store;
  @override
  DatabaseApi get database => store;
}

class _HeldPositions extends MatrixSdkDatabase {
  _HeldPositions(
      {required super.database,
      required this.release,
      required super.timelineMigrationReader,
      required super.timelineLegacyPageReader})
      : super('synthetic-old-index');
  final Completer<void> release;
  int lookups = 0;
  @override
  Future<Map<String, int>> getTimelineEventPositions(
      Room room, Iterable<String> ids) async {
    lookups++;
    await release.future;
    return super.getTimelineEventPositions(room, ids);
  }
}

class _StoredClient extends SnapshotClient {
  _StoredClient(this.store);
  final MatrixSdkDatabase store;
  @override
  DatabaseApi get database => store;
}

class _TimelineRoom extends SnapshotRoom {
  _TimelineRoom({required super.id, required super.client, this.opening})
      : super(joined: true);
  @override
  bool get isDirectChat => true;
  @override
  String get directChatMatrixID => '@peer:test';
  final Completer<void>? opening;
  @override
  Future<Timeline> getTimeline(
      {void Function(int)? onChange,
      void Function(int)? onRemove,
      void Function(int)? onInsert,
      void Function()? onNewEvent,
      void Function()? onUpdate,
      String? eventContextId}) async {
    await opening?.future;
    return Timeline(
        room: this, chunk: TimelineChunk(events: []), onUpdate: onUpdate);
  }
}

class _LogicalClient extends SnapshotClient {
  @override
  Map<String, dynamic> get directChats => {
        '@peer:test': ['!new:test', '!old:test']
      };
}

DatabaseFactory cacheFirstDatabaseFactory = databaseFactoryFfi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(() {
    PathProviderPlatform.instance = MatrixTestPaths();
    SharedPreferences.setMockInitialValues({});
  });
  test('logical primary opens while secondary cached source is still hydrating',
      () async {
    final release = Completer<void>();
    final client = _LogicalClient();
    final primary = _TimelineRoom(id: '!new:test', client: client);
    client.snapshotRooms.addAll([
      primary,
      _TimelineRoom(id: '!old:test', client: client, opening: release)
    ]);
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    await owner.prepareConversationAssociations();
    final lease = await owner.openRoomLease(primary.id);
    Future<RoomTimelineCapability>? pending;
    try {
      pending = lease.openLogicalRoomTimeline(onUpdate: () {});
      final timeline = await pending.timeout(const Duration(milliseconds: 300));
      timeline.dispose();
    } finally {
      release.complete();
      await pending;
      await lease.cancel();
      await client.dispose();
    }
  });
  test(
      'SDK cold init installs cached rooms before optional legacy preview reads',
      () async {
    final sql =
        await cacheFirstDatabaseFactory.openDatabase(inMemoryDatabasePath);
    final release = Completer<void>();
    final db = MatrixSdkDatabase('cold-list', database: sql,
        timelineLegacyPageReader: (key, source,
            {start = 0,
            limit = 256,
            findEventIds,
            reverse = false,
            isCancelled}) async {
      await release.future;
      return TimelineLegacyPage(start == 0 ? [r'$cached'] : [],
          start: start, hasMore: false);
    });
    await db.open();
    final client = Client('cold-list',
        databaseBuilder: (_) => db,
        httpClient: MockClient((request) async {
          final uploaded = request.url.path.endsWith('/keys/upload')
              ? (jsonDecode(request.body)['one_time_keys'] as Map?)?.length ?? 0
              : 0;
          return http.Response(
              jsonEncode({
                'filter_id': 'synthetic',
                'next_batch': 'synthetic',
                'versions': ['v1.1'],
                'one_time_key_counts': {'signed_curve25519': uploaded},
                'device_keys': <String, Object>{}
              }),
              200,
              headers: {'content-type': 'application/json'});
        }))
      ..backgroundSync = false;
    final room =
        Room(id: '!cached:test', client: client, membership: Membership.join);
    await sql
        .insert('box_rooms', {'k': room.id, 'v': jsonEncode(room.toJson())});
    await sql.insert('box_timeline_fragments', {
      'k': '${room.id}|',
      'v': jsonEncode([r'$cached'])
    });
    Future<void>? pending;
    try {
      pending = client.init(
          newToken: 'synthetic',
          newUserID: '@me:test',
          newDeviceID: 'SYNTHETIC',
          newDeviceName: 'synthetic',
          newHomeserver: Uri.parse('https://test'),
          waitForFirstSync: false);
      await pending.timeout(const Duration(milliseconds: 400));
      expect(client.rooms.single.id, room.id);
    } finally {
      release.complete();
      await pending;
      await client.dispose();
    }
  });
  test('persisted initial bubbles publish before unknown old-index positions',
      () async {
    final sql =
        await cacheFirstDatabaseFactory.openDatabase(inMemoryDatabasePath);
    final release = Completer<void>();
    final legacy = [r'$cached', ...List.generate(999999, (i) => 'old-$i')];
    final db = _HeldPositions(
        database: sql,
        release: release,
        timelineMigrationReader: (_) async* {
          await release.future;
          yield legacy;
        },
        timelineLegacyPageReader: (key, source,
            {start = 0,
            limit = 256,
            findEventIds,
            reverse = false,
            isCancelled}) async {
          return TimelineLegacyPage(legacy.skip(start).take(limit).toList(),
              start: start, hasMore: start + limit < legacy.length);
        });
    await db.open();
    final client = _StoredClient(db);
    final room =
        Room(id: '!stored:test', client: client, membership: Membership.join);
    client.snapshotRooms.add(room);
    await sql.insert('box_timeline_fragments',
        {'k': '${room.id}|', 'v': jsonEncode(legacy)});
    await sql.insert('box_events', {
      'k': '${room.id}|\$cached',
      'v': jsonEncode({
        'event_id': r'$cached',
        'type': EventTypes.Message,
        'sender': '@me:test',
        'origin_server_ts': 1000,
        'content': {'msgtype': 'm.text', 'body': 'cached synthetic bubble'}
      })
    });
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final lease = await owner.openRoomLease(room.id);
    Future<RoomTimelineCapability>? pending;
    try {
      pending = lease.openRoomTimeline(onUpdate: () {});
      final timeline = await pending.timeout(const Duration(milliseconds: 300));
      expect(timeline.snapshot().single.text, 'cached synthetic bubble');
      expect(db.lookups, 0,
          reason:
              'the bounded database head is already proof of persisted residency');
      expect(
          (await sql.query('matrix_timeline_fragment_state',
                  where: 'fragment_key=?', whereArgs: ['${room.id}|']))
              .single['migration_state'],
          'copying');
      timeline.dispose();
    } finally {
      db.release.complete();
      await pending;
      await lease.cancel();
      await client.dispose();
      await db.close();
    }
  });
  for (final snapshot in [true, false]) {
    test(
        '${snapshot ? 'first cached snapshot' : 'room associations'} does not wait for duplicate history counts',
        () async {
      final db = _HeldCounts();
      final client = _CachedClient(db);
      for (final id in ['!old:test', '!new:test']) {
        client.snapshotRooms.add(
            DirectSnapshotRoom(id: id, client: client, peer: '@peer:test'));
      }
      final owner =
          MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
      Future<void>? pending;
      try {
        pending = snapshot
            ? owner.conversations.snapshot().then((value) {
                expect(value.rooms, hasLength(1));
              })
            : owner.prepareConversationAssociations();
        await expectLater(
            pending.timeout(const Duration(milliseconds: 300)), completes);
      } finally {
        db.release.complete();
        await pending;
        await client.dispose();
      }
    });
  }
  test('held optional preview does not queue the active room cached head',
      () async {
    final sql =
        await cacheFirstDatabaseFactory.openDatabase(inMemoryDatabasePath);
    final release = Completer<void>();
    final entered = Completer<void>();
    final db = MatrixSdkDatabase('preview-isolation', database: sql,
        timelineMigrationReader: (_) async* {
      await release.future;
      yield [r'$cached'];
    }, timelineLegacyPageReader: (key, source,
            {start = 0,
            limit = 256,
            findEventIds,
            reverse = false,
            isCancelled}) async {
      if (key == '!optional:test|') {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      }
      return TimelineLegacyPage([r'$cached'], start: 0, hasMore: false);
    });
    await db.open();
    final client = _StoredClient(db);
    final optional =
        Room(id: '!optional:test', client: client, membership: Membership.join);
    final active =
        Room(id: '!active:test', client: client, membership: Membership.join);
    client.snapshotRooms.addAll([optional, active]);
    for (final room in [optional, active]) {
      await sql.insert('box_timeline_fragments', {
        'k': '${room.id}|',
        'v': jsonEncode([r'$cached'])
      });
      await sql.insert('box_events', {
        'k': '${room.id}|\$cached',
        'v': jsonEncode({
          'event_id': r'$cached',
          'type': EventTypes.Message,
          'sender': '@me:test',
          'origin_server_ts': 1000,
          'content': {'msgtype': 'm.text', 'body': 'cached synthetic bubble'}
        })
      });
    }
    final repair = db.refreshRoomListPreviews([optional], client);
    await entered.future;
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final lease = await owner.openRoomLease(active.id);
    final pending = lease.openRoomTimeline(onUpdate: () {});
    try {
      final timeline = await pending.timeout(const Duration(milliseconds: 300));
      expect(timeline.snapshot().single.text, 'cached synthetic bubble');
      timeline.dispose();
    } finally {
      release.complete();
      await repair;
      await pending;
      await lease.cancel();
      await client.dispose();
      await db.close();
    }
  });
}
