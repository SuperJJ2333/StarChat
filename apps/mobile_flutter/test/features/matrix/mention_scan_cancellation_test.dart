import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/room_mention_store.dart';
import 'package:liuhetong_mobile/features/matrix/unread_mention_tracker.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';

class _Client extends Client {
  _Client(this.store) : super('mention-cancel');
  final DatabaseApi store;
  @override
  DatabaseApi get database => store;
  @override
  String? get userID => '@me:test';
}

class _Room extends Room {
  _Room(this.history) : super(id: '!room:test', client: _Client(history)) {
    prev_batch = 'older';
  }
  final _History history;
  @override
  bool get isDirectChat => false;
  @override
  String get fullyRead => '';
  @override
  Future<int> requestHistory(
      {int historyCount = Room.defaultHistoryCount,
      void Function()? onHistoryReceived,
      direction = Direction.b}) async {
    await history.requestHistory();
    prev_batch = null;
    return 1;
  }

  @override
  Future<Event?> getLocalEventById(String id,
          {bool Function()? shouldContinue}) async =>
      history.events.firstWhere((event) => event.eventId == id);
}

class _Snapshot extends ListTimelineIdSnapshot {
  _Snapshot(super.ids, this.closed);
  final void Function() closed;
  @override
  void dispose() {
    closed();
    super.dispose();
  }
}

class _History extends Fake implements DatabaseApi {
  final requested = Completer<void>();
  final release = Completer<void>();
  final events = <Event>[];
  int requests = 0;
  bool canceled = false;
  @override
  Future<TimelineIdSnapshot> openTimelineIdSnapshot(Room room,
          {String? afterEventId,
          bool includeSending = false,
          TimelineIdDirection direction = TimelineIdDirection.older}) async =>
      _Snapshot(
          events.map((event) => event.eventId).toList(), () => canceled = true);
  Future<void> requestHistory() async {
    requests++;
    if (!requested.isCompleted) requested.complete();
    await release.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'revocation after in-flight history stops scan without saving page or checkpoint',
      () async {
    SharedPreferences.setMockInitialValues({});
    MaintenanceActivity.instance.resetForTesting();
    final history = _History();
    final room = _Room(history);
    history.events.add(Event(
        room: room,
        eventId: 'head',
        type: EventTypes.Message,
        content: {'msgtype': MessageTypes.Text, 'body': ''},
        senderId: '@other:test',
        originServerTs: DateTime.utc(2026)));
    final store = RoomMentionStore();
    var allowed = true;
    final scan = store.scan(room, shouldContinue: () => allowed);
    await history.requested.future;
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getString('chat-mentions-v2:@me:test:!room:test');
    allowed = false;
    history.events.add(Event(
        room: room,
        eventId: 'older-mention',
        type: EventTypes.Message,
        content: {
          'msgtype': MessageTypes.Text,
          'body': '',
          'm.mentions': {
            'user_ids': ['@me:test']
          }
        },
        senderId: '@other:test',
        originServerTs: DateTime.utc(2025)));
    history.release.complete();
    await scan;
    expect(history.requests, 1);
    expect(history.canceled, true);
    expect(store.hasPending(room), false);
    expect(prefs.getString('chat-mentions-v2:@me:test:!room:test'), before);
    expect((await store.open(room)).completedScanHead, isNull);
  });
  test('visible potential uses half viewport for oversized messages', () {
    expect(mentionVisibleHeightThreshold(100, 600), 50);
    expect(mentionVisibleHeightThreshold(1800, 600), 300);
    expect(mentionVisibleHeightThreshold(600, 600), 300);
  });
}
