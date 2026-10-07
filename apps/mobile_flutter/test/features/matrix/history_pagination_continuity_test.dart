import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';

Map<String, dynamic> _row(String id, int sequence) => {
      'event_id': id,
      'type': EventTypes.Message,
      'sender': '@sender:synthetic',
      'origin_server_ts': sequence * 86400000,
      'content': {'msgtype': 'm.text', 'body': 'synthetic'},
    };

Future<void> _settle() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _sync(Client client, Room room,
        {required bool limited, String id = 'fresh-newest'}) async =>
    client.handleSync(SyncUpdate.fromJson({
      'next_batch': 'sync-next',
      'rooms': {
        'join': {
          room.id: {
            'timeline': {
              'limited': limited,
              'prev_batch': 'fresh-prev',
              'events': [_row(id, 500)],
            }
          }
        }
      },
    }));

class _Room extends Room {
  _Room(Client client) : super(id: '!continuity:synthetic', client: client);
  late Timeline timeline;
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      eventContextId == null
          ? timeline
          : super
              .getTimeline(eventContextId: eventContextId, onUpdate: onUpdate);
}

class _DatabaseClient extends Client {
  _DatabaseClient(this.store, {http.Client? httpClient})
      : super('continuity-store', httpClient: httpClient);
  final MatrixSdkDatabase store;
  @override
  DatabaseApi get database => store;
}

class _HeldStore extends MatrixSdkDatabase {
  _HeldStore(super.path,
      {required super.database, required super.sqfliteFactory});
  bool holdPage = false;
  bool holdUser = false;
  String? heldEventId;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Event?> getEventById(String eventId, Room room) async {
    final event = await super.getEventById(eventId, room);
    if (heldEventId == eventId) {
      heldEventId = null;
      entered.complete();
      await release.future;
    }
    return event;
  }

  @override
  Future<User?> getUser(String userId, Room room) async {
    if (holdUser) {
      holdUser = false;
      entered.complete();
      await release.future;
    }
    return super.getUser(userId, room);
  }

  @override
  Future<List<Event>> getEventList(Room room,
      {int start = 0, bool onlySending = false, int? limit}) async {
    final page = await super.getEventList(room,
        start: start, onlySending: onlySending, limit: limit);
    if (holdPage) {
      entered.complete();
      await release.future;
    }
    return page;
  }
}

Future<MatrixRoomTimelineAdapter> _adapter(_Room room) async {
  final owner = MatrixSdkE2eeClient(room.client,
      homeserver: Uri.parse('https://matrix.fixture.test'),
      readContinuityMetadata: (client) async => MatrixClientContinuityMetadata(
          isLoggedIn: client.isLogged(),
          userId: client.userID,
          deviceId: client.deviceID,
          ed25519Fingerprint: 'synthetic-fingerprint',
          databaseGeneration: 'synthetic-generation'));
  final lease = await owner.openRoomLease(room.id);
  return MatrixRoomTimelineAdapter(
      await lease.openRoomTimeline(onUpdate: () {}));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final limited in [true, false]) {
    test('delayed history respects fragment ownership, limited=$limited',
        () async {
      final entered = Completer<void>();
      final response = Completer<http.Response>();
      final client =
          Client('delayed-history', httpClient: MockClient((request) {
        expect(request.url.queryParameters['from'], 'cached-prev');
        entered.complete();
        return response.future;
      }))
            ..homeserver = Uri.parse('https://matrix.fixture.test')
            ..accessToken = 'synthetic-token';
      final room = _Room(client)..prev_batch = 'cached-prev';
      client.rooms.add(room);
      final timeline = room.timeline = Timeline(
          room: room,
          chunk: TimelineChunk(events: [
            Event.fromJson(_row('cached-latest', 20), room),
            Event.fromJson(_row('cached-anchor', 19), room),
          ]));
      try {
        final pending = timeline.requestHistory(historyCount: 2);
        await entered.future;
        await _sync(client, room, limited: limited);
        await _settle();
        response.complete(http.Response(
            jsonEncode({
              'start': 'cached-prev',
              'end': 'cached-older',
              'chunk': [_row('stale-18', 18), _row('stale-17', 17)],
            }),
            200));
        await pending;
        await _settle();
        expect(room.prev_batch, limited ? 'fresh-prev' : 'cached-older');
        expect(
            timeline.events.map((e) => e.eventId).toList(),
            limited
                ? ['fresh-newest']
                : [
                    'fresh-newest',
                    'cached-latest',
                    'cached-anchor',
                    'stale-18',
                    'stale-17'
                  ]);
      } finally {
        timeline.cancelSubscriptions();
        await client.dispose();
      }
    });
  }

  test('pinned controller retains visible history while live receives a gap',
      () async {
    final client = Client('pinned-history');
    final room = _Room(client)..prev_batch = 'cached-prev';
    client.rooms.add(room);
    room.timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [
          for (var i = 200; i > 0; i--)
            Event.fromJson(_row('cached-$i', i), room),
        ]));
    final adapter = await _adapter(room);
    final controller = RoomTimelineController(adapter, windowed: true);
    try {
      await controller.refresh();
      controller.pinWindow();
      final before = controller.messages.map((m) => m.id).toList();
      await _sync(client, room, limited: true);
      await _settle();
      await controller.refresh();
      expect(controller.messages.map((m) => m.id).toList(), before);
      expect(controller.newestMessage?.id, 'fresh-newest');
      expect(controller.isViewingHistoryContext, isTrue);
      await controller.showLatest();
      expect(controller.messages.map((m) => m.id), contains('fresh-newest'));
      expect(controller.isViewingHistoryContext, isFalse);
    } finally {
      controller.dispose();
      await client.dispose();
    }
  });

  test('pinned history after a gap obtains genuine context continuation',
      () async {
    final client = Client('pinned-context', httpClient: MockClient((request) {
      expect(request.url.path, contains('/context/cached-anchor'));
      return Future.value(http.Response(
          jsonEncode({
            'start': 'context-older',
            'end': 'context-newer',
            'event': _row('cached-anchor', 19),
            'events_before': [_row('neighbor-18', 18), _row('neighbor-17', 17)],
            'events_after': [_row('cached-latest', 20)],
          }),
          200));
    }))
      ..homeserver = Uri.parse('https://matrix.fixture.test')
      ..accessToken = 'synthetic-token';
    final room = _Room(client)..prev_batch = 'cached-prev';
    client.rooms.add(room);
    room.timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [
          Event.fromJson(_row('cached-latest', 20), room),
          Event.fromJson(_row('cached-anchor', 19), room),
        ]));
    final adapter = await _adapter(room);
    adapter.enableWindow();
    adapter.pinWindow();
    try {
      await _sync(client, room, limited: true);
      await _settle();
      await adapter.loadHistory();
      adapter.snapshot();
      adapter.selectEarlier();
      expect(adapter.snapshot().map((m) => m.id).toList(),
          ['neighbor-17', 'neighbor-18', 'cached-anchor', 'cached-latest']);
      expect(room.prev_batch, 'fresh-prev');
      expect(adapter.hasFutureHistory, isFalse,
          reason: 'the oldest-row context end is not the pinned newest edge');
    } finally {
      adapter.dispose();
      await client.dispose();
    }
  });

  test('pinned local identifier cursor survives limited sync without skipping',
      () async {
    final artifacts = Directory(
        '../../docs/verification/artifacts/2026-10-07/history-icons-performance/history-scroll');
    await artifacts.create(recursive: true);
    final directory = await artifacts.createTemp('pinned-store-');
    final path = '${directory.path}/matrix.sqlite';
    final store = MatrixSdkDatabase(path,
        database: await databaseFactoryFfi.openDatabase(path),
        sqfliteFactory: databaseFactoryFfi);
    await store.open();
    final client = _DatabaseClient(store);
    final room = _Room(client)..prev_batch = null;
    client.rooms.add(room);
    MatrixRoomTimelineAdapter? adapter;
    try {
      await store.transaction(() async {
        for (var i = 1; i <= 300; i++) {
          await store.storeEventUpdate(
              EventUpdate(
                  roomID: room.id,
                  type: EventUpdateType.timeline,
                  content: _row('local-$i', i)),
              client);
        }
      });
      room.timeline = Timeline(
          room: room,
          chunk:
              TimelineChunk(events: await store.getEventList(room, limit: 30)));
      adapter = await _adapter(room);
      adapter.enableWindow();
      adapter.pinWindow();
      await adapter.loadHistory();
      await _sync(client, room, limited: true);
      await _settle();
      await adapter.loadHistory();
      adapter.snapshot();
      expect(adapter.allMessages.map((m) => m.id).toList(),
          [for (var i = 151; i <= 300; i++) 'local-$i']);
      expect(adapter.newestMessage?.id, 'fresh-newest');
      adapter.selectLatest();
      expect(adapter.snapshot().map((m) => m.id), contains('fresh-newest'));
    } finally {
      adapter?.dispose();
      await client.dispose(closeDatabase: false);
      await store.close();
      await databaseFactoryFfi.deleteDatabase(path);
    }
  });

  test('late cached page cannot attach to a replacement live fragment',
      () async {
    final artifacts = Directory(
        '../../docs/verification/artifacts/2026-10-07/history-icons-performance/history-scroll');
    await artifacts.create(recursive: true);
    final directory = await artifacts.createTemp('held-store-');
    final path = '${directory.path}/matrix.sqlite';
    final store = _HeldStore(path,
        database: await databaseFactoryFfi.openDatabase(path),
        sqfliteFactory: databaseFactoryFfi);
    await store.open();
    final client = _DatabaseClient(store);
    final room = _Room(client)..prev_batch = null;
    client.rooms.add(room);
    Timeline? timeline;
    try {
      await store.transaction(() async {
        for (var i = 1; i <= 30; i++) {
          await store.storeEventUpdate(
              EventUpdate(
                  roomID: room.id,
                  type: EventUpdateType.timeline,
                  content: _row('local-$i', i)),
              client);
        }
      });
      timeline = Timeline(
          room: room,
          chunk:
              TimelineChunk(events: await store.getEventList(room, limit: 10)));
      store.holdPage = true;
      final request = timeline.requestHistory(historyCount: 10);
      await store.entered.future;
      await _sync(client, room, limited: true);
      await _settle();
      store.release.complete();
      await request;
      await _settle();
      expect(timeline.events.map((e) => e.eventId).toList(), ['fresh-newest']);
      expect(room.prev_batch, 'fresh-prev');
    } finally {
      timeline?.cancelSubscriptions();
      await client.dispose(closeDatabase: false);
      await store.close();
      await databaseFactoryFfi.deleteDatabase(path);
    }
  });

  test('pinned retained messages still observe authoritative redactions',
      () async {
    final client = Client('pinned-redaction');
    final room = _Room(client);
    client.rooms.add(room);
    room.timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [
          Event.fromJson(_row('cached-anchor', 19), room),
        ]));
    final adapter = await _adapter(room);
    adapter.enableWindow();
    adapter.pinWindow();
    try {
      await _sync(client, room, limited: true);
      await _settle();
      client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.timeline,
          content: {
            'event_id': 'recall',
            'type': EventTypes.Redaction,
            'sender': '@sender:synthetic',
            'origin_server_ts': 500 * 86400000,
            'redacts': 'cached-anchor',
            'content': <String, dynamic>{},
          }));
      await _settle();
      final retained = adapter.snapshot().single;
      expect(retained.id, 'cached-anchor');
      expect(retained.isRecalled, isTrue);
      expect(retained.text, isNot('synthetic'));
    } finally {
      adapter.dispose();
      await client.dispose();
    }
  });

  test('history processing cannot cross a gap during member lookup', () async {
    final artifacts = Directory(
        '../../docs/verification/artifacts/2026-10-07/history-icons-performance/history-scroll');
    await artifacts.create(recursive: true);
    final directory = await artifacts.createTemp('held-member-');
    final path = '${directory.path}/matrix.sqlite';
    final store = _HeldStore(path,
        database: await databaseFactoryFfi.openDatabase(path),
        sqfliteFactory: databaseFactoryFfi);
    await store.open();
    final client = _DatabaseClient(store,
        httpClient: MockClient((_) async => http.Response(
            jsonEncode({
              'start': 'cached-prev',
              'end': 'cached-older',
              'chunk': [_row('stale-18', 18), _row('stale-17', 17)]
            }),
            200)))
      ..homeserver = Uri.parse('https://matrix.fixture.test')
      ..accessToken = 'synthetic-token';
    final room = _Room(client)..prev_batch = 'cached-prev';
    client.rooms.add(room);
    final timeline = room.timeline = Timeline(
        room: room,
        chunk: TimelineChunk(
            events: [Event.fromJson(_row('cached-19', 19), room)]));
    try {
      store.holdUser = true;
      final pending = timeline.requestHistory(historyCount: 2);
      await store.entered.future;
      await _sync(client, room, limited: true);
      await _settle();
      store.release.complete();
      await pending;
      await _settle();
      expect(timeline.events.map((e) => e.eventId).toList(), ['fresh-newest']);
      expect((await store.getEventIdList(room)), ['fresh-newest']);
      expect(room.prev_batch, 'fresh-prev');
    } finally {
      timeline.cancelSubscriptions();
      await client.dispose(closeDatabase: false);
      await store.close();
      await databaseFactoryFfi.deleteDatabase(path);
    }
  });

  test('pinned pending cache page preserves a concurrent authoritative recall',
      () async {
    final artifacts = Directory(
        '../../docs/verification/artifacts/2026-10-07/history-icons-performance/history-scroll');
    await artifacts.create(recursive: true);
    final directory = await artifacts.createTemp('held-recall-');
    final path = '${directory.path}/matrix.sqlite';
    final store = _HeldStore(path,
        database: await databaseFactoryFfi.openDatabase(path),
        sqfliteFactory: databaseFactoryFfi);
    await store.open();
    final client = _DatabaseClient(store);
    final room = _Room(client);
    client.rooms.add(room);
    Timeline? live;
    Timeline? pinned;
    try {
      await store.transaction(() async {
        for (var i = 1; i <= 3; i++) {
          await store.storeEventUpdate(
              EventUpdate(
                  roomID: room.id,
                  type: EventUpdateType.timeline,
                  content: _row('local-$i', i)),
              client);
        }
      });
      live = Timeline(
          room: room,
          chunk:
              TimelineChunk(events: await store.getEventList(room, limit: 1)));
      pinned = Timeline.forkHistory(source: live, room: room);
      store.heldEventId = 'local-1';
      final pending = pinned.requestHistory(historyCount: 2);
      await store.entered.future;
      await client.handleSync(SyncUpdate.fromJson({
        'next_batch': 'recall-sync',
        'rooms': {
          'join': {
            room.id: {
              'timeline': {
                'limited': false,
                'events': [
                  {
                    'event_id': 'recall',
                    'type': EventTypes.Redaction,
                    'sender': '@sender:synthetic',
                    'origin_server_ts': 4 * 86400000,
                    'redacts': 'local-2',
                    'content': <String, dynamic>{},
                  }
                ],
              }
            }
          }
        },
      }));
      await _settle();
      expect((await store.getEventById('local-2', room))!.redacted, isTrue);
      store.release.complete();
      await pending;
      final recalled = pinned.events.singleWhere((e) => e.eventId == 'local-2');
      expect(recalled.redacted, isTrue);
      expect(recalled.content['body'], isNot('synthetic'));
      expect(pinned.events.map((e) => e.eventId),
          ['local-3', 'local-2', 'local-1']);
    } finally {
      pinned?.cancelSubscriptions();
      live?.cancelSubscriptions();
      await client.dispose(closeDatabase: false);
      await store.close();
      await databaseFactoryFfi.deleteDatabase(path);
    }
  });

  testWidgets(
      'actual variable-height list keeps its anchor through delayed sync and pagination',
      (tester) async {
    late Completer<void> entered;
    late Completer<http.Response> response;
    late Client client;
    late _Room room;
    late RoomTimelineController controller;
    await tester.runAsync(() async {
      entered = Completer<void>();
      response = Completer<http.Response>();
      client = Client('pinned-list', httpClient: MockClient((request) {
        expect(request.url.path, contains('/context/cached-1'));
        entered.complete();
        return response.future;
      }))
        ..homeserver = Uri.parse('https://matrix.fixture.test')
        ..accessToken = 'synthetic-token';
      room = _Room(client);
      client.rooms.add(room);
      room.timeline = Timeline(
          room: room,
          chunk: TimelineChunk(events: [
            for (var i = 200; i > 0; i--)
              Event.fromJson(_row('cached-$i', i), room),
          ]));
      final adapter = await _adapter(room);
      controller = RoomTimelineController(adapter, windowed: true);
      await controller.refresh();
    });
    final scroll = ScrollController();
    final viewport = GlobalKey();
    final keys = <String, GlobalKey>{};
    try {
      await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
              child: SizedBox(
                  key: viewport,
                  width: 360,
                  height: 500,
                  child: ListenableBuilder(
                      listenable: controller,
                      builder: (_, __) {
                        final ids = controller.messages.reversed
                            .map((m) => m.stableId)
                            .toList();
                        return AnchoredTimelineList(
                            controller: scroll,
                            eventIds: ids,
                            messageKeys: keys,
                            followLatest: false,
                            itemBuilder: (_, i) => SizedBox(
                                key: ValueKey(ids[i]),
                                child: SizedBox(
                                    key:
                                        keys.putIfAbsent(ids[i], GlobalKey.new),
                                    height: [
                                      44.0,
                                      120.0,
                                      240.0,
                                      64.0
                                    ][i % 4])));
                      })))));
      scroll.jumpTo(1200);
      await tester.pump();
      controller.pinWindow();
      final anchor = TimelineScrollAnchor.capture(keys, viewport)!;
      late Future<void> pending;
      await tester.runAsync(() async {
        pending = controller.loadHistory();
        await entered.future;
        await _sync(client, room, limited: true);
        await _settle();
        await controller.refresh();
      });
      await tester.pump();
      expect(tester.getRect(find.byKey(keys[anchor.eventId]!)).top,
          closeTo(anchor.globalY, 1));
      await tester.runAsync(() async {
        response.complete(http.Response(
            jsonEncode({
              'start': 'older-real-token',
              'end': 'newer-real-token',
              'event': _row('cached-1', 1),
              'events_before': [_row('older-0', 0)],
              'events_after': [],
            }),
            200));
        await pending;
      });
      await tester.pump();
      expect(tester.getRect(find.byKey(keys[anchor.eventId]!)).top,
          closeTo(anchor.globalY, 1));
      await controller.showEarlierWindow();
      await tester.pump();
      expect(tester.getRect(find.byKey(keys[anchor.eventId]!)).top,
          closeTo(anchor.globalY, 1));
      expect(controller.newestMessage?.id, 'fresh-newest');
    } finally {
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      controller.dispose();
      await tester.runAsync(() => client.dispose());
    }
  });
}
