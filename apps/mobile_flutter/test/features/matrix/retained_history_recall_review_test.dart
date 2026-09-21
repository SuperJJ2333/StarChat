import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/bounded_history_search.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_viewport.dart';

RoomMessageViewModel row(int id, {bool recalled = false}) =>
    RoomMessageViewModel(
      id: '$id',
      senderId: 'fixture',
      text: recalled
          ? ''
          : (id == 99 || id == 98 ? 'private needle' : 'ordinary'),
      isOwn: false,
      isRecalled: recalled,
      deliveryState: RoomDeliveryState.sent,
      timestamp: DateTime.utc(2026).add(Duration(seconds: id)),
    );

class _Capability extends Fake
    implements RoomTimelineCapability, RoomNewestFirstTimelineSource {
  _Capability(this.viewport);
  final RoomTimelineViewport<RoomMessageViewModel> viewport;
  @override
  List<RoomMessageViewModel> snapshot() => viewport.all.toList();
  @override
  Iterable<RoomMessageViewModel> get newestFirstMessages =>
      viewport.newestFirst;
  @override
  Iterable<RoomMessageViewModel> historyNewestFirst({String? beforeEventId}) =>
      viewport.historyNewestFirst(beforeEventId: beforeEventId);
  @override
  void dispose() {}
}

ChatSearchMessage? project(RoomMessageViewModel? message) =>
    message == null || message.isRecalled
        ? null
        : ChatSearchMessage(
            eventId: message.id,
            senderId: message.senderId,
            senderDisplayName: 'Fixture',
            timestamp: message.timestamp,
            timelineOrder: message.timestamp.millisecondsSinceEpoch,
            visibleText: message.text,
          );

void main() {
  test('retained scan revalidates recalled and removed rows before exposure',
      () async {
    final viewport = RoomTimelineViewport<RoomMessageViewModel>(
        idOf: (message) => message.id, project: (message) => message);
    viewport.update(List.generate(700, row));
    final controller = RoomTimelineController(
        MatrixRoomTimelineAdapter(_Capability(viewport)),
        windowed: true);
    addTearDown(controller.dispose);

    BoundedHistorySearch<RoomMessageViewModel> scanner(
            {required bool current}) =>
        BoundedHistorySearch(
          snapshot: () => controller.newestFirstMessages,
          snapshotBefore: (id) =>
              controller.historyNewestFirst(beforeEventId: id),
          eventId: (message) => message.id,
          project: (message) =>
              project(current ? controller.findMessage(message.id) : message),
          exhausted: () => true,
          loadEarlier: () async {},
        );
    final stale = scanner(current: false);
    final safe = scanner(current: true);
    const filters = ChatSearchFilters(keyword: 'needle');
    final oldFirst = await stale.search(filters);
    final safeFirst = await safe.search(filters);
    expect(oldFirst.items, isEmpty);
    expect(safeFirst.items, isEmpty);
    expect(safeFirst.nextCursor, isNotNull);

    // Both iterators retain the pre-update 700-row reference list. The next
    // unvisited row is recalled; the row after it disappears from the source.
    viewport.update([
      for (var id = 0; id < 700; id++)
        if (id != 98) row(id, recalled: id == 99),
    ]);
    await controller.refresh();
    final oldNext = await stale.search(filters, cursor: oldFirst.nextCursor);
    final safeNext = await safe.search(filters, cursor: safeFirst.nextCursor);
    expect(oldNext.items.map((message) => message.eventId), ['99', '98'],
        reason: 'The pre-fix projection exposes both stale private bodies.');
    expect(safeNext.items, isEmpty,
        reason:
            'Current indexed lookup must reject recall and source removal.');
    expect(safeNext.nextCursor, isNull);
  });
}
