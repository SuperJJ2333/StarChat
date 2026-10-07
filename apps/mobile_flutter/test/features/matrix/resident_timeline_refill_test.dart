import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Client extends Client {
  _Client(this.store, {http.Client? httpClient})
      : super('resident-test', httpClient: httpClient);
  final MatrixSdkDatabase store;
  @override
  DatabaseApi get database => store;
}

class _HeldEncryption implements Encryption {
  final entered = Completer<void>();
  final released = Completer<Event>();
  @override
  bool get enabled => true;
  @override
  Future<Event> decryptRoomEvent(String roomId, Event event,
      {bool store = false,
      EventUpdateType updateType = EventUpdateType.timeline}) {
    if (!entered.isCompleted) entered.complete();
    return released.future;
  }

  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DecryptClient extends Client {
  _DecryptClient(this.held) : super('resident-decrypt');
  final _HeldEncryption held;
  @override
  Encryption get encryption => held;
}

// Exercise consumer acceptance of filtered raw pages while all visible payloads
// and subsequent pages still come from the real native indexed store.
class _EmptyFirstSnapshot implements TimelineIdSnapshot {
  _EmptyFirstSnapshot(this.inner, {this.first = true});
  final TimelineIdSnapshot inner;
  bool first;
  TimelineIdPage? empty;
  @override
  int get length => inner.length;
  @override
  Future<TimelineIdPage> next({int limit = 30}) async => first
      ? empty ??= TimelineIdPage([], hasMore: true, cursor: -1, rawCount: limit)
      : inner.next(limit: limit);
  @override
  void accept(TimelineIdPage page) {
    if (identical(page, empty)) {
      first = false;
      empty = null;
    } else {
      inner.accept(page);
    }
  }

  @override
  Future<TimelineIdSnapshot> fork(
          {required String afterEventId,
          TimelineIdDirection direction = TimelineIdDirection.older}) async =>
      _EmptyFirstSnapshot(
          await inner.fork(afterEventId: afterEventId, direction: direction));
  @override
  Future<TimelineIdSnapshot> checkpoint() async =>
      _EmptyFirstSnapshot(await inner.checkpoint(), first: first);
  @override
  void dispose() => inner.dispose();
}

class _EmptyFirstStore extends MatrixSdkDatabase {
  _EmptyFirstStore(super.path, {required super.database});
  @override
  Future<TimelineIdSnapshot> openTimelineIdSnapshot(Room room,
          {String? afterEventId,
          bool includeSending = false,
          TimelineIdDirection direction = TimelineIdDirection.older}) async =>
      _EmptyFirstSnapshot(await super.openTimelineIdSnapshot(room,
          afterEventId: afterEventId,
          includeSending: includeSending,
          direction: direction));
}

class _HeldReadStore extends MatrixSdkDatabase {
  _HeldReadStore(super.path, {required super.database});
  bool hold = false;
  final entered = Completer<void>();
  final released = Completer<void>();
  @override
  Future<Event?> getEventById(String eventId, Room room) async {
    final event = await super.getEventById(eventId, room);
    if (hold) {
      hold = false;
      entered.complete();
      await released.future;
    }
    return event;
  }
}

class _HeldOpenStore extends MatrixSdkDatabase {
  _HeldOpenStore(super.path, {required super.database});
  bool hold = false;
  final entered = Completer<void>();
  final released = Completer<void>();
  @override
  Future<TimelineIdSnapshot> openTimelineIdSnapshot(Room room,
      {String? afterEventId,
      bool includeSending = false,
      TimelineIdDirection direction = TimelineIdDirection.older}) async {
    if (hold) {
      hold = false;
      entered.complete();
      await released.future;
    }
    return super.openTimelineIdSnapshot(room,
        afterEventId: afterEventId,
        includeSending: includeSending,
        direction: direction);
  }
}

Map<String, dynamic> _row(int index) => {
      'event_id': 'saved-$index',
      'type': EventTypes.Message,
      'sender': '@synthetic:test',
      // Deliberately non-monotonic: local sequence, not clocks, owns order.
      'origin_server_ts': index.isEven ? index : 100000 - index,
      'content': {
        'msgtype': 'm.text',
        'body': 'synthetic',
        if (index > 0 && index % 50 == 0)
          'm.relates_to': {
            'rel_type': 'm.annotation',
            'event_id': 'saved-${index - 1}',
            'key': 'synthetic',
          },
      },
    };

void _expectResidentAggregates(Timeline timeline) {
  final contributions = timeline.aggregatedEvents.values
      .expand((types) => types.values)
      .expand((events) => events)
      .toList();
  expect(
      contributions.map((e) => e.eventId).toSet(),
      timeline.events
          .where((e) => e.relationshipType != null && !e.redacted)
          .map((e) => e.eventId)
          .toSet());
  expect(contributions.length, lessThanOrEqualTo(timeline.events.length));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('resident round trip conserves overlap, pending and saved bodies',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('resident-test', database: sql);
    await db.open();
    final client = _Client(db);
    final room = Room(id: '!resident:synthetic', client: client);
    client.rooms.add(room);
    Timeline? live;
    Timeline? history;
    try {
      for (var start = 0; start < 1600; start += 200) {
        await db.transaction(() async {
          for (var i = start; i < start + 200; i++) {
            await db.storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: _row(i)),
                client);
          }
        });
      }
      final pending = Event.fromJson({..._row(-1), 'status': 0}, room);
      live = Timeline(
          room: room,
          chunk: TimelineChunk(events: [
            pending,
            ...await db.getEventList(room, limit: 1000),
          ]));
      history = Timeline.forkHistory(source: live, room: room);
      for (var i = 0; i < 6; i++) {
        final before = {for (final e in history.events) e.eventId: e};
        await history.requestHistory(historyCount: 100);
        expect(history.events.where((e) => e.status.isSynced).length, 1000);
        expect(history.events.contains(pending), isTrue);
        _expectResidentAggregates(history);
        final overlap =
            history.events.where((e) => before.containsKey(e.eventId));
        expect(overlap.length, greaterThanOrEqualTo(100));
        for (final e in overlap) {
          expect(identical(e, before[e.eventId]), isTrue);
        }
      }
      expect(history.events.last.eventId, 'saved-0');
      expect(history.chunk.nextBatch, isEmpty);
      expect(history.canRequestFuture, isTrue);
      for (var i = 0; i < 6; i++) {
        await history.requestFuture(historyCount: 100);
        expect(history.events.where((e) => e.status.isSynced).length, 1000);
        _expectResidentAggregates(history);
      }
      expect(history.events.where((e) => e.status.isSynced).first.eventId,
          'saved-1599');
      expect(await db.getTimelineEventCount(room), 1600);
      for (final id in ['saved-0', 'saved-799', 'saved-1599']) {
        expect(await db.getEventById(id, room), isNotNull);
      }
    } finally {
      history?.cancelSubscriptions();
      live?.cancelSubscriptions();
      await client.dispose();
      await db.close();
    }
  });

  test('no-database fork retains every unpersisted body', () async {
    final client = Client('resident-no-store');
    final room = Room(id: '!resident:synthetic', client: client);
    final live = Timeline(
        room: room,
        chunk: TimelineChunk(events: [
          for (var i = 0; i < 1500; i++) Event.fromJson(_row(i), room),
        ]));
    final history = Timeline.forkHistory(source: live, room: room);
    expect(history.events.length, 1500);
    expect(history.events.every(live.events.contains), isTrue);
    history.cancelSubscriptions();
    live.cancelSubscriptions();
    await client.dispose();
  });

  test('independent event lookups keep a bounded reloadable cache', () async {
    var reads = 0;
    final client =
        Client('resident-lookups', httpClient: MockClient((request) async {
      reads++;
      return http.Response(
          jsonEncode({..._row(1), 'event_id': request.url.pathSegments.last}),
          200);
    }))
          ..homeserver = Uri.parse('https://matrix.synthetic.test')
          ..accessToken = 'synthetic';
    final room = Room(id: '!resident:synthetic', client: client);
    final timeline = Timeline(room: room, chunk: TimelineChunk(events: []));
    try {
      for (var i = 0; i < 300; i++) {
        expect(
            (await timeline.getEventById('lookup-$i'))?.eventId, 'lookup-$i');
      }
      expect(reads, 300);
      await timeline.getEventById('lookup-299');
      expect(reads, 300);
      await timeline.getEventById('lookup-0');
      expect(reads, 301);
    } finally {
      timeline.cancelSubscriptions();
      await client.dispose();
    }
  });

  test(
      'loaded edit aliases deduplicate and authoritative recall removes contribution',
      () async {
    final client = Client('resident-aggregate');
    final room = Room(id: '!resident:synthetic', client: client);
    final target = Event.fromJson(_row(1), room);
    Map<String, dynamic> edit(String id, int status) => {
          ..._row(2),
          'event_id': id,
          'status': status,
          'unsigned': {'transaction_id': 'edit-tx'},
          'content': {
            'body': 'edited',
            'msgtype': 'm.text',
            'm.new_content': {'body': 'edited', 'msgtype': 'm.text'},
            'm.relates_to': {
              'rel_type': 'm.replace',
              'event_id': target.eventId
            },
          },
        };
    final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [
          Event.fromJson(edit('edit-tx', -1), room),
          Event.fromJson(edit('confirmed-edit', 1), room),
          target,
        ]));
    try {
      final contributions =
          timeline.aggregatedEvents[target.eventId]!['m.replace']!;
      expect(contributions.map((e) => e.eventId), ['confirmed-edit']);
      expect(target.getDisplayEvent(timeline).body, 'edited');
      client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.timeline,
          content: {
            ..._row(3),
            'event_id': 'recall-edit',
            'type': EventTypes.Redaction,
            'redacts': 'confirmed-edit',
            'content': <String, dynamic>{}
          }));
      await Future<void>.delayed(Duration.zero);
      expect(target.getDisplayEvent(timeline).body, 'synthetic');
      expect(timeline.aggregatedEvents[target.eventId], isNull);
    } finally {
      timeline.cancelSubscriptions();
      await client.dispose();
    }
  });

  for (final cancel in [false, true]) {
    test(
        'late key decryption preserves identity after insertion; cancel=$cancel',
        () async {
      final encryption = _HeldEncryption();
      final client = _DecryptClient(encryption);
      final room = Room(id: '!resident:synthetic', client: client);
      final encrypted = Event.fromJson({
        ..._row(1),
        'type': EventTypes.Encrypted,
        'content': {
          'msgtype': MessageTypes.BadEncrypted,
          'session_id': 'synthetic-session'
        },
      }, room);
      var updates = 0;
      final timeline = Timeline(
          room: room,
          onUpdate: () => updates++,
          chunk: TimelineChunk(
              events: [encrypted, Event.fromJson(_row(0), room)]));
      try {
        room.onSessionKeyReceived.add('synthetic-session');
        await encryption.entered.future;
        client.onEvent.add(EventUpdate(
            roomID: room.id, type: EventUpdateType.timeline, content: _row(2)));
        await Future<void>.delayed(Duration.zero);
        final before = timeline.events.toList();
        final beforeUpdates = updates;
        if (cancel) timeline.cancelSubscriptions();
        encryption.released.complete(Event.fromJson(_row(1), room));
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(timeline.events.map((e) => e.eventId),
            ['saved-2', 'saved-1', 'saved-0']);
        if (cancel) {
          expect(timeline.events, before);
          expect(updates, beforeUpdates);
        } else {
          expect(timeline.events[1].type, EventTypes.Message);
        }
      } finally {
        timeline.cancelSubscriptions();
        await client.dispose();
      }
    });
  }

  test(
      'empty filtered raw pages advance both cursors without content revisions',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = _EmptyFirstStore('resident-empty', database: sql);
    await db.open();
    final client = _Client(db);
    final room = Room(id: '!resident:synthetic', client: client);
    Timeline? live;
    Timeline? history;
    try {
      for (var start = 0; start < 1004; start += 200) {
        await db.transaction(() async {
          for (var i = start; i < start + 200 && i < 1004; i++) {
            await db.storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: _row(i)),
                client);
          }
        });
      }
      live = Timeline(
          room: room,
          chunk:
              TimelineChunk(events: await db.getEventList(room, limit: 1000)));
      history = Timeline.forkHistory(source: live, room: room);
      final initial = history.events.toList();
      final before = history.presentationRevision;
      await history.requestHistory(historyCount: 2);
      expect(history.events, initial);
      expect(history.presentationRevision, before);
      expect(history.canRequestHistory, isTrue);
      await history.requestHistory(historyCount: 2);
      expect(history.events.last.eventId, 'saved-2');
      final afterOlder = history.events.toList();
      final revision = history.presentationRevision;
      await history.requestFuture(historyCount: 2);
      expect(history.events, afterOlder);
      expect(history.presentationRevision, revision);
      expect(history.canRequestFuture, isTrue);
      await history.requestFuture(historyCount: 2);
      expect(history.events.first.eventId, 'saved-1003');
    } finally {
      history?.cancelSubscriptions();
      live?.cancelSubscriptions();
      await client.dispose();
      await db.close();
    }
  });

  test('retired missing anchor cannot exhaust replacement local history',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = _HeldOpenStore('resident-open-generation-race', database: sql);
    await db.open();
    final client = _Client(db);
    final room = Room(id: '!resident:synthetic', client: client);
    client.rooms.add(room);
    Timeline? timeline;
    try {
      await db.transaction(() async {
        for (var i = 0; i < 60; i++) {
          await db.storeEventUpdate(
              EventUpdate(
                  roomID: room.id,
                  type: EventUpdateType.timeline,
                  content: _row(i)),
              client);
        }
      });
      timeline = Timeline(
          room: room,
          chunk: TimelineChunk(events: await db.getEventList(room, limit: 30)));
      await timeline.enableResidentWindow();
      db.hold = true;
      final pending = timeline.requestHistory(historyCount: 10);
      await db.entered.future;
      await client.handleSync(SyncUpdate.fromJson({
        'next_batch': 'replacement-after-opening-snapshot',
        'rooms': {
          'join': {
            room.id: {
              'timeline': {
                'limited': true,
                'events': [_row(2000)]
              }
            }
          }
        }
      }));
      await Future<void>.delayed(Duration.zero);
      await db.transaction(() async {
        for (var i = 1999; i >= 1990; i--) {
          await db.storeEventUpdate(
              EventUpdate(
                  roomID: room.id,
                  type: EventUpdateType.history,
                  content: _row(i)),
              client);
        }
      });
      db.released.complete();
      await pending;
      expect(timeline.events.map((event) => event.eventId), ['saved-2000']);
      expect(timeline.canRequestHistory, isTrue);
      await timeline.requestHistory(historyCount: 10);
      expect(timeline.events.map((event) => event.eventId),
          List.generate(11, (index) => 'saved-${2000 - index}'));
      expect(await db.getTimelineEventCount(room), 11);
    } finally {
      if (!db.released.isCompleted) db.released.complete();
      timeline?.cancelSubscriptions();
      await client.dispose();
      await db.close();
    }
  });

  test('live append invalidates an older payload lease without losing refill',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = _HeldReadStore('resident-older-live-race', database: sql);
    await db.open();
    final client = _Client(db);
    final room = Room(id: '!resident:synthetic', client: client);
    client.rooms.add(room);
    Timeline? timeline;
    try {
      for (var start = 0; start < 1100; start += 200) {
        await db.transaction(() async {
          for (var i = start; i < start + 200 && i < 1100; i++) {
            await db.storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: _row(i)),
                client);
          }
        });
      }
      timeline = Timeline(
          room: room,
          chunk:
              TimelineChunk(events: await db.getEventList(room, limit: 1000)));
      await timeline.enableResidentWindow();
      final generation = room.historyGeneration;
      final retained =
          timeline.events.singleWhere((event) => event.eventId == 'saved-500');
      db.hold = true;
      final pending = timeline.requestHistory(historyCount: 100);
      await db.entered.future;
      await client.handleSync(SyncUpdate.fromJson({
        'next_batch': 'same-generation-live-append',
        'rooms': {
          'join': {
            room.id: {
              'timeline': {
                'limited': false,
                'events': [_row(1100)],
              }
            }
          }
        }
      }));
      await Future<void>.delayed(Duration.zero);
      expect(room.historyGeneration, generation);
      expect(timeline.events.first.eventId, 'saved-1100');
      expect(timeline.events.last.eventId, 'saved-101');
      db.released.complete();
      await pending;
      expect(timeline.events.length, 1000);
      expect(timeline.events.last.eventId, 'saved-101');
      await timeline.requestHistory(historyCount: 100);
      expect(timeline.events.map((event) => event.eventId),
          List.generate(1000, (index) => 'saved-${1000 - index}'));
      expect(
          identical(
              timeline.events
                  .singleWhere((event) => event.eventId == 'saved-500'),
              retained),
          isTrue);
      expect(await db.getTimelineEventCount(room), 1101);
      expect((await db.getEventById('saved-0', room))?.eventId, 'saved-0');
    } finally {
      if (!db.released.isCompleted) db.released.complete();
      timeline?.cancelSubscriptions();
      await client.dispose();
      await db.close();
    }
  });

  test('late local newer payload cannot attach across a live limited sync',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = _HeldReadStore('resident-future-race', database: sql);
    await db.open();
    final client = _Client(db);
    final room = Room(id: '!resident:synthetic', client: client);
    client.rooms.add(room);
    Timeline? timeline;
    try {
      for (var start = 0; start < 1100; start += 200) {
        await db.transaction(() async {
          for (var i = start; i < start + 200 && i < 1100; i++) {
            await db.storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: _row(i)),
                client);
          }
        });
      }
      timeline = Timeline(
          room: room,
          chunk:
              TimelineChunk(events: await db.getEventList(room, limit: 1000)));
      await timeline.requestHistory(historyCount: 100);
      expect(timeline.events.first.eventId, 'saved-999');
      db.hold = true;
      final pending = timeline.requestFuture(historyCount: 100);
      await db.entered.future;
      await client.handleSync(SyncUpdate.fromJson({
        'next_batch': 'replacement-sync',
        'rooms': {
          'join': {
            room.id: {
              'timeline': {
                'limited': true,
                'prev_batch': 'replacement-prev',
                'events': [_row(2000)],
              }
            }
          }
        },
      }));
      await Future<void>.delayed(Duration.zero);
      db.released.complete();
      await pending;
      expect(timeline.events.map((e) => e.eventId), ['saved-2000']);
      expect(room.prev_batch, 'replacement-prev');
    } finally {
      if (!db.released.isCompleted) db.released.complete();
      timeline?.cancelSubscriptions();
      await client.dispose();
      await db.close();
    }
  });

  test('a fresh live head cannot stitch across evicted newer rows', () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('resident-live-gap', database: sql);
    await db.open();
    final client = _Client(db);
    final room = Room(id: '!resident:synthetic', client: client);
    client.rooms.add(room);
    Timeline? timeline;
    Future<void> sync(int index) => client.handleSync(SyncUpdate.fromJson({
          'next_batch': 'live-$index',
          'rooms': {
            'join': {
              room.id: {
                'timeline': {
                  'limited': false,
                  'events': [_row(index)]
                },
              }
            }
          },
        }));
    try {
      for (var start = 0; start < 1100; start += 200) {
        await db.transaction(() async {
          for (var i = start; i < start + 200 && i < 1100; i++) {
            await db.storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: _row(i)),
                client);
          }
        });
      }
      timeline = Timeline(
          room: room,
          chunk:
              TimelineChunk(events: await db.getEventList(room, limit: 1000)));
      await timeline.requestHistory(historyCount: 100);
      final pending = EventUpdate(
          roomID: room.id,
          type: EventUpdateType.timeline,
          content: {..._row(2001), 'event_id': 'pending-away', 'status': -1});
      await db.transaction(() => db.storeEventUpdate(pending, client));
      client.onEvent.add(pending);
      await sync(2000);
      await Future<void>.delayed(Duration.zero);
      expect(timeline.events.any((e) => e.eventId == 'pending-away'), isTrue);
      expect(timeline.events.any((e) => e.eventId == 'saved-2000'), isFalse,
          reason:
              'New head must wait until the evicted local interval is refilled.');
      for (var i = 0; i < 3 && timeline.canRequestFuture; i++) {
        await timeline.requestFuture(historyCount: 100);
      }
      expect(timeline.events.where((e) => e.status.isSynced).first.eventId,
          'saved-2000');
      expect(timeline.allowNewEvent, isTrue);
      await sync(2002);
      await Future<void>.delayed(Duration.zero);
      expect(timeline.events.where((e) => e.status.isSynced).first.eventId,
          'saved-2002');
      expect(timeline.events.where((e) => e.status.isSynced).length, 1000);
      expect(timeline.events.any((e) => e.eventId == 'pending-away'), isTrue);
    } finally {
      timeline?.cancelSubscriptions();
      await client.dispose();
      await db.close();
    }
  });

  test('live sync keeps saved slice bounded and retains actual invite facts',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('resident-live', database: sql);
    await db.open();
    final client = _Client(db);
    final room = Room(id: '!resident:synthetic', client: client);
    client.rooms.add(room);
    Timeline? timeline;
    try {
      for (var start = 0; start < 1000; start += 200) {
        await db.transaction(() async {
          for (var i = start; i < start + 200; i++) {
            final row = i <= 1
                ? <String, dynamic>{
                    ..._row(i),
                    'type': EventTypes.RoomMember,
                    'state_key': '@joiner:test',
                    'sender': i == 0 ? '@inviter:test' : '@joiner:test',
                    'content': {'membership': i == 0 ? 'invite' : 'join'},
                  }
                : _row(i);
            await db.storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: row),
                client);
          }
        });
      }
      timeline = Timeline(
          room: room,
          chunk:
              TimelineChunk(events: await db.getEventList(room, limit: 1000)));
      await timeline.enableResidentWindow();
      final before = timeline.presentationRevision;
      for (var i = 1000; i < 1002; i++) {
        final update = EventUpdate(
            roomID: room.id, type: EventUpdateType.timeline, content: _row(i));
        await db.transaction(() => db.storeEventUpdate(update, client));
        client.onEvent.add(update);
        await Future<void>.delayed(Duration.zero);
        expect(timeline.events.length, 1000);
        if (i == 1000) {
          final fact = timeline.retainedMembershipInvites['@joiner:test'];
          expect(fact?.eventId, 'saved-0');
          expect(fact?.senderId, '@inviter:test');
        }
      }
      expect(timeline.retainedMembershipInvites, isEmpty,
          reason: 'Dependencies leave when their join leaves residency.');
      expect(timeline.presentationRevision, greaterThan(before));
      expect(await db.getTimelineEventCount(room), 1002);
      final unchanged = timeline.presentationRevision;
      await timeline.enableResidentWindow();
      expect(timeline.presentationRevision, unchanged);
    } finally {
      timeline?.cancelSubscriptions();
      await client.dispose();
      await db.close();
    }
  });

  for (final cancel in [false, true]) {
    test('remote eviction reanchors with real context; cancel=$cancel',
        () async {
      final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final db = MatrixSdkDatabase('resident-context', database: sql);
      await db.open();
      var contextCalls = 0;
      final entered = Completer<void>();
      final released = Completer<http.Response>();
      final client = _Client(db, httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/messages')) {
          expect(request.url.queryParameters['from'], 'original-older');
          return http.Response(
              jsonEncode({
                'start': 'original-older',
                'end': 'remote-oldest',
                'chunk': [for (var i = 99; i >= 0; i--) _row(i)],
              }),
              200);
        }
        expect(request.url.path, endsWith('/context/saved-999'));
        contextCalls++;
        if (contextCalls == 1 && !cancel) {
          return http.Response(
              jsonEncode({'errcode': 'M_UNKNOWN', 'error': 'retry'}), 503);
        }
        entered.complete();
        return released.future;
      }))
        ..homeserver = Uri.parse('https://matrix.synthetic.test')
        ..accessToken = 'synthetic';
      final room = Room(id: '!resident:synthetic', client: client);
      client.rooms.add(room);
      var updates = 0;
      final timeline = Timeline(
          room: room,
          onUpdate: () => updates++,
          chunk: TimelineChunk(
              isFragment: true,
              prevBatch: 'original-older',
              events: [
                for (var i = 1099; i >= 100; i--) Event.fromJson(_row(i), room)
              ]));
      try {
        await timeline.enableResidentWindow();
        await timeline.requestHistory(historyCount: 100);
        expect(timeline.events.length, 1000);
        expect(timeline.events.first.eventId, 'saved-999');
        expect(timeline.events.last.eventId, 'saved-0');
        expect(timeline.canRequestFuture, isTrue);
        final before = timeline.events.toList();
        if (!cancel) {
          await expectLater(timeline.requestFuture(), throwsException);
          expect(timeline.events, before);
          expect(timeline.chunk.nextBatch, isEmpty);
        }
        final pending = timeline.requestFuture();
        await entered.future;
        final beforeCancelUpdates = updates;
        if (cancel) timeline.cancelSubscriptions();
        released.complete(http.Response(
            jsonEncode({
              'event': _row(999),
              'events_after': [for (var i = 1000; i < 1015; i++) _row(i)],
              'events_before': [_row(998)],
              'start': 'context-older',
              'end': 'context-newer',
            }),
            200));
        await pending;
        if (cancel) {
          expect(timeline.events, before);
          expect(updates, beforeCancelUpdates);
        } else {
          expect(timeline.events.length, 1000);
          expect(timeline.events.first.eventId, 'saved-1014');
          expect(timeline.chunk.nextBatch, 'context-newer');
          expect(timeline.events.singleWhere((e) => e.eventId == 'saved-999'),
              same(before.first));
          expect(timeline.canRequestHistory, isTrue);
        }
      } finally {
        timeline.cancelSubscriptions();
        await client.dispose();
        await db.close();
      }
    });
  }
}
