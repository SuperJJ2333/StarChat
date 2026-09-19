import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/network_state_manager.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';

/// 可编程传输：按 [responses] 顺序回答每次派发，并记录每次使用的 txid。
///
/// 只被 `RoomTimelineController` 的乐观发送路径使用（[sendTextWithTransaction]），
/// 因此测试可以精确断言「重发是否复用同一个 txid」。
final class _FakeTransport
    implements RoomTimelineAdapter, RoomOptimisticTextAdapter {
  final events = <RoomMessageViewModel>[];
  final txids = <String>[];
  final responses = <Future<String> Function()>[];
  int adapterRetries = 0;
  int disposed = 0;

  @override
  Future<String> sendTextWithTransaction(String text, String transactionId) {
    txids.add(transactionId);
    if (responses.isEmpty) return Future<String>.value('event-${txids.length}');
    return responses.removeAt(0)();
  }

  @override
  Future<String> sendText(String text) async => 'event-text';

  @override
  Future<void> retry(String transactionId) async {
    adapterRetries++;
    txids.add(transactionId);
    if (responses.isNotEmpty) await responses.removeAt(0)();
  }

  @override
  List<RoomMessageViewModel> snapshot() => List.of(events);

  @override
  Future<Uint8List> loadAttachment(String eventId) async => Uint8List(0);

  @override
  Future<Uint8List?> loadThumbnail(String eventId) async => null;

  @override
  Future<void> loadHistory() async {}

  @override
  Future<void> markRead() async {}

  @override
  Future<String> sendRedPacketReference(String packetId, String greeting,
          {String? mode,
          String? recipientId,
          String? recipientMatrixId}) async =>
      'event-red-packet';

  @override
  Future<String> sendTransferReference(
          String transferId, String amount, String? note,
          {String? receiverId, String? receiverMatrixId}) async =>
      'event-transfer';

  @override
  void dispose() => disposed++;
}

Future<String> _networkDown() =>
    Future<String>.error(const SocketException('offline'));

class _HeldSettlement implements OutboxJournal {
  _HeldSettlement(this.inner);
  final OutboxJournal inner;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool held = false;
  @override
  Future<OutboxMessage?> findByTxid(String txid) => inner.findByTxid(txid);
  @override
  Future<OutboxMessage?> persist(
          {required String txid,
          required String content,
          OutboxStatus status = OutboxStatus.queued,
          String? localId}) =>
      inner.persist(
          txid: txid, content: content, status: status, localId: localId);
  @override
  Future<bool> claim(String localId, {Set<OutboxStatus>? from}) =>
      inner.claim(localId, from: from);
  @override
  Future<void> complete(String localId) => inner.complete(localId);
  @override
  Future<void> settle(String localId, OutboxStatus status,
      {String? lastError}) async {
    if (status == OutboxStatus.waitingNetwork && !held) {
      held = true;
      entered.complete();
      await release.future;
    }
    await inner.settle(localId, status, lastError: lastError);
  }
}

void main() {
  late NetworkStateManager manager;

  setUp(() => manager = NetworkStateManager());
  tearDown(() => manager.dispose());

  group('离线优先发送状态机', () {
    test('declined claim reflects durable failure and later background outcome',
        () async {
      final outbox =
          PersistentOutboxManager(InMemoryOutboxStore(), accountId: 'me');
      final journal = RoomOutboxJournal(
          manager: outbox,
          roomId: null,
          receiverId: '@peer:test',
          beforeClaim: (id) async {
            await outbox.bindRoom(id, '!canonical:test');
            await outbox.updateStatus(id, OutboxStatus.failed);
            return false;
          });
      final transport = _FakeTransport();
      final controller = RoomTimelineController(transport,
          outboxJournal: journal, outboxRoomId: '!old:test');
      await controller.sendText('keep outcome');
      expect(transport.txids, isEmpty);
      expect(
          controller.messages.single.deliveryState, RoomDeliveryState.failed);
      final row = (await outbox.unsent()).single;
      await outbox.updateStatus(row.localId, OutboxStatus.sent);
      await controller.reconcileOutboxStatuses();
      expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
      await controller.retry(row.txid);
      expect(transport.txids, isEmpty);
      controller.dispose();
      outbox.dispose();
    });
    test('recovery during durable failure settlement waits for claim release',
        () async {
      final outbox =
          PersistentOutboxManager(InMemoryOutboxStore(), accountId: 'me');
      final journal = _HeldSettlement(
          outbox.journalFor(roomId: '!r:test', receiverId: '@peer:test'));
      final transport = _FakeTransport()..responses.add(_networkDown);
      final controller = RoomTimelineController(transport,
          networkStateManager: manager, outboxJournal: journal);
      final sending = controller.sendText('recover');
      await journal.entered.future;
      manager.reportSuccess();
      await Future<void>.delayed(Duration.zero);
      expect(transport.txids, hasLength(1));
      journal.release.complete();
      await sending;
      await Future<void>.delayed(Duration.zero);
      expect(transport.txids, hasLength(2));
      expect(transport.txids.toSet(), hasLength(1));
      expect(await outbox.unsent(), isEmpty);
      controller.dispose();
      outbox.dispose();
    });

    test(
        'recovery while retry is pending is consumed once without failure storm',
        () async {
      final pending = Completer<String>();
      final transport = _FakeTransport()
        ..responses.addAll([_networkDown, () => pending.future, _networkDown]);
      final controller =
          RoomTimelineController(transport, networkStateManager: manager);
      await controller.sendText('recover');
      manager.reportSuccess();
      await Future<void>.delayed(Duration.zero);
      manager.report(transportAvailable: false);
      manager.reportSuccess();
      pending.completeError(const SocketException('stale request'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(transport.txids, hasLength(3));
      await Future<void>.delayed(Duration.zero);
      expect(transport.txids, hasLength(3));
      controller.dispose();
    });

    test('网络失败 → waitingNetwork（不是红色失败），并上报网络状态机', () async {
      final transport = _FakeTransport()..responses.add(_networkDown);
      final controller =
          RoomTimelineController(transport, networkStateManager: manager);

      await controller.sendText('你好');

      expect(controller.messages.single.deliveryState,
          RoomDeliveryState.waitingNetwork);
      expect(controller.messages.single.deliveryState,
          isNot(RoomDeliveryState.failed));
      expect(manager.current, NetworkState.weak,
          reason: '网络失败必须上报给网络状态机，供恢复判定使用');
      controller.dispose();
    });

    test('服务端拒绝（非网络错误）仍是 failed，且不降级网络状态', () async {
      final transport = _FakeTransport()
        ..responses.add(() => Future<String>.error(StateError('M_FORBIDDEN')));
      final controller =
          RoomTimelineController(transport, networkStateManager: manager);

      await controller.sendText('被拒绝');

      expect(
          controller.messages.single.deliveryState, RoomDeliveryState.failed);
      expect(controller.messages.single.deliveryState,
          isNot(RoomDeliveryState.waitingNetwork));
      expect(manager.current, NetworkState.online,
          reason: '服务端拒绝不是网络失败，不得改变网络状态');
      controller.dispose();
    });

    test('互动门禁（canSendNow 为 false）仍是 failed 且不触达传输层', () async {
      final transport = _FakeTransport();
      final controller = RoomTimelineController(transport,
          canSendNow: () => false, networkStateManager: manager);

      await controller.sendText('非好友');

      expect(
          controller.messages.single.deliveryState, RoomDeliveryState.failed);
      expect(transport.txids, isEmpty);
      controller.dispose();
    });

    test('乐观行在派发一开始就从 local 翻成 sending', () async {
      final pending = Completer<String>();
      final transport = _FakeTransport()..responses.add(() => pending.future);
      final controller =
          RoomTimelineController(transport, networkStateManager: manager);

      final send = controller.sendText('你好');

      expect(
          controller.messages.single.deliveryState, RoomDeliveryState.sending);
      expect(controller.messages.single.deliveryState,
          isNot(RoomDeliveryState.local));

      pending.complete(r'$ok');
      await send;
      expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
      controller.dispose();
    });
  });

  group('离线快速失败与悬挂护栏（2026-09-19 房间瘫痪修复）', () {
    test('网络状态机判定离线时，发送不进入传输层，立即转 waitingNetwork', () async {
      manager.report(transportAvailable: false);
      expect(manager.current, NetworkState.offline);

      final transport = _FakeTransport()
        ..responses.add(() => Future<String>.value(r'$server'));
      final controller =
          RoomTimelineController(transport, networkStateManager: manager);

      await controller.sendText('离线发送');

      final local = controller.messages.single;
      expect(local.deliveryState, RoomDeliveryState.waitingNetwork,
          reason: '离线时不许空等传输层超时，必须立刻进入可自动重发的等待态');
      expect(transport.txids, isEmpty, reason: '传输层不该被调用（弱网黑洞下 SDK 队列会卡死整个房间）');

      manager.report(transportAvailable: true, serverReachable: true);
      await pumpEventQueue();

      expect(transport.txids, [local.stableId], reason: '恢复后自动重发，复用同一 txid');
      expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
      controller.dispose();
    });

    test('传输层悬挂时护栏超时把行转入 waitingNetwork，不再阻塞后续消息', () async {
      final hanging = Completer<String>();
      final transport = _FakeTransport()
        ..responses.add(() => hanging.future)
        ..responses.add(() => Future<String>.value(r'$second'));
      final controller = RoomTimelineController(transport,
          networkStateManager: manager,
          sendDispatchTimeout: const Duration(milliseconds: 60));

      await controller.sendText('会悬挂的消息');
      expect(controller.messages.first.deliveryState,
          RoomDeliveryState.waitingNetwork,
          reason: '悬挂的发送必须在护栏超时后可见（waitingNetwork 自动重发），'
              '而不是永远停在 sending 让房间瘫痪');

      final second = await controller.sendText('第二条消息');
      expect(second, isNotNull, reason: '第一条悬挂后，后续消息必须仍能正常派发');
      expect(controller.messages.last.deliveryState, RoomDeliveryState.sent);
      expect(transport.txids.length, 2);

      // 第一条的底层 future 之后仍挂着（模拟 SDK 队列滞留），其失败不得成为
      // 未处理异常；行保持在 waitingNetwork 等待恢复。
      hanging.completeError(const SocketException('late failure'));
      await pumpEventQueue();
      expect(controller.messages.first.deliveryState,
          RoomDeliveryState.waitingNetwork);
      controller.dispose();
    });
  });

  group('网络恢复自动重发', () {
    test('report(transportAvailable/serverReachable) 恢复 → 同一 txid 自动重发并 sent',
        () async {
      final transport = _FakeTransport()
        ..responses.add(_networkDown)
        ..responses.add(() => Future<String>.value(r'$server'));
      final controller =
          RoomTimelineController(transport, networkStateManager: manager);

      await controller.sendText('你好');
      final local = controller.messages.single;
      expect(local.deliveryState, RoomDeliveryState.waitingNetwork);
      expect(transport.txids, [local.stableId]);

      manager.report(transportAvailable: true, serverReachable: true);
      await pumpEventQueue();

      expect(transport.txids, [local.stableId, local.stableId],
          reason: '自动重发必须复用同一个 txid');
      expect(controller.messages.single.stableId, local.stableId);
      expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
      controller.dispose();
    });

    test('reportSuccess 恢复 → 同样自动重发并 sent', () async {
      final transport = _FakeTransport()
        ..responses.add(_networkDown)
        ..responses.add(() => Future<String>.value(r'$server'));
      final controller =
          RoomTimelineController(transport, networkStateManager: manager);

      await controller.sendText('你好');
      expect(controller.messages.single.deliveryState,
          RoomDeliveryState.waitingNetwork);

      manager.reportSuccess();
      await pumpEventQueue();

      expect(transport.txids, hasLength(2));
      expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
      controller.dispose();
    });

    test('恢复通知重复触发时不会二次派发', () async {
      final second = Completer<String>();
      final transport = _FakeTransport()
        ..responses.add(_networkDown)
        ..responses.add(() => second.future);
      final controller =
          RoomTimelineController(transport, networkStateManager: manager);

      await controller.sendText('你好');

      manager.report(recovering: true);
      await pumpEventQueue();
      expect(transport.txids, hasLength(2), reason: '恢复后立刻重发一次');
      expect(
          controller.messages.single.deliveryState, RoomDeliveryState.sending);

      // 重发仍在途时反复触发恢复信号（含转入 recovering 再进入 online）。
      manager.report(transportAvailable: true, serverReachable: true);
      manager.reportSuccess();
      manager.report(recovering: true);
      manager.report(transportAvailable: true, serverReachable: true);
      await pumpEventQueue();

      expect(transport.txids, hasLength(2), reason: '在途重发不得被二次派发');
      expect(
          controller.messages.single.deliveryState, RoomDeliveryState.sending);

      second.complete(r'$server');
      await pumpEventQueue();
      expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
      expect(transport.txids, hasLength(2));
      controller.dispose();
    });

    test('dispose 后恢复通知不再派发', () async {
      final transport = _FakeTransport()..responses.add(_networkDown);
      final controller =
          RoomTimelineController(transport, networkStateManager: manager);

      await controller.sendText('你好');
      controller.dispose();

      manager.report(transportAvailable: true, serverReachable: true);
      await pumpEventQueue();

      expect(transport.txids, hasLength(1));
    });
  });

  group('手动重试', () {
    test('failed 行手动重试仍然可用', () async {
      final transport = _FakeTransport()
        ..responses.add(() => Future<String>.error(StateError('M_FORBIDDEN')))
        ..responses.add(() => Future<String>.value(r'$ok'));
      final controller =
          RoomTimelineController(transport, networkStateManager: manager);

      await controller.sendText('重试我');
      final local = controller.messages.single;
      expect(local.deliveryState, RoomDeliveryState.failed);

      await controller.retry(local.stableId);

      expect(transport.txids, [local.stableId, local.stableId]);
      expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
      controller.dispose();
    });

    test('waitingNetwork 行可点击立即重试（不等网络状态机）', () async {
      final transport = _FakeTransport()
        ..responses.add(_networkDown)
        ..responses.add(() => Future<String>.value(r'$ok'));
      final controller =
          RoomTimelineController(transport, networkStateManager: manager);

      await controller.sendText('等待中');
      final local = controller.messages.single;
      expect(local.deliveryState, RoomDeliveryState.waitingNetwork);

      await controller.retry(local.stableId);

      expect(transport.txids, [local.stableId, local.stableId]);
      expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
      controller.dispose();
    });
  });

  group('气泡外观', () {
    Future<void> pumpBubble(
      WidgetTester tester,
      MessageDeliveryState state,
      VoidCallback onRetry,
    ) async {
      await tester.pumpWidget(CupertinoApp(
        home: CupertinoPageScaffold(
          child: Center(
            child: WeChatMessageBubble(
              direction: MessageDirection.outgoing,
              content: const Text('你好'),
              state: state,
              onRetry: onRetry,
            ),
          ),
        ),
      ));
    }

    testWidgets(
        'waitingNetwork 显示红色感叹号且可点击重发（2026-09-19 用户修订：'
        '弱网/断网未发出的消息必须及时给出红色感叹号警告）', (tester) async {
      var retries = 0;
      await pumpBubble(
          tester, MessageDeliveryState.waitingNetwork, () => retries++);

      // 状态词表（UI_DESIGN.md §7 消息，2026-09-19 修订）：网络原因未发出的
      // waitingNetwork 与终局 failed 在视觉上一致（红色感叹号 + 点击重发），
      // 区别只在行为：waitingNetwork 会在网络恢复后自动重发。
      expect(find.byKey(const Key('message-delivery-waiting')), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.exclamationmark_circle_fill),
          findsOneWidget);
      expect(find.byIcon(CupertinoIcons.clock), findsNothing);
      expect(find.text('等待网络'), findsNothing,
          reason: '不再渲染「等待网络」文字，红色感叹号本身就是警告');

      await tester.tap(find.byKey(const Key('message-delivery-waiting')));
      await tester.pump();
      expect(retries, 1, reason: 'waitingNetwork 的气泡点击即立即重发');
    });

    testWidgets('failed 仍是红色感叹号且可重试', (tester) async {
      var retries = 0;
      await pumpBubble(tester, MessageDeliveryState.failed, () => retries++);

      expect(find.byIcon(CupertinoIcons.exclamationmark_circle_fill),
          findsOneWidget);
      expect(find.text('等待发送'), findsNothing);
      expect(find.text('等待网络'), findsNothing);
      expect(find.byIcon(CupertinoIcons.clock), findsNothing);

      await tester.tap(find.byKey(const Key('message-delivery-failed')));
      await tester.pump();
      expect(retries, 1);
    });
  });
}
