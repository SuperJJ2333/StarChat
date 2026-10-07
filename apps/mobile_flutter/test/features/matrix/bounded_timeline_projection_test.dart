import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/local_hidden_events.dart';
import 'package:liuhetong_mobile/features/matrix/room_paged_history_source.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/local_room_history_search.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/bounded_history_search.dart';

import 'matrix_room_timeline_adapter_test.dart'
    show RetryClient, RetryRoom, openAdapter;

// Counts real SDK source access through the production adapter/capability.
// These no-database fixtures intentionally retain all supplied bodies: only
// unchanged projection work is measured here, not persisted resident eviction.
class _ReadCountingList<T> extends ListBase<T> {
  _ReadCountingList(this.values);
  final List<T> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => values.length = value;
  @override
  T operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, T value) => values[index] = value;
}

class _StoredClient extends RetryClient {
  _StoredClient(this.store);
  final MatrixSdkDatabase store;
  @override
  DatabaseApi get database => store;
}

class _HeldSearchOpenDatabase extends MatrixSdkDatabase {
  _HeldSearchOpenDatabase(super.path, {required super.database});
  final opened = Completer<MatrixSearchEventIds>();
  final release = Completer<void>();
  int payloadReads = 0;

  @override
  Future<MatrixSearchEventIds> openSearchEventIds(Room room,
      {int maxBytes = 32 * 1024 * 1024,
      MatrixSearchSnapshotBudget? budget}) async {
    final ids = await super
        .openSearchEventIds(room, maxBytes: maxBytes, budget: budget);
    opened.complete(ids);
    await release.future;
    return ids;
  }

  @override
  Future<List<Event?>> getSearchEventsByIds(Room room, List<String> eventIds) {
    payloadReads++;
    return super.getSearchEventsByIds(room, eventIds);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(sqfliteFfiInit);

  for (final revoke in [false, true]) {
    test(
        'public calendar fresh capture disposes after ${revoke ? 'revoke' : 'invalidate'}',
        () async {
      final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final db = _HeldSearchOpenDatabase('cancel-capture', database: sql);
      await db.open();
      final client = _StoredClient(db);
      final room = RetryRoom(client: client);
      client.room = room;
      final owner = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://test'),
          readContinuityMetadata: (_) async =>
              const MatrixClientContinuityMetadata(
                  isLoggedIn: false,
                  userId: null,
                  deviceId: null,
                  ed25519Fingerprint: 'synthetic',
                  databaseGeneration: 'synthetic'));
      final lease = await owner.openRoomLease(room.id);
      MatrixSearchEventIds? captured;
      try {
        await db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': 'capture-row',
                  'type': EventTypes.Message,
                  'sender': '@synthetic:test',
                  'origin_server_ts': 1000,
                  'content': {
                    'msgtype': MessageTypes.Text,
                    'body': 'synthetic'
                  },
                }),
            client);
        final rejected = expectLater(lease.readLocalSearchPage(room.id, 0, 64),
            throwsA(isA<HistorySearchCancelled>()));
        captured = await db.opened.future;
        if (revoke) {
          lease.revokeNow();
        } else {
          lease.invalidateLocalHistorySearch();
        }
        db.release.complete();
        await rejected;
        expect(db.payloadReads, 0);
        await expectLater(
            captured.page(0, 1),
            throwsA(isA<StateError>().having(
                (error) => error.message, 'message', contains('disposed'))));
      } finally {
        if (!db.release.isCompleted) db.release.complete();
        captured?.dispose();
        await lease.cancel();
        await client.dispose();
        await db.close();
      }
    });
  }

  test('member state outside resident content invalidates cached notices',
      () async {
    final client = RetryClient();
    final room = RetryRoom(client: client);
    client.room = room;
    Event membership(
            String id, String member, String sender, String kind, int time) =>
        Event.fromJson({
          'event_id': id,
          'type': EventTypes.RoomMember,
          'state_key': member,
          'sender': sender,
          'origin_server_ts': time,
          'content': {'membership': kind}
        }, room);
    void name(String displayName) => room.setState(User('@inviter:test',
        membership: 'join', displayName: displayName, room: room));
    name('Before');
    room.setState(User('@joined:test',
        membership: 'join', displayName: 'Joined', room: room));
    final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [
          membership('join', '@joined:test', '@joined:test', 'join', 200),
          membership('invite', '@joined:test', '@inviter:test', 'invite', 100),
        ]));
    final adapter = await openAdapter(room, timeline);
    try {
      adapter.enableWindow();
      expect(adapter.snapshot().single.text, contains('Before'));
      final sourceRevision = timeline.presentationRevision;
      name('After');
      await Future<void>.delayed(Duration.zero);
      expect(timeline.presentationRevision, sourceRevision,
          reason:
              'Only room member state changed, not resident event content.');
      expect(adapter.snapshot().single.text, contains('After'));
    } finally {
      adapter.dispose();
      await client.dispose();
    }
  });

  test('SDK delivery update invalidates a windowed cached sending row',
      () async {
    final client = RetryClient();
    final room = RetryRoom(client: client);
    client.room = room;
    Map<String, dynamic> row(EventStatus status) => {
          'event_id': 'pending',
          'type': EventTypes.Message,
          'sender': '@synthetic:test',
          'origin_server_ts': 100,
          'status': status.intValue,
          'content': {'msgtype': MessageTypes.Text, 'body': 'synthetic'},
        };
    final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(
            events: [Event.fromJson(row(EventStatus.sending), room)]));
    final adapter = await openAdapter(room, timeline);
    try {
      adapter.enableWindow();
      expect(adapter.snapshot().single.deliveryState.name, 'sending');
      client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.timeline,
          content: row(EventStatus.error)));
      await Future<void>.delayed(Duration.zero);
      final failed = adapter.snapshot();
      expect(failed.single.deliveryState.name, 'failed');
      expect(identical(adapter.snapshot(), failed), isTrue);
    } finally {
      adapter.dispose();
      await client.dispose();
    }
  });

  test('native evicted invite still renders its retained join notice',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('invite-boundary', database: sql);
    await db.open();
    final client = _StoredClient(db);
    final room = RetryRoom(client: client);
    client.room = room;
    room.setState(User('@inviter:test',
        membership: 'join', displayName: 'Inviter', room: room));
    room.setState(User('@joined:test',
        membership: 'join', displayName: 'Joined', room: room));
    try {
      for (var start = 0; start < 1001; start += 200) {
        await db.transaction(() async {
          for (var i = start; i < (start + 200).clamp(0, 1001); i++) {
            await db.storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: {
                      'event_id': i == 0
                          ? 'invite'
                          : i == 1
                              ? 'join'
                              : 'message-$i',
                      'type':
                          i < 2 ? EventTypes.RoomMember : EventTypes.Message,
                      if (i < 2) 'state_key': '@joined:test',
                      'sender': i == 0 ? '@inviter:test' : '@joined:test',
                      'origin_server_ts': i,
                      'content': i < 2
                          ? {'membership': i == 0 ? 'invite' : 'join'}
                          : {'msgtype': MessageTypes.Text, 'body': 'synthetic'},
                    }),
                client);
          }
        });
      }
      final timeline = Timeline(
          room: room,
          chunk:
              TimelineChunk(events: await db.getEventList(room, limit: 1001)));
      final adapter = await openAdapter(room, timeline);
      try {
        expect(timeline.events.length, 1000);
        expect(timeline.events.any((e) => e.eventId == 'invite'), isFalse);
        expect(timeline.retainedMembershipInvites['@joined:test']?.eventId,
            'invite');
        adapter.enableWindow();
        expect(adapter.selectAnchor('join'), isTrue);
        expect(adapter.snapshot().singleWhere((r) => r.id == 'join').text,
            'Inviter邀请Joined加入群聊');
        expect(await db.getEventById('invite', room), isNotNull);
      } finally {
        adapter.dispose();
      }
    } finally {
      await client.dispose();
      await db.close();
    }
  });

  test(
      'public search retries its frozen checkpoint after payload failure and live reset',
      () async {
    var payloadReads = 0;
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('consumer-checkpoint', database: sql);
    await db.open();
    final client = _StoredClient(db);
    final room = RetryRoom(client: client);
    client.room = room;
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        readContinuityMetadata: (_) async =>
            const MatrixClientContinuityMetadata(
                isLoggedIn: false,
                userId: null,
                deviceId: null,
                ed25519Fingerprint: 'synthetic',
                databaseGeneration: 'synthetic'));
    final lease = await owner.openRoomLease(room.id);
    var failPayload = true;
    final search = LocalRoomHistorySearch(
        roomIds: () => [room.id],
        pageSize: 64,
        readPage: lease.readLocalSearchPage,
        openIds: lease.openLocalSearchIds,
        readByIds: (roomId, ids) async {
          payloadReads++;
          if (payloadReads == 3 && failPayload) {
            throw StateError('Synthetic payload read failure');
          }
          return lease.readLocalSearchByIds(roomId, ids);
        },
        project: (_, row) => row);
    Future<void> save(String id, int sequence, String body) =>
        db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': id,
                  'type': EventTypes.Message,
                  'sender': '@synthetic:test',
                  'origin_server_ts': sequence,
                  'content': {'msgtype': MessageTypes.Text, 'body': body},
                }),
            client);
    try {
      for (var start = 0; start < 600; start += 200) {
        await db.transaction(() async {
          for (var i = start; i < start + 200; i++) {
            await save('saved-$i', i, i == 599 || i == 0 ? 'needle' : 'filler');
          }
        });
      }
      const filters = ChatSearchFilters(keyword: 'needle');
      final first = await search.search(filters, limit: 1);
      expect(first.items.single.eventId, 'saved-599');
      expect(payloadReads, 1);
      await expectLater(search.search(filters, cursor: first.nextCursor),
          throwsA(isA<StateError>()));
      expect(payloadReads, 3,
          reason: 'Failure follows advancement beyond the saved ID page.');
      await db.deleteTimelineForRoom(room.id);
      await save('fresh-head', 1000, 'needle');
      failPayload = false;
      var cursor = first.nextCursor;
      final retryIds = <String>[];
      do {
        final retry = await search.search(filters, cursor: cursor);
        retryIds.addAll(retry.items.map((r) => r.eventId));
        cursor = retry.nextCursor;
      } while (cursor != null);
      expect(retryIds, ['saved-0']);
      expect(await db.getTimelineEventCount(room), 1);
    } finally {
      search.cancel();
      await lease.cancel();
      await client.dispose();
      await db.close();
    }
  });

  test('window revision exposes SDK replacement redaction and hidden changes',
      () async {
    final client = RetryClient();
    final room = RetryRoom(client: client);
    client.room = room;
    Map<String, dynamic> row(String body) => {
          'event_id': 'target',
          'type': EventTypes.Message,
          'sender': '@synthetic:test',
          'origin_server_ts': 1000,
          'content': {'msgtype': 'm.text', 'body': body},
        };
    final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [Event.fromJson(row('before'), room)]));
    final adapter = await openAdapter(room, timeline);
    try {
      adapter.enableWindow();
      expect(adapter.snapshot().single.text, 'before');
      client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.timeline,
          content: row('after')));
      await Future<void>.delayed(Duration.zero);
      expect(adapter.snapshot().single.text, 'after');
      client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.timeline,
          content: {
            'event_id': 'redaction',
            'type': EventTypes.Redaction,
            'sender': '@synthetic:test',
            'origin_server_ts': 2000,
            'redacts': 'target',
            'content': <String, dynamic>{},
          }));
      await Future<void>.delayed(Duration.zero);
      expect(adapter.snapshot().single.isRecalled, isTrue);
      adapter.setHiddenFilter((id, _) => id == 'target');
      expect(adapter.snapshot(), isEmpty);
      adapter.setHiddenFilter(null);
      expect(adapter.snapshot().single.isRecalled, isTrue);
    } finally {
      adapter.dispose();
      await client.dispose();
    }
  });

  test(
      'visibility snapshot is reused until another store changes the same scope',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final first = SharedPreferencesLocalHiddenEvents(
        preferences: preferences, accountId: 'synthetic-a');
    final second = SharedPreferencesLocalHiddenEvents(
        preferences: preferences, accountId: 'synthetic-a');
    final other = SharedPreferencesLocalHiddenEvents(
        preferences: preferences, accountId: 'synthetic-b');
    final before = first.readFilter('room');
    expect(identical(before, first.readFilter('room')), isTrue);
    await second.hide('room', 'hidden');
    final after = first.readFilter('room');
    expect(before('hidden', null), isFalse);
    expect(after('hidden', null), isTrue);
    expect(other.readFilter('room')('hidden', null), isFalse);
    expect(first.readFilter('other')('hidden', null), isFalse);
    final cutoff = DateTime.utc(2026);
    await second.clearHistoryThrough('room', cutoff);
    expect(first.readFilter('room')('old', cutoff), isTrue);
    expect(
        identical(first.readFilter('room'), first.readFilter('room')), isTrue);
  });

  test('native bidirectional history keeps 1000 residents and every saved body',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('bounded-resident', database: sql);
    await db.open();
    final client = _StoredClient(db);
    final room = RetryRoom(client: client);
    client.room = room;
    Timeline? timeline;
    try {
      for (var start = 0; start < 1400; start += 200) {
        await db.transaction(() async {
          for (var i = start; i < start + 200; i++) {
            await db.storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: {
                      'event_id': 'saved-$i',
                      'type': 'm.room.message',
                      'sender': '@synthetic:test',
                      'origin_server_ts': i,
                      'content': {'msgtype': 'm.text', 'body': 'synthetic'},
                    }),
                client);
          }
        });
      }
      timeline = Timeline(
          room: room,
          chunk:
              TimelineChunk(events: await db.getEventList(room, limit: 1000)));
      final older = Timeline.forkHistory(source: timeline, room: room);
      try {
        for (var page = 0; page < 4; page++) {
          await older.requestHistory(historyCount: 100);
          expect(older.events.length, lessThanOrEqualTo(1000),
              reason:
                  'Saved older pages must replace resident rows, not accumulate.');
        }
        expect(older.events.last.eventId, 'saved-0');
        expect(older.canRequestFuture, isTrue,
            reason:
                'Evicted newer local rows remain reachable without nextBatch.');
        for (var page = 0; page < 4; page++) {
          await older.requestFuture(historyCount: 100);
          expect(older.events.length, lessThanOrEqualTo(1000));
        }
        expect(older.events.first.eventId, 'saved-1399');
        expect(await db.getTimelineEventCount(room), 1400);
        expect(await db.getEventById('saved-0', room), isNotNull);
        expect(await db.getEventById('saved-1399', room), isNotNull);
      } finally {
        older.cancelSubscriptions();
      }
      final adapter = await openAdapter(room, timeline);
      RoomHistoryReadCursor? cursor;
      try {
        adapter.enableWindow();
        final visible = adapter.snapshot().map((r) => r.id).toList();
        final read = <String>[];
        do {
          final page = await adapter.readHistoryPage(
              cursor: cursor,
              direction: RoomHistoryDirection.older,
              rawLimit: 64);
          if (!identical(cursor, page.nextCursor)) cursor?.dispose();
          cursor = page.nextCursor;
          expect(page.rawCount, lessThanOrEqualTo(64));
          read.addAll(page.messages.map((r) => r.id));
          if (page.exhausted) break;
          expect(cursor, isNotNull);
        } while (true);
        expect(read.length, 1400);
        expect(read.first, 'saved-1399');
        expect(read.last, 'saved-0');
        expect(adapter.snapshot().map((r) => r.id), visible,
            reason: 'Search/voice readers must not move the visible window.');
      } finally {
        cursor?.dispose();
        adapter.dispose();
      }
    } finally {
      timeline?.cancelSubscriptions();
      await client.dispose();
      await db.close();
    }
  });

  for (final size in [1000, 10000, 100000]) {
    test('unchanged SDK snapshot reads no raw rows with $size resident bodies',
        () async {
      final client = RetryClient();
      final room = RetryRoom(client: client);
      client.room = room;
      final events = _ReadCountingList(List.generate(
          size,
          (i) => Event(
              room: room,
              eventId: '\$synthetic-${size - i}',
              type: EventTypes.Message,
              senderId: '@synthetic:test',
              originServerTs: DateTime.fromMillisecondsSinceEpoch(size - i),
              content: {'msgtype': 'm.text', 'body': 'synthetic'})));
      final timeline =
          Timeline(room: room, chunk: TimelineChunk(events: events));
      final adapter = await openAdapter(room, timeline);
      try {
        adapter.enableWindow();
        adapter.selectEarlier();
        final before = adapter.snapshot();
        expect(before.length, 200);
        final newest = adapter.newestMessage;
        events.reads = 0;
        final after = adapter.snapshot();
        expect(identical(adapter.newestMessage, newest), isTrue);
        expect(after.map((row) => row.id), before.map((row) => row.id));
        expect(events.reads, 0,
            reason: 'No presentation revision changed; polling must not scan '
                'the SDK history again.');
        expect(timeline.events.length, size,
            reason: 'Unpersisted synthetic bodies must not be discarded.');
      } finally {
        adapter.dispose();
        timeline.cancelSubscriptions();
        await client.dispose();
      }
    });
  }
}
