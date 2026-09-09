import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/room_mention_store.dart';
import 'package:liuhetong_mobile/features/matrix/unread_mention_tracker.dart';

class _Client extends Client {
  _Client() : super('mention-cancel');
  @override
  String? get userID => '@me:test';
}

class _Room extends Room {
  _Room(this.history) : super(id: '!room:test', client: _Client());
  final _Timeline history;
  @override
  bool get isDirectChat => false;
  @override
  String get fullyRead => '';
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      history;
}

class _Timeline extends Fake implements Timeline {
  final requested = Completer<void>();
  final release = Completer<void>();
  @override
  final events = <Event>[];
  int requests = 0;
  bool canceled = false;
  @override
  bool get canRequestHistory => true;
  @override
  Future<void> requestHistory({int historyCount = 30}) async {
    requests++;
    if (!requested.isCompleted) requested.complete();
    await release.future;
  }

  @override
  void cancelSubscriptions() => canceled = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'revocation after in-flight history stops scan without saving page or checkpoint',
      () async {
    SharedPreferences.setMockInitialValues({});
    final history = _Timeline();
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
