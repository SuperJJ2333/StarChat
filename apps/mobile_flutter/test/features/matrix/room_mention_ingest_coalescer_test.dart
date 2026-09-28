import 'dart:async';
import 'dart:collection';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/room_mention_store.dart';
import 'package:liuhetong_mobile/features/matrix/local_hidden_events.dart';

class _Client extends Client {
  _Client() : super('mention-bounds');
  @override
  String? get userID => '@me:test';
}

class _Room extends Room {
  _Room(String id) : super(id: id, client: _Client());
  @override
  bool get isDirectChat => false;
  @override
  String get fullyRead => '';
}

Event _event(Room room, int i) => Event(
    room: room,
    eventId: 'e$i',
    type: EventTypes.Message,
    content: {'body': 'synthetic', 'msgtype': MessageTypes.Text},
    senderId: '@other:test',
    originServerTs: DateTime.utc(2026));

class _CountingContent extends MapBase<String, dynamic> {
  _CountingContent({bool mention = false})
      : _data = {
          'msgtype': MessageTypes.Text,
          'body': 'synthetic',
          if (mention)
            'm.mentions': {
              'user_ids': ['@me:test']
            },
        };
  static int mentionReads = 0;
  final Map<String, dynamic> _data;
  @override
  dynamic operator [](Object? key) {
    if (key == 'm.mentions') mentionReads++;
    return _data[key];
  }

  @override
  void operator []=(String key, dynamic value) => _data[key] = value;
  @override
  Iterable<String> get keys => _data.keys;
  @override
  void clear() => _data.clear();
  @override
  dynamic remove(Object? key) => _data.remove(key);
}

class _RedactedEvent extends Event {
  _RedactedEvent(Room room, String id)
      : super(
            room: room,
            eventId: id,
            type: EventTypes.Message,
            content: {},
            senderId: '@other:test',
            originServerTs: DateTime.utc(2026));
  @override
  bool get redacted => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      '4096 observations avoid old mention parsing across 10000 rows and 20 appends, preserving old recall',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = RoomMentionStore();
    final room = _Room('!large:test');
    Event row(int i) => Event(
        room: room,
        eventId: 'e$i',
        type: EventTypes.Message,
        content: _CountingContent(mention: i == 9000),
        senderId: '@other:test',
        originServerTs: DateTime.utc(2026));
    final rows = List.generate(10000, row);
    await store.ingest(room, rows);
    expect(store.observationEventCount(room), 4096);
    expect((await store.open(room)).pendingEventIdsNewestFirst(), ['e9000']);
    _CountingContent.mentionReads = 0;
    for (var i = 10000; i < 10020; i++) {
      rows.insert(0, row(i));
      await store.ingest(room, rows, changedEventIds: {'e$i'});
    }
    expect(_CountingContent.mentionReads, 20);
    rows[rows.indexWhere((e) => e.eventId == 'e9000')] =
        _RedactedEvent(room, 'e9000');
    await store.ingest(room, rows, changedEventIds: {'e9000'});
    expect((await store.open(room)).pendingCount, 0);
    // A newly decrypted old row must also be observed outside the small cache.
    final old = rows.firstWhere((e) => e.eventId == 'e9001');
    old.content['m.mentions'] = {
      'user_ids': ['@me:test']
    };
    await store.ingest(room, rows, changedEventIds: {'e9001'});
    expect((await store.open(room)).pendingEventIdsNewestFirst(), ['e9001']);
    await SharedPreferencesLocalHiddenEvents(
            preferences: await SharedPreferences.getInstance(),
            accountId: '@me:test')
        .hide(room.id, 'e9001');
    await store.ingest(room, rows, changedEventIds: {});
    expect((await store.open(room)).pendingCount, 0);
    expect(store.observationEventCount(room), 4096);
  });
  test('failed active ingestion clears single flight and remains retryable',
      () async {
    var calls = 0;
    final coalescer = MentionIngestCoalescer(
        isActive: () => true,
        ingest: (_) async {
          if (calls++ == 0) throw StateError('synthetic');
        });
    await expectLater(coalescer.request(), throwsStateError);
    await coalescer.request();
    expect(calls, 2);
  });
  test('overlapping notifications ingest one active and one latest source',
      () async {
    var source = 0, active = 0, maxActive = 0;
    final seen = <int>[];
    final gate = Completer<void>();
    final coalescer = MentionIngestCoalescer(
        isActive: () => true,
        ingest: (shouldContinue) async {
          active++;
          maxActive = active > maxActive ? active : maxActive;
          final current = source;
          if (current == 0) await gate.future;
          if (shouldContinue()) seen.add(current);
          active--;
        });
    final first = coalescer.request();
    for (var i = 1; i <= 100; i++) {
      source = i;
      coalescer.request();
    }
    gate.complete();
    await first;
    expect(seen, [0, 100]);
    expect(maxActive, 1);
  });
  test('revocation during await rejects late persistence and trailing request',
      () async {
    var active = true, persisted = 0, calls = 0;
    final gate = Completer<void>();
    final coalescer = MentionIngestCoalescer(
        isActive: () => active,
        ingest: (shouldContinue) async {
          calls++;
          await gate.future;
          if (shouldContinue()) persisted++;
        });
    final first = coalescer.request();
    coalescer.request();
    active = false;
    coalescer.cancel();
    gate.complete();
    await first;
    expect(calls, 1);
    expect(persisted, 0);
    active = true;
    await coalescer.request();
    expect(persisted, 1);
  });
  test('observation metadata is bounded per room and released on lease close',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store =
        RoomMentionStore(maxObservationRooms: 2, maxObservationEvents: 3);
    final first = _Room('!1:test'),
        second = _Room('!2:test'),
        third = _Room('!3:test');
    await store.ingest(first, List.generate(10, (i) => _event(first, i)));
    expect(store.observationEventCount(first), 3);
    await store.ingest(second, [_event(second, 1)]);
    await store.ingest(third, [_event(third, 1)]);
    expect(store.observationRoomCount, 2);
    expect(store.observationEventCount(first), 0);
    store.invalidateObservation(third);
    expect(store.observationRoomCount, 1);
    expect(store.observationEventCount(third), 0);
  });
}
