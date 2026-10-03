import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

class _Client extends Client {
  _Client() : super('search-progress-synthetic');
  late Room room;
  @override
  Room? getRoomById(String id) => id == room.id ? room : null;
}

class _Room extends Room {
  _Room(_Client client) : super(id: '!progress:synthetic', client: client) {
    client.room = this;
  }
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      _Timeline();
}

class _Timeline extends Fake implements Timeline {
  @override
  final events = <Event>[];
  @override
  void cancelSubscriptions() {}
}

void main() {
  testWidgets(
      'SDK history and old decryption complete one stable search; recall purges it',
      (tester) async {
    final client = _Client();
    final room = _Room(client);
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.invalid'));
    final lease = await owner.openRoomLease(room.id);
    await lease.openLogicalRoomTimeline(onUpdate: () {});
    var queries = 0;
    final pending = Completer<List<ChatSearchMessage>>();
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
      isGroup: false,
      memberEntries: const [],
      historyChanges: lease.localHistoryChanges,
      ordinaryAppends: lease.localHistoryAppends,
      onJumpToMessage: (_) {},
      search: (_, {cursor, limit = 50}) {
        queries++;
        return queries == 1 ? pending.future : Future.value([]);
      },
    )));
    await tester.enterText(
        find.byKey(const Key('chat-search-input')), 'needle');
    await tester.pump(const Duration(milliseconds: 350));
    final revision = lease.localHistorySearchRevision;
    for (final type in [
      EventUpdateType.history,
      EventUpdateType.decryptedTimelineQueue
    ]) {
      client.onEvent.add(EventUpdate(roomID: room.id, type: type, content: {
        'event_id': r'$old',
        'type': EventTypes.Message,
        'content': {'msgtype': MessageTypes.Text, 'body': 'synthetic needle'},
      }));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    pending.complete([
      ChatSearchMessage(
          eventId: r'$old',
          senderId: '@synthetic:test',
          senderDisplayName: 'synthetic',
          timestamp: DateTime(2025, 9, 1),
          timelineOrder: 1,
          visibleText: 'synthetic needle')
    ]);
    await tester.pump();
    expect(queries, 1);
    expect(lease.localHistorySearchRevision, revision);
    expect(find.byKey(const Key(r'chat-search-result-$old')), findsOneWidget);
    client.onEvent.add(
        EventUpdate(roomID: room.id, type: EventUpdateType.history, content: {
      'event_id': r'$recall',
      'type': EventTypes.Redaction,
      'content': {'redacts': r'$old'},
    }));
    await tester.pump();
    expect(find.byKey(const Key(r'chat-search-result-$old')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await lease.cancel();
    await client.dispose();
    await tester.pump(const Duration(milliseconds: 50));
  });
}
