import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/network_state_manager.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

/// 记录每次派发使用的 txid 的假传输层（应答脚本由测试注入）。
final class _FakeTransport
    implements RoomTimelineAdapter, RoomOptimisticTextAdapter {
  final events = <RoomMessageViewModel>[];
  final txids = <String>[];
  final responses = <Future<String> Function()>[];

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
  void dispose() {}
}

Future<String> _networkDown() =>
    Future<String>.error(const SocketException('offline'));

void main() {
  late NetworkStateManager manager;
  late PersistentOutboxManager outbox;

  setUp(() {
    manager = NetworkStateManager();
    outbox = PersistentOutboxManager(InMemoryOutboxStore(), accountId: 'me');
  });

  tearDown(() {
    manager.dispose();
    outbox.dispose();
  });

  RoomTimelineController controllerFor(_FakeTransport transport) =>
      RoomTimelineController(transport,
          networkStateManager: manager,
          outboxJournal: outbox.journalFor(
              roomId: '!room:test', receiverId: '@peer:test'));

  group('会话内发送：先落盘再派发', () {
    test('发送中的消息已持久化（status=sending），送达后从 outbox 移除', () async {
      final inFlight = Completer<String>();
      final transport = _FakeTransport()..responses.add(() => inFlight.future);
      final controller = controllerFor(transport);

      final send = controller.sendText('hello');
      await pumpEventQueue();

      final pending = await outbox.unsent();
      expect(pending, hasLength(1), reason: '派发之前消息必须已经落盘');
      expect(pending.single.content, 'hello');
      expect(pending.single.roomId, '!room:test');
      expect(pending.single.receiverId, '@peer:test');
      expect(pending.single.status, OutboxStatus.sending);
      expect(pending.single.txid, controller.messages.single.stableId,
          reason: 'outbox 行与时间线乐观行共用同一个 txid');
      expect(transport.txids, <String>[pending.single.txid]);

      inFlight.complete(r'$server');
      await send;
      await pumpEventQueue();

      expect(await outbox.unsent(), isEmpty, reason: '确认送达后不保留正文副本');
      controller.dispose();
    });

    test('离线发送 → outbox 行是 waitingNetwork（不是 failed）且 txid 不变', () async {
      final transport = _FakeTransport()..responses.add(_networkDown);
      final controller = controllerFor(transport);

      await controller.sendText('hello');

      expect(controller.messages.single.deliveryState,
          RoomDeliveryState.waitingNetwork);
      final pending = await outbox.unsent();
      expect(pending.single.status, OutboxStatus.waitingNetwork);
      expect(pending.single.status, isNot(OutboxStatus.failed),
          reason: '网络问题永远不是终局失败');
      expect(pending.single.txid, controller.messages.single.stableId);
      controller.dispose();
    });

    test('服务端拒绝 → outbox 行是 failed，并保留失败原因', () async {
      final transport = _FakeTransport()
        ..responses.add(() => Future<String>.error(StateError('M_FORBIDDEN')));
      final controller = controllerFor(transport);

      await controller.sendText('被拒绝');

      final pending = await outbox.unsent();
      expect(pending.single.status, OutboxStatus.failed);
      expect(pending.single.lastError, contains('M_FORBIDDEN'));
      controller.dispose();
    });

    test('网络恢复自动重发：同一 txid、outbox 里始终只有一行', () async {
      final transport = _FakeTransport()
        ..responses.add(_networkDown)
        ..responses.add(() => Future<String>.value(r'$server'));
      final controller = controllerFor(transport);

      await controller.sendText('hello');
      final row = (await outbox.unsent()).single;

      manager.reportSuccess();
      await pumpEventQueue();

      expect(transport.txids, <String>[row.txid, row.txid],
          reason: '自动重发必须复用同一 txid（幂等键）');
      expect(await outbox.unsent(), isEmpty);
      expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
      controller.dispose();
    });

    test('手动重试复用同一 txid，且不会新增 outbox 行', () async {
      final transport = _FakeTransport()
        ..responses.add(() => Future<String>.error(StateError('M_FORBIDDEN')))
        ..responses.add(() => Future<String>.value(r'$ok'));
      final controller = controllerFor(transport);

      await controller.sendText('重试我');
      final row = (await outbox.unsent()).single;
      final local = controller.messages.single;
      expect(local.deliveryState, RoomDeliveryState.failed);

      await controller.retry(local.stableId);

      expect(transport.txids, <String>[row.txid, row.txid]);
      expect(await outbox.unsent(), isEmpty);
      expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
      controller.dispose();
    });

    test('互动门禁拒绝（canSendNow=false）→ 不触达传输层，但原文仍落盘为 failed', () async {
      final transport = _FakeTransport();
      final controller = RoomTimelineController(transport,
          canSendNow: () => false,
          networkStateManager: manager,
          outboxJournal: outbox.journalFor(
              roomId: '!room:test', receiverId: '@peer:test'));

      await controller.sendText('非好友');

      expect(transport.txids, isEmpty, reason: '门禁拒绝不触达传输层');
      expect(
          controller.messages.single.deliveryState, RoomDeliveryState.failed);
      final pending = await outbox.unsent();
      expect(pending.single.status, OutboxStatus.failed,
          reason: '被本地门禁拒绝的原文也要留住，重进会话仍可见并可重试');
      expect(pending.single.content, '非好友');
      controller.dispose();
    });

    test('媒体消息（图片/语音等）不进 outbox：带外载荷无法用正文重放', () async {
      final transport = _FakeTransport();
      final controller = controllerFor(transport);

      await controller.sendText('[图片消息]', kind: RoomMessageKind.image);

      expect(await outbox.unsent(), isEmpty);
      expect(transport.txids, hasLength(1));
      controller.dispose();
    });
  });

  group('重启恢复：把上一条进程留下的行放回时间线', () {
    test('新控制器用行内 txid 发送上一次进程留下的未送达行（只发一次）', () async {
      // 上一次进程：用户离线发送，行留在 outbox（roomId 已绑定）。
      final leftover = await outbox.save(
          receiverId: '@peer:test',
          content: '上次没发出去',
          roomId: '!room:test',
          status: OutboxStatus.waitingNetwork);
      final transport = _FakeTransport()
        ..responses.add(() => Future<String>.value(r'$server'));
      final controller = controllerFor(transport);

      await controller.sendText(leftover!.content, outboxRow: leftover);

      expect(transport.txids, <String>[leftover.txid],
          reason: '恢复必须复用持久化的 txid，服务端幂等去重');
      expect(controller.messages.single.stableId, leftover.txid);
      expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
      expect(await outbox.unsent(), isEmpty);
      controller.dispose();
    });

    test('重复派发保护：同一 outbox 行两次发送尝试 → 只发一次', () async {
      final row = await outbox.save(
          receiverId: '@peer:test',
          content: '只发一次',
          roomId: '!room:test',
          status: OutboxStatus.waitingNetwork);
      final inFlight = Completer<String>();
      final transport = _FakeTransport()..responses.add(() => inFlight.future);
      final controller = controllerFor(transport);

      final first = controller.sendText(row!.content, outboxRow: row);
      await pumpEventQueue();
      // 第二次尝试（例如恢复流程与用户点击同时命中同一行）。
      await controller.sendText(row.content, outboxRow: row);
      await pumpEventQueue();

      expect(transport.txids, <String>[row.txid], reason: '两次尝试只允许一次真正的服务端发送');
      expect(controller.messages, hasLength(1), reason: '时间线也不能出现两条');

      inFlight.complete(r'$server');
      await first;
      await pumpEventQueue();
      expect(transport.txids, <String>[row.txid]);
      expect(await outbox.unsent(), isEmpty);
      controller.dispose();
    });

    test('failed 行只能手动重试：restoreOutboxMessage 只恢复展示，不派发', () async {
      final row = await outbox.save(
          receiverId: '@peer:test',
          content: '被拒绝过',
          roomId: '!room:test',
          status: OutboxStatus.failed);
      final transport = _FakeTransport();
      final controller = controllerFor(transport);

      controller.restoreOutboxMessage(row!);
      await pumpEventQueue();

      expect(transport.txids, isEmpty, reason: 'failed 绝不自动重发');
      expect(
          controller.messages.single.deliveryState, RoomDeliveryState.failed);
      expect(controller.messages.single.stableId, row.txid);
      controller.dispose();
    });
  });

  group('pending 原文与持久化行的抵扣', () {
    OutboxMessage row(String content) => OutboxMessage(
          localId: 'local-$content',
          txid: 'tx-$content',
          receiverId: '@peer:test',
          content: content,
          createdAt: DateTime(2026, 9, 18),
          updatedAt: DateTime(2026, 9, 18),
        );

    test('已落盘的原文不会被再次新建发送；重复内容逐个抵扣', () {
      final orphaned = textsWithoutOutboxRows(
        texts: <String>['你好', '你好', '只落盘了一条'],
        rows: <OutboxMessage>[row('你好'), row('只落盘了一条')],
      );

      expect(orphaned, <String>['你好'], reason: '两条"你好"抵扣一条落盘行，另一条走兜底；其余不重复发送');
    });

    test('没有落盘行时全部走兜底（降级路径），空文本被忽略', () {
      expect(
        textsWithoutOutboxRows(
            texts: <String>['a', '  ', 'b'], rows: const <OutboxMessage>[]),
        <String>['a', 'b'],
      );
    });
  });
  test(
      'historical outbox remains visible but never reroutes its transaction to primary',
      () async {
    final transport = _FakeTransport();
    final controller =
        RoomTimelineController(transport, outboxRoomId: '!primary:test');
    final row = OutboxMessage(
        localId: 'old-local',
        txid: 'old-tx',
        receiverId: '@peer:test',
        content: 'old pending',
        roomId: '!old:test',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026));
    await controller.sendText(row.content, outboxRow: row);
    expect(controller.messages.single.text, 'old pending');
    expect(controller.messages.single.deliveryState, RoomDeliveryState.failed);
    await controller.retry(row.txid);
    expect(transport.txids, isEmpty);
    controller.dispose();
  });
}
