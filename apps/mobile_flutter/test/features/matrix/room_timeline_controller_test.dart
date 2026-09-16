import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_date_capability.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

class FakeTimelineAdapter implements RoomTimelineAdapter {
  final items = <RoomMessageViewModel>[];
  int disposed = 0;
  int marks = 0;
  final redPackets = <String>[];
  int retries = 0;
  Object? sendFailure;
  @override
  Future<Uint8List> loadAttachment(String eventId) async =>
      Uint8List.fromList([1, 2, 3]);
  @override
  Future<Uint8List?> loadThumbnail(String eventId) async => null;
  int historyPages = 1; // 每次加载追加的消息数；0 表示已无更多
  int historyCalls = 0;
  @override
  Future<void> loadHistory() async {
    historyCalls++;
    for (var i = 0; i < historyPages; i++) {
      items.insert(
        0,
        RoomMessageViewModel(
          id: 'history-$historyCalls-$i',
          senderId: 'peer',
          text: '早前消息',
          isOwn: false,
          deliveryState: RoomDeliveryState.sent,
          timestamp: DateTime.utc(2026, 8, 1),
        ),
      );
    }
  }

  @override
  Future<void> markRead() async => marks++;
  int retryCalls = 0;
  Completer<void>? retryPending;
  @override
  Future<void> retry(String transactionId) async {
    retryCalls++;
    await retryPending?.future;
  }

  @override
  Future<String> sendText(String text) async {
    final failure = sendFailure;
    if (failure != null) throw failure;
    return 'event-1';
  }

  @override
  Future<String> sendRedPacketReference(
    String packetId,
    String greeting, {
    String? mode,
    String? recipientId,
    String? recipientMatrixId,
  }) async {
    redPackets.add('$packetId:$greeting');
    redPacketTargets
        .add('${mode ?? ''}|${recipientId ?? ''}|${recipientMatrixId ?? ''}');
    return 'event-red-packet';
  }

  final transfers = <String>[];
  final redPacketTargets = <String>[];
  final transferTargets = <String>[];
  @override
  Future<String> sendTransferReference(
    String transferId,
    String amount,
    String? note, {
    String? receiverId,
    String? receiverMatrixId,
  }) async {
    transfers.add('$transferId:$amount:$note');
    transferTargets
        .add('${receiverId ?? ''}|${receiverMatrixId ?? ''}');
    return 'event-transfer';
  }

  @override
  List<RoomMessageViewModel> snapshot() => List.of(items);
  @override
  void dispose() => disposed++;
}

final class DeferredHistoryTimelineAdapter extends FakeTimelineAdapter
    implements RoomHistoryDateSource, RoomWindowedTimelineSource {
  final historyRequests = <Completer<void>>[];
  int latestCalls = 0;
  bool viewingHistory = true;
  RoomHistoryDayLocation? dateLocation;

  @override
  bool get isViewingHistoryContext => viewingHistory;

  @override
  void cancelPendingDateLookup() {}

  @override
  Future<void> loadHistory() {
    final pending = Completer<void>();
    historyRequests.add(pending);
    return pending.future;
  }

  @override
  Iterable<RoomHistoryDayMetadata> get loadedDayMetadata => const [];

  @override
  Future<RoomHistoryDayLocation?> locateDay(DateTime localDay) async {
    viewingHistory = true;
    return dateLocation;
  }

  @override
  void selectLatest() {
    latestCalls++;
    viewingHistory = false;
  }

  @override
  void enableWindow() {}
  @override
  void setHiddenFilter(bool Function(String, DateTime?)? hidden) {}
  @override
  bool get hasEarlierWindow => false;
  @override
  bool get hasLaterWindow => false;
  @override
  int get totalMessages => items.length;
  @override
  Iterable<RoomMessageViewModel> get allMessages => items;
  @override
  RoomMessageViewModel? findMessage(String id) => null;
  @override
  RoomMessageViewModel? get newestMessage => items.lastOrNull;
  @override
  DateTime? previousTimestamp(String id) => null;
  @override
  bool selectAnchor(String id) => false;
  @override
  void selectEarlier() {}
  @override
  void selectLater() {}
  @override
  void pinWindow() {}
}

void main() {
  testWidgets('SDK burst publishes once per frame and local echo is immediate',
      (tester) async {
    final adapter = FakeTimelineAdapter();
    final controller = RoomTimelineController(adapter);
    var notifications = 0;
    controller.addListener(() => notifications++);
    for (var i = 0; i < 100; i++) {
      adapter.items.add(RoomMessageViewModel(
          id: '$i',
          senderId: 'peer',
          text: 'fixture',
          isOwn: false,
          deliveryState: RoomDeliveryState.sent,
          timestamp: DateTime.utc(2026)));
      controller.scheduleRefresh();
    }
    expect(notifications, 0);
    await tester.pump();
    expect(notifications, 1);
    final send = controller.sendText('local fixture');
    expect(controller.messages.last.text, 'local fixture');
    expect(notifications, 2);
    await send;
    await tester.pump(const Duration(milliseconds: 60));
    expect(controller.messages.length, 101);
    controller.dispose();
  });

  test(
      'acknowledged server ID retains transaction index without stale local retry',
      () async {
    final adapter = FakeTimelineAdapter();
    final controller = RoomTimelineController(adapter);
    await controller.sendText('fixture');
    final tx = controller.messages.single.stableId;
    adapter.items.add(RoomMessageViewModel(
        id: 'event-1',
        senderId: 'me',
        text: 'fixture',
        isOwn: true,
        deliveryState: RoomDeliveryState.sent,
        timestamp: DateTime.utc(2026)));
    await controller.refresh();
    expect(controller.messages.single.stableId, tx);
    expect(controller.indexOf('event-1'), 0);
    expect(controller.indexOf(tx), 0);
    await controller.retry('event-1');
    expect(controller.messages, hasLength(1));
    controller.dispose();
  });

  test(
      'stable index and row identity survive append update history and removal',
      () async {
    final adapter = FakeTimelineAdapter();
    RoomMessageViewModel item(String id, {bool recalled = false}) =>
        RoomMessageViewModel(
            id: id,
            senderId: 'peer',
            text: recalled ? '' : id,
            isOwn: false,
            deliveryState: RoomDeliveryState.sent,
            timestamp: DateTime.utc(2026),
            isRecalled: recalled);
    adapter.items.addAll([item('a'), item('b')]);
    final controller = RoomTimelineController(adapter);
    final first = controller.messages.first;
    adapter.items.add(item('c'));
    await controller.refresh();
    expect(controller.indexOf('c'), 2);
    expect(identical(controller.messages.first, first), isTrue);
    adapter.items[1] = item('b', recalled: true);
    await controller.refresh();
    expect(controller.messages[controller.indexOf('b')!].isRecalled, isTrue);
    expect(identical(controller.messages.first, first), isTrue);
    adapter.items.insert(0, item('history'));
    await controller.refresh();
    expect(controller.indexOf('a'), 1);
    expect(identical(controller.messages[1], first), isTrue);
    adapter.items.removeAt(1);
    await controller.refresh();
    expect(controller.indexOf('a'), isNull);
    expect(controller.indexOf('b'), 1);
    controller.dispose();
  });

  test('unchanged refresh retains list and models without notifying', () async {
    final adapter = FakeTimelineAdapter();
    adapter.items.add(RoomMessageViewModel(
        id: 'a',
        senderId: 'peer',
        text: 'a',
        isOwn: false,
        deliveryState: RoomDeliveryState.sent,
        timestamp: DateTime.utc(2026)));
    final controller = RoomTimelineController(adapter);
    final before = controller.messages;
    var notifications = 0;
    controller.addListener(() => notifications++);
    adapter.items[0] = adapter.items[0].copyWith();
    await controller.refresh();
    expect(notifications, 0);
    expect(identical(controller.messages, before), isTrue);
    controller.dispose();
  });

  test('refresh preserves SDK order across nonmonotonic timestamps', () async {
    final adapter = FakeTimelineAdapter();
    for (final i in [2, 1, 3]) {
      adapter.items.add(RoomMessageViewModel(
          id: '$i',
          senderId: 'peer',
          text: '$i',
          isOwn: false,
          deliveryState: RoomDeliveryState.sent,
          timestamp: DateTime.utc(2026).add(Duration(seconds: i))));
    }
    final controller = RoomTimelineController(adapter);
    await controller.refresh();
    expect(controller.messages.map((m) => m.id), ['2', '1', '3']);
    controller.dispose();
  });

  test('retry respects current permission and deduplicates concurrent taps',
      () async {
    final adapter = FakeTimelineAdapter();
    adapter.items.add(RoomMessageViewModel(
        id: 'failed',
        senderId: 'me',
        text: 'fixture',
        isOwn: true,
        deliveryState: RoomDeliveryState.failed,
        timestamp: DateTime.utc(2026, 9, 6)));
    var allowed = false;
    final controller =
        RoomTimelineController(adapter, canSendNow: () => allowed);
    await controller.retry('failed');
    expect(adapter.retryCalls, 0);
    allowed = true;
    adapter.retryPending = Completer<void>();
    final first = controller.retry('failed');
    final second = controller.retry('failed');
    expect(adapter.retryCalls, 1);
    adapter.retryPending!.complete();
    await Future.wait([first, second]);
    controller.dispose();
  });

  test('controller owns delivery state, read marker and adapter disposal',
      () async {
    final adapter = FakeTimelineAdapter();
    final controller = RoomTimelineController(adapter);
    await controller.sendText('你好');
    expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
    await controller.markRead();
    expect(adapter.marks, 1);
    await controller.sendRedPacketReference('packet-1', '恭喜发财');
    expect(adapter.redPackets, ['packet-1:恭喜发财']);
    await controller.sendTransferReference('transfer-1', '20.00', '午饭');
    expect(adapter.transfers, ['transfer-1:20.00:午饭']);
    // 收款/指定对象账号标识随引用消息进入房间（供第三方本机解析展示名）。
    await controller.sendRedPacketReference('packet-2', '恭喜发财',
        mode: 'EXCLUSIVE',
        recipientId: 'business-2',
        recipientMatrixId: '@bob:test');
    await controller.sendTransferReference('transfer-2', '8.88', null,
        receiverId: 'business-9', receiverMatrixId: '@carol:test');
    expect(adapter.redPacketTargets, ['||', 'EXCLUSIVE|business-2|@bob:test']);
    expect(adapter.transferTargets, ['|', 'business-9|@carol:test']);
    controller.dispose();
    expect(adapter.disposed, 1);
  });

  test('time separators appear at the first message and after five minutes',
      () {
    final first = DateTime(2026, 8, 17, 9);
    expect(shouldShowMessageTimeSeparator(null, first), isTrue);
    expect(
      shouldShowMessageTimeSeparator(
        first,
        first.add(const Duration(minutes: 4, seconds: 59)),
      ),
      isFalse,
    );
    expect(
      shouldShowMessageTimeSeparator(
        first,
        first.add(const Duration(minutes: 5)),
      ),
      isTrue,
    );
  });

  test('message copy keeps attachment mime type for GIF action policy', () {
    final message = RoomMessageViewModel(
      id: r'$gif',
      senderId: '@alice:example.test',
      text: 'wave.gif',
      isOwn: true,
      deliveryState: RoomDeliveryState.sending,
      timestamp: DateTime.utc(2026, 8, 17),
      kind: RoomMessageKind.image,
      mimeType: 'image/gif',
    );

    final sent = message.copyWith(deliveryState: RoomDeliveryState.sent);

    expect(sent.mimeType, 'image/gif');
  });

  test('message copy retains selected reply excerpt through acknowledgement',
      () {
    final localEcho = RoomMessageViewModel(
      id: 'local-quote',
      senderId: 'me',
      text: '回复正文',
      isOwn: true,
      deliveryState: RoomDeliveryState.sending,
      timestamp: DateTime.utc(2026, 9, 12),
      replyToEventId: r'$source',
      replyExcerpt: '🥲中文[微笑]',
    );

    final acknowledged = localEcho.copyWith(
      id: r'$server',
      deliveryState: RoomDeliveryState.sent,
    );

    expect(acknowledged.replyToEventId, r'$source');
    expect(acknowledged.replyExcerpt, '🥲中文[微笑]');
  });

  test('failed send retries in place without duplicating the message',
      () async {
    final adapter = FakeTimelineAdapter();
    adapter.sendFailure = StateError('network down');
    final controller = RoomTimelineController(adapter);

    await controller.sendText('你好');
    expect(
      controller.messages.where((m) => m.text == '你好').length,
      1,
      reason: '失败只标记一次，不产生副本',
    );
    expect(controller.messages.single.deliveryState, RoomDeliveryState.failed);

    adapter.sendFailure = null;
    // 真实 SDK：sendAgain 复用同一事件，重发成功后时间线中出现已发送事件。
    adapter.items.add(controller.messages.single.copyWith(
      deliveryState: RoomDeliveryState.sent,
    ));
    await controller.retry(controller.messages.single.id);

    expect(adapter.retryCalls, 1);
    expect(
      controller.messages.where((m) => m.text == '你好').length,
      1,
      reason: '重发复用同一事件，不插入新消息',
    );
  });

  test('loadHistory reports loading and exhaustion for top-of-list UI',
      () async {
    final adapter = FakeTimelineAdapter();
    // 初始只有一条最新消息。
    adapter.items.add(RoomMessageViewModel(
      id: 'm-1',
      senderId: 'peer',
      text: '最新',
      isOwn: false,
      deliveryState: RoomDeliveryState.sent,
      timestamp: DateTime.utc(2026, 8, 2),
    ));
    final controller = RoomTimelineController(adapter);

    expect(controller.historyLoading, isFalse);
    expect(controller.historyExhausted, isFalse);

    await controller.loadHistory();
    expect(controller.historyLoading, isFalse, reason: '加载完成后停用 loading 图标');
    expect(controller.historyExhausted, isFalse);
    expect(controller.messages.length, 2);
    expect(adapter.historyCalls, 1);

    // 已无更多历史：加载后消息数不增长 → exhausted，重复调用为空操作。
    adapter.historyPages = 0;
    await controller.loadHistory();
    expect(controller.historyExhausted, isTrue, reason: '顶部显示“没有更多了”');
    expect(controller.messages.length, 2);
    await controller.loadHistory();
    expect(adapter.historyCalls, 2, reason: '耗尽后不再发起加载');
  });

  test('returning to latest invalidates an older history request owner',
      () async {
    final adapter = DeferredHistoryTimelineAdapter();
    final controller = RoomTimelineController(adapter, windowed: true);

    final older = controller.loadHistory();
    expect(controller.historyLoading, isTrue);

    await controller.showLatest();
    expect(controller.historyLoading, isFalse,
        reason: '回到实时流必须解除旧 context 的 loading 状态');
    expect(adapter.latestCalls, 1);

    final newer = controller.loadHistory();
    expect(adapter.historyRequests, hasLength(2),
        reason: '旧请求不能阻止新 context 发起历史请求');
    adapter.historyRequests[0].complete();
    await older;
    expect(controller.historyLoading, isTrue,
        reason: '旧 finally 不得清除新请求的 loading 状态');
    adapter.historyRequests[1].complete();
    await newer;
    expect(controller.historyLoading, isFalse);
    controller.dispose();
  });

  test('selectLatest restores live state through one adapter entry point',
      () async {
    final adapter = DeferredHistoryTimelineAdapter();
    final controller = RoomTimelineController(adapter, windowed: true);

    await controller.selectLatest();

    expect(adapter.latestCalls, 1,
        reason: 'date capability and viewport must not each restore live');
    controller.dispose();
  });

  test('date context state publishes when the visible rows are unchanged',
      () async {
    final adapter = DeferredHistoryTimelineAdapter()
      ..viewingHistory = false
      ..dateLocation = RoomHistoryDayLocation(
        eventId: r'$context',
        day: DateTime(2026, 9, 13),
      );
    final controller = RoomTimelineController(adapter, windowed: true);
    var publications = 0;
    controller.addListener(() => publications++);

    await controller.locateDay(DateTime(2026, 9, 13));
    expect(controller.isViewingHistoryContext, isTrue);
    expect(publications, 1,
        reason: 'latest/context controls need a rebuild even with equal rows');

    await controller.showLatest();
    expect(controller.isViewingHistoryContext, isFalse);
    expect(publications, 2);
    controller.dispose();
  });

  test('sending from history restores live state and cancels stale loading',
      () async {
    final adapter = DeferredHistoryTimelineAdapter();
    final controller = RoomTimelineController(adapter, windowed: true);
    final older = controller.loadHistory();

    await controller.sendText('return to live');

    expect(adapter.latestCalls, 1);
    expect(controller.historyLoading, isFalse);
    adapter.historyRequests.single.complete();
    await older;
    controller.dispose();
  });
}
