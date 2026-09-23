import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/network_state_manager.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/core/outbox/message_send_scheduler.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_room_sender_registry.dart';
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

class _WriteFailureStore implements OutboxStore {
  final inner = InMemoryOutboxStore();
  bool fail = false;
  int failedWrites = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (fail && invocation.memberName == #updateStatus) {
      failedWrites++;
      return Future<bool>.error(StateError('storage unavailable'));
    }
    final target = switch (invocation.memberName) {
      #insert => inner.insert,
      #byLocalId => inner.byLocalId,
      #byTxid => inner.byTxid,
      #updateStatus => inner.updateStatus,
      #query => inner.query,
      #delete => inner.delete,
      _ => null,
    };
    if (target != null) {
      return Function.apply(
          target, invocation.positionalArguments, invocation.namedArguments);
    }
    return super.noSuchMethod(invocation);
  }
}

class _TransportLease implements OutboxLease {
  _TransportLease(this.transport);
  final _FakeTransport transport;
  @override
  Future<String> send(String text, String txid) =>
      transport.sendTextWithTransaction(text, txid);
  @override
  Future<void> release() async {}
}

class _ControllerSender implements OutboxSender {
  _ControllerSender(this.controller);
  final RoomTimelineController controller;
  @override
  String get roomId => '!room:test';
  @override
  bool get canSend => true;
  @override
  Future<String> send(OutboxMessage row) async {
    final result = await controller.sendText(row.content, outboxRow: row);
    if (result == null) throw StateError('send not accepted');
    return result;
  }
}

class _ServerUnavailable implements Exception {
  int get statusCode => 503;
  int get retryAfterSeconds => 5;
}

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

  test('expired deadline with failed writes wakes only once per owner',
      () async {
    var now = DateTime.now();
    final store = _WriteFailureStore();
    outbox.dispose();
    outbox = PersistentOutboxManager(store, accountId: 'me', clock: () => now);
    manager.reportSuccess();
    final transport = _FakeTransport()
      ..responses.add(() => Future.error(_ServerUnavailable()));
    final original = controllerFor(transport);
    await original.sendText('storage fixture');
    final row = (await outbox.unsent()).single;
    original.dispose();
    now = row.nextServerRetryAt!.add(const Duration(seconds: 1));
    store.fail = true;
    final restored = controllerFor(transport)..restoreOutboxMessage(row);
    final scheduler = MessageSendScheduler(
        outbox: outbox, senderFor: (_) => _ControllerSender(restored))
      ..start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(store.failedWrites, lessThanOrEqualTo(3));
    expect(transport.txids, [row.txid]);
    final retained = (await outbox.unsent()).single;
    expect(retained.serverRetryCount, 1);
    expect(retained.status, OutboxStatus.waitingNetwork);
    store.fail = false;
    manager.report(transportAvailable: false);
    manager.reportSuccess();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(transport.txids, [row.txid, row.txid]);
    expect(await outbox.unsent(), isEmpty);
    scheduler.dispose();
    restored.dispose();
  });

  testWidgets(
      'retryable canonical admission failure receives durable retry budget',
      (tester) async {
    outbox.dispose();
    outbox = PersistentOutboxManager(InMemoryOutboxStore(),
        accountId: 'me', clock: tester.binding.clock.now);
    var admissions = 0;
    final transport = _FakeTransport();
    final controller = RoomTimelineController(transport,
        outboxJournal: RoomOutboxJournal(
            manager: outbox,
            roomId: '!room:test',
            receiverId: '@peer:test',
            beforeClaim: (_) async {
              admissions++;
              throw _ServerUnavailable();
            }));
    await controller.sendText('admission fixture');
    final row = (await outbox.unsent()).single;
    expect(row.serverRetryCount, 1);
    expect(row.nextServerRetryAt, isNotNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(admissions, 2);
    expect(transport.txids, isEmpty);
    controller.dispose();
  });

  for (final ownerFailed in [false, true]) {
    test(
        'late admission failure preserves concurrent owner ${ownerFailed ? 'terminal rejection' : 'retry deadline'}',
        () async {
      final admission = Completer<bool>();
      final transport = _FakeTransport();
      final delayed = RoomTimelineController(transport,
          outboxJournal: RoomOutboxJournal(
              manager: outbox,
              roomId: '!room:test',
              receiverId: '@peer:test',
              beforeClaim: (_) => admission.future));
      final pending = delayed.sendText('concurrent admission');
      await pumpEventQueue();
      final row = (await outbox.unsent()).single;
      final owner =
          outbox.journalFor(roomId: '!room:test', receiverId: '@peer:test');
      expect(await owner.claim(row.localId), isTrue);
      await owner.settle(row.localId,
          ownerFailed ? OutboxStatus.failed : OutboxStatus.waitingNetwork,
          error: ownerFailed ? StateError('denied') : _ServerUnavailable());
      final settled = (await outbox.byLocalId(row.localId))!;
      admission.completeError(
          ownerFailed ? _ServerUnavailable() : StateError('denied'));
      await pending;
      final retained = (await outbox.byLocalId(row.localId))!;
      expect(retained.status, settled.status);
      expect(retained.retryCount, settled.retryCount);
      expect(retained.serverRetryCount, settled.serverRetryCount);
      expect(retained.nextServerRetryAt, settled.nextServerRetryAt);
      expect(retained.lastError, settled.lastError);
      expect(transport.txids, isEmpty);
      delayed.dispose();
    });
  }

  for (final failure in [false, true]) {
    testWidgets(
        'observation timeout holds budget until late ${failure ? '503' : 'ACK'}',
        (tester) async {
      outbox.dispose();
      outbox = PersistentOutboxManager(InMemoryOutboxStore(),
          accountId: 'me', clock: tester.binding.clock.now);
      final response = Completer<String>();
      final transport = _FakeTransport()..responses.add(() => response.future);
      final controller = RoomTimelineController(transport,
          sendDispatchTimeout: const Duration(seconds: 1),
          outboxJournal: outbox.journalFor(
              roomId: '!room:test', receiverId: '@peer:test'));
      final pending = controller.sendText('timeout fixture');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(await pending, isNull);
      final row = (await outbox.unsent()).single;
      expect(row.status, OutboxStatus.sending);
      expect(row.serverRetryCount, 0);
      expect(row.nextServerRetryAt, isNull);
      expect(await outbox.claim(row.localId), isFalse);
      await controller.retry(row.txid);
      expect(transport.txids, [row.txid]);
      controller.dispose();
      if (failure) {
        response.completeError(_ServerUnavailable());
      } else {
        response.complete('ack');
      }
      await tester.pump();
      final settled = await outbox.byLocalId(row.localId);
      if (failure) {
        expect(settled!.serverRetryCount, 1);
        expect(settled.nextServerRetryAt,
            tester.binding.clock.now().add(const Duration(seconds: 5)));
      } else {
        expect(settled, isNull);
      }
    });
  }

  testWidgets(
      'direct foreground late failure wakes background after page disposal',
      (tester) async {
    outbox.dispose();
    outbox = PersistentOutboxManager(InMemoryOutboxStore(),
        accountId: 'me', clock: tester.binding.clock.now);
    manager.reportSuccess();
    final response = Completer<String>();
    final transport = _FakeTransport()..responses.add(() => response.future);
    final scheduler = MessageSendScheduler(
        outbox: outbox,
        senderFor: (_) => null,
        networkState: manager,
        leaseFactory: (_) async => _TransportLease(transport))
      ..start();
    await tester.pump();
    final controller = controllerFor(transport);
    final pending = controller.sendText('direct typed');
    await tester.pump();
    final row = (await outbox.unsent()).single;
    controller.dispose();
    response.completeError(_ServerUnavailable());
    await pending;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(transport.txids, [row.txid, row.txid]);
    expect(await outbox.unsent(), isEmpty);
    scheduler.dispose();
  });

  testWidgets(
      'restored page wakes at durable deadline and wrapper never charges twice',
      (tester) async {
    outbox.dispose();
    outbox = PersistentOutboxManager(InMemoryOutboxStore(),
        accountId: 'me', clock: tester.binding.clock.now);
    final transport = _FakeTransport()
      ..responses.add(() => Future.error(_ServerUnavailable()));
    var controller = controllerFor(transport);
    final row = (await outbox.save(
        receiverId: '@peer:test', content: 'x', roomId: '!room:test'))!;
    final scheduler = MessageSendScheduler(
        outbox: outbox, senderFor: (_) => _ControllerSender(controller));
    await scheduler.drain();
    final failed = (await outbox.byLocalId(row.localId))!;
    expect(failed.serverRetryCount, 1);
    scheduler.dispose();
    controller.dispose();
    controller = controllerFor(transport)..restoreOutboxMessage(failed);
    await tester.pump(const Duration(seconds: 4));
    expect(transport.txids, [row.txid]);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(transport.txids, [row.txid, row.txid]);
    expect(await outbox.unsent(), isEmpty);
    controller.dispose();
  });

  test('late server failure persists retry budget after page disposal',
      () async {
    final response = Completer<String>();
    final transport = _FakeTransport()..responses.add(() => response.future);
    final controller = controllerFor(transport);
    final send = controller.sendText('persist backoff');
    await pumpEventQueue();
    final row = (await outbox.unsent()).single;
    controller.dispose();
    response.completeError(_ServerUnavailable());
    await send;
    final settled = (await outbox.byLocalId(row.localId))!;
    expect(settled.status, OutboxStatus.waitingNetwork);
    expect(settled.toRow()['server_retry_count'], 1);
    expect(settled.toRow()['next_server_retry_at'], isA<int>());
    expect(await outbox.claim(row.localId), isFalse);
  });

  group('room switch during dispatch', () {
    test('late server acknowledgement settles outbox after page disposal',
        () async {
      final response = Completer<String>();
      final transport = _FakeTransport()..responses.add(() => response.future);
      final controller = controllerFor(transport);
      final send = controller.sendText('in flight');
      await pumpEventQueue();
      final row = (await outbox.unsent()).single;
      controller.dispose();
      final reopenedTransport = _FakeTransport();
      final reopened = controllerFor(reopenedTransport);
      await reopened.sendText(row.content, outboxRow: row);
      expect(reopened.messages.single.deliveryState, RoomDeliveryState.sending);
      response.complete(r'$accepted');
      expect(await send, r'$accepted');
      expect(await outbox.unsent(), isEmpty);
      expect(transport.txids, [row.txid]);
      expect(reopenedTransport.txids, isEmpty);
      reopened.dispose();
    });

    for (final networkFailure in [false, true]) {
      test(
          'late ${networkFailure ? "network" : "server"} failure survives page disposal',
          () async {
        final response = Completer<String>();
        final transport = _FakeTransport()
          ..responses.add(() => response.future);
        final controller = controllerFor(transport);
        final send = controller.sendText('in flight');
        await pumpEventQueue();
        final original = (await outbox.unsent()).single;
        controller.dispose();
        response.completeError(networkFailure
            ? const SocketException('offline')
            : StateError('M_FORBIDDEN'));
        await send;
        final row = (await outbox.unsent()).single;
        expect(row.txid, original.txid);
        expect(row.status,
            networkFailure ? OutboxStatus.waitingNetwork : OutboxStatus.failed);
        expect(row.lastError, 'send_failed');
      });
    }
  });

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
      expect(pending.single.lastError, 'send_failed');
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
  for (final status in [
    OutboxStatus.sending,
    OutboxStatus.waitingNetwork,
    OutboxStatus.failed
  ]) {
    test('historical source preserves $status without rerouting retries',
        () async {
      final transport = _FakeTransport();
      final controller =
          RoomTimelineController(transport, outboxRoomId: '!primary:test');
      final row = OutboxMessage(
          localId: 'old-local',
          txid: 'old-tx',
          receiverId: '@peer:test',
          content: 'in source',
          roomId: '!old:test',
          status: status,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026));
      controller.restoreOutboxMessage(row);
      expect(controller.messages.single.deliveryState,
          roomDeliveryStateOf(status));
      await controller.retry(row.txid);
      expect(transport.txids, isEmpty);
      controller.dispose();
    });
  }
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
    expect(controller.messages.single.deliveryState, RoomDeliveryState.local);
    await controller.retry(row.txid);
    expect(transport.txids, isEmpty);
    controller.dispose();
  });
}
