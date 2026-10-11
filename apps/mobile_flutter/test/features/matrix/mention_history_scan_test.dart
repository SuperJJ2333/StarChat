import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';
import 'package:liuhetong_mobile/features/matrix/room_mention_store.dart';
import 'package:liuhetong_mobile/features/matrix/mention_history_scan.dart';

class _Database extends Fake implements DatabaseApi {
  _Database(this.ids);
  final List<String> ids;
  int opens = 0;
  @override
  Future<TimelineIdSnapshot> openTimelineIdSnapshot(Room room,
      {String? afterEventId,
      bool includeSending = false,
      TimelineIdDirection direction = TimelineIdDirection.older}) async {
    opens++;
    return ListTimelineIdSnapshot(ids,
        afterEventId: afterEventId, direction: direction);
  }
}

class _RejectingPreferences extends InMemorySharedPreferencesStore {
  _RejectingPreferences() : super.empty();
  bool rejectWrites = false;
  int writes = 0;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes++;
    if (rejectWrites) return false;
    return super.setValue(valueType, key, value);
  }
}

class _Client extends Client {
  _Client(this.store) : super('mention-pages');
  final DatabaseApi store;
  @override
  DatabaseApi get database => store;
  @override
  String get userID => '@me:test';
}

class _Room extends Room {
  _Room(this.count)
      : super(
            id: '!room:test',
            client: _Client(_Database(List.generate(count, (i) => 'e$i'))));
  final int count;
  int payloadReads = 0;
  int legacyPeak = 0;
  String marker = '';
  Future<void> Function(String)? beforeRead;
  Future<int> Function()? historyRequest;
  final reads = <String, int>{};
  @override
  bool get isDirectChat => false;
  @override
  String get fullyRead => marker;
  Event event(String id) => Event(
      room: this,
      eventId: id,
      type: EventTypes.Message,
      content: {
        'msgtype': MessageTypes.Text,
        'body': 'synthetic',
        'm.mentions': {
          'user_ids': ['@me:test']
        }
      },
      senderId: '@other:test',
      originServerTs: DateTime.utc(2026));
  @override
  Future<Event?> getLocalEventById(String id,
      {bool Function()? shouldContinue}) async {
    await beforeRead?.call(id);
    payloadReads++;
    reads[id] = (reads[id] ?? 0) + 1;
    return event(id);
  }

  @override
  Future<int> requestHistory(
          {int historyCount = Room.defaultHistoryCount,
          void Function()? onHistoryReceived,
          direction = Direction.b}) async =>
      await historyRequest?.call() ?? 0;

  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      _GrowingTimeline(this)..grow();
}

class _GrowingTimeline extends Fake implements Timeline {
  _GrowingTimeline(this.room);
  @override
  final _Room room;
  @override
  final events = <Event>[];
  void grow() {
    final end = (events.length + 256).clamp(0, room.count);
    for (var i = events.length; i < end; i++) {
      events.add(room.event('e$i'));
    }
    room.legacyPeak = events.length;
  }

  @override
  bool get canRequestHistory => events.length < room.count;
  @override
  Future<void> requestHistory({int historyCount = 30}) async => grow();
  @override
  void cancelSubscriptions() => events.clear();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MaintenanceActivity.instance.resetForTesting();
  });
  test('100000 history rows retain at most one body page and read each once',
      () async {
    final room = _Room(100000);
    final store = RoomMentionStore();
    // Stop the old accumulating implementation at its first budget violation;
    // the fixture still represents the entire 100k unread interval.
    await store.scan(room, shouldContinue: () => room.legacyPeak <= 256);
    expect(room.legacyPeak, lessThanOrEqualTo(256),
        reason: 'a history Timeline must not accumulate decrypted bodies');
    expect(room.payloadReads, room.count);
    expect(room.reads.values.every((count) => count == 1), isTrue);
    final state = await store.open(room);
    expect(state.pendingCount, room.count);
    expect(state.completedScanHead, 'e0');
  });

  for (final count in [1000, 10000, 100000]) {
    test('$count row reader releases all consumed page bodies', () async {
      final room = _Room(count);
      final reader = await MentionHistoryScan.open(room);
      MentionScanPage? previous;
      var total = 0;
      var peak = 0;
      while (true) {
        final page = await reader.next();
        expect(previous?.events, anyOf(isNull, isEmpty));
        total += page.events.length;
        peak = page.events.length > peak ? page.events.length : peak;
        previous = page;
        if (!page.hasMore) break;
      }
      await reader.close();
      expect(previous.events, isEmpty);
      expect(peak, 256);
      expect(total, count);
      expect(room.payloadReads, count);
    });
  }

  test('captured read marker and head survive receipt and newer sync changes',
      () async {
    final room = _Room(1000)..marker = 'e600';
    final store = RoomMentionStore();
    room.beforeRead = (id) async {
      if (id != 'e0') return;
      room.marker = 'e1';
      (room.client.database! as _Database).ids.insert(0, 'newer');
    };
    await store.scan(room);
    final state = await store.open(room);
    expect(state.boundaryEventId, 'e600');
    expect(state.completedScanHead, 'e0');
    expect(state.pendingCount, 600);
    expect(room.payloadReads, 601);
    state.markViewed('e0');
    state.onRedacted('e1');
    await store.save(room);
    room.beforeRead = null;
    await store.scan(room);
    expect(state.completedScanHead, 'newer');
    expect(state.pendingEventIdsNewestFirst(), isNot(contains('e0')));
    expect(state.pendingEventIdsNewestFirst(), isNot(contains('e1')));
    expect(state.pendingEventIdsNewestFirst().first, 'newer');
  });

  test('unreachable read marker resolves without rereading any body', () async {
    final room = _Room(1000)..marker = 'missing';
    final store = RoomMentionStore();
    await store.scan(room);
    final state = await store.open(room);
    expect(state.boundaryEventId, '');
    expect(state.pendingCount, 1000);
    expect(room.payloadReads, 1000);
    expect(room.reads.values.every((count) => count == 1), isTrue);
  });

  test('revocation before checkpoint persistence cannot move in-memory head',
      () async {
    final room = _Room(1);
    final store = RoomMentionStore();
    final state = await store.open(room);
    await store.scan(room,
        shouldContinue: () => state.completedScanHead == null);
    expect(state.completedScanHead, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('chat-mentions-v2:@me:test:!room:test'),
        isNot(contains('"completedScanHead":"e0"')));
  });

  test('failed platform write retains pending and retries the uncommitted head',
      () async {
    final platform = _RejectingPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    final room = _Room(2);
    final store = RoomMentionStore();
    final state = await store.open(room);
    var published = 0;
    store.addListener(() => published++);
    platform.rejectWrites = true;
    await store.scan(room);
    expect(state.pendingCount, 2);
    expect(published, 0);
    expect(state.completedScanHead, isNull,
        reason: 'a false platform result must not acknowledge a checkpoint');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('chat-mentions-v2:@me:test:!room:test'),
        isNot(contains('"completedScanHead":"e0"')),
        reason: 'failed optimistic preference cache must not look committed');
    platform.rejectWrites = false;
    await store.scan(room);
    expect(room.payloadReads, 4);
    expect(state.pendingCount, 2);
    expect(state.completedScanHead, 'e0');
    expect(published, 1);
    expect((await platform.getAll()).values.single,
        contains('"completedScanHead":"e0"'));
  });

  test(
      'failed initial platform write does not cache a successfully opened state',
      () async {
    final platform = _RejectingPreferences()..rejectWrites = true;
    SharedPreferencesStorePlatform.instance = platform;
    final room = _Room(1);
    final store = RoomMentionStore();
    await expectLater(store.open(room), throwsStateError);
    expect((await platform.getAll()), isEmpty);
    platform.rejectWrites = false;
    await store.scan(room);
    expect(platform.writes, 3,
        reason: 'retry must reopen successfully before saving the scan');
    expect((await store.open(room)).completedScanHead, 'e0');
  });

  testWidgets('interaction stops page reads until 500ms quiet', (tester) async {
    var now = DateTime.utc(2026);
    final maintenance = MaintenanceActivity(clock: () => now);
    addTearDown(maintenance.dispose);
    maintenance.setInteractive('scroll', true);
    final room = _Room(512);
    final opening = MentionHistoryScan.open(room, maintenance: maintenance);
    await tester.pump();
    expect((room.client.database! as _Database).opens, 0);
    maintenance.setInteractive('scroll', false);
    now = now.add(const Duration(milliseconds: 499));
    await tester.pump(const Duration(milliseconds: 499));
    expect((room.client.database! as _Database).opens, 0);
    now = now.add(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    final reader = await opening;
    final first = await reader.next();
    expect(room.payloadReads, 256);
    first.release();
    maintenance.setInteractive('keyboard', true);
    final next = reader.next();
    await tester.pump();
    expect(room.payloadReads, 256);
    maintenance.setInteractive('keyboard', false);
    now = now.add(const Duration(milliseconds: 499));
    await tester.pump(const Duration(milliseconds: 499));
    expect(room.payloadReads, 256);
    now = now.add(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect((await next).events.length, 256);
    await reader.close();
  });

  testWidgets(
      'metadata registration yields at 256 IDs and cancels while interactive',
      (tester) async {
    final room = _Room(1000);
    final store = RoomMentionStore();
    final state = await store.open(room);
    final maintenance = MaintenanceActivity.instance;
    var sawPartial = false;
    void observe() {
      if (state.hasEventOrder('e255') && !state.hasEventOrder('e256')) {
        sawPartial = true;
        maintenance.setInteractive('keyboard', true);
      }
    }

    maintenance.addListener(observe);
    addTearDown(() {
      maintenance.removeListener(observe);
      maintenance.resetForTesting();
    });
    var allowed = true;
    var finished = false;
    unawaited(store
        .scan(room, shouldContinue: () => allowed)
        .then((_) => finished = true));
    await tester.pump();
    expect(sawPartial, isTrue,
        reason: 'full-interval synchronous registration bypasses maintenance');
    expect(state.hasEventOrder('e256'), isFalse);
    expect(room.payloadReads, 0);
    allowed = false;
    await tester.pump(const Duration(milliseconds: 200));
    expect(finished, isTrue);
    expect(state.completedScanHead, isNull);
  });

  testWidgets('cancel hung body read completes within 200ms without checkpoint',
      (tester) async {
    final room = _Room(512);
    final pending = Completer<void>();
    var reading = false;
    room.beforeRead = (_) {
      reading = true;
      return pending.future;
    };
    var allowed = true;
    var finished = false;
    final store = RoomMentionStore();
    unawaited(store
        .scan(room, shouldContinue: () => allowed)
        .then((_) => finished = true));
    await tester.pump();
    expect(reading, isTrue);
    allowed = false;
    await tester.pump(const Duration(milliseconds: 200));
    expect(finished, isTrue);
    expect((await store.open(room)).completedScanHead, isNull);
    expect(store.hasPending(room), isFalse);
    pending.complete();
    await tester.pump();
    expect(store.hasPending(room), isFalse);
  });

  test('server history extends only behind the captured tail', () async {
    final room = _Room(256)..prev_batch = 'older';
    var requests = 0;
    room.historyRequest = () async {
      requests++;
      final ids = (room.client.database! as _Database).ids;
      ids.insert(0, 'live-newer');
      ids.addAll(List.generate(256, (i) => 'e${i + 256}'));
      room.prev_batch = null;
      return 256;
    };
    final store = RoomMentionStore();
    await store.scan(room);
    expect(requests, 1);
    expect(room.reads.containsKey('live-newer'), isFalse);
    expect(room.payloadReads, 512);
    expect((await store.open(room)).completedScanHead, 'e0');
  });

  testWidgets('hung history network does not hold another maintenance owner',
      (tester) async {
    final room = _Room(1)..prev_batch = 'older';
    final network = Completer<int>();
    var requesting = false;
    room.historyRequest = () {
      requesting = true;
      return network.future;
    };
    var allowed = true;
    var finished = false;
    final store = RoomMentionStore();
    unawaited(store
        .scan(room, shouldContinue: () => allowed)
        .then((_) => finished = true));
    await tester.pump();
    expect(requesting, isTrue);
    MaintenanceLease? anotherOwner;
    final maintenance = MaintenanceActivity.instance;
    unawaited(maintenance.acquireHeavy().then((lease) => anotherOwner = lease));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    try {
      expect(anotherOwner, isNotNull,
          reason: 'network waiting must not consume the local heavy budget');
      expect(room.payloadReads, 0);
    } finally {
      allowed = false;
      anotherOwner?.release();
      network.complete(0);
      await tester.pump(const Duration(milliseconds: 200));
      // On the RED implementation the queued owner only acquires after cancel.
      anotherOwner?.release();
    }
    expect(finished, isTrue);
    expect((await store.open(room)).completedScanHead, isNull);
  });

  testWidgets('history reply reacquires maintenance before any body read',
      (tester) async {
    final room = _Room(1)..prev_batch = 'older';
    final network = Completer<int>();
    room.historyRequest = () => network.future;
    var finished = false;
    final store = RoomMentionStore();
    unawaited(store.scan(room).then((_) => finished = true));
    await tester.pump();
    final anotherOwner = await MaintenanceActivity.instance.acquireHeavy();
    expect(anotherOwner, isNotNull);
    room.prev_batch = null;
    network.complete(0);
    await tester.pump();
    expect(room.payloadReads, 0);
    expect(finished, isFalse);
    anotherOwner!.release();
    await tester.pump();
    expect(room.payloadReads, 1);
    expect(finished, isTrue);
    expect((await store.open(room)).completedScanHead, 'e0');
  });
}
