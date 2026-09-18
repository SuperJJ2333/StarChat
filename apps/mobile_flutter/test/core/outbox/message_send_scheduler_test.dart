import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/network_state_manager.dart';
import 'package:liuhetong_mobile/core/outbox/message_send_scheduler.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_recovery_service.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_room_sender_registry.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';

/// 假房间句柄：模拟 `RoomPage` 的会话内发送——
/// **先原子认领 outbox 行，再"发"**，认领失败就绝不重复发送。
/// 不触网，应答脚本由测试注入。
final class _FakeSender implements OutboxSender {
  _FakeSender(this.roomId, this.manager);

  @override
  final String roomId;

  final PersistentOutboxManager manager;
  final List<String> txids = <String>[];
  final List<Future<String> Function()> responses =
      <Future<String> Function()>[];
  bool _revoked = false;

  @override
  bool get canSend => !_revoked;

  void revoke() => _revoked = true;

  @override
  Future<String> send(OutboxMessage message) async {
    final claimed = await manager.claim(message.localId);
    if (!claimed) {
      // 行已被（另一个派发者）认领或已送达：不算一次发送。
      throw const _AlreadyDispatched();
    }
    txids.add(message.txid);
    final response = responses.isEmpty
        ? () => Future<String>.value('event-${message.txid}')
        : responses.removeAt(0);
    try {
      final eventId = await response();
      await manager.updateStatus(message.localId, OutboxStatus.sent);
      await manager.removeOrArchive(message.localId);
      return eventId;
    } catch (error) {
      final status = defaultNetworkFailureClassifier(error)
          ? OutboxStatus.waitingNetwork
          : OutboxStatus.failed;
      await manager.updateStatus(message.localId, status,
          lastError: error.toString());
      rethrow;
    }
  }
}

/// 假临时租约：记录打开/释放与每次发送使用的 txid。
final class _FakeLease implements OutboxLease {
  final List<String> txids = <String>[];
  final List<Future<String> Function()> responses =
      <Future<String> Function()>[];
  /// 按正文指定失败原因（与行顺序无关，避免测试依赖 UUID 排序）。
  final Map<String, Object> failuresByText = <String, Object>{};
  int releases = 0;
  bool _released = false;

  @override
  Future<String> send(String text, String transactionId) {
    txids.add(transactionId);
    final failure = failuresByText[text];
    if (failure != null) return Future<String>.error(failure);
    if (responses.isEmpty) return Future<String>.value('event-$transactionId');
    return responses.removeAt(0)();
  }

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    releases++;
  }
}

/// 记录租约打开次数（并可按脚本失败）的工厂。
final class _LeaseFactory {
  _LeaseFactory({
    this.failOpen = false,
    this.openError,
    List<_FakeLease>? scripted,
  }) : _scripted = scripted ?? <_FakeLease>[];

  final bool failOpen;
  final Object? openError;
  final List<_FakeLease> _scripted;
  final List<String> openedRooms = <String>[];
  final List<_FakeLease> leases = <_FakeLease>[];
  int get opens => openedRooms.length;

  Future<OutboxLease> open(String roomId) async {
    openedRooms.add(roomId);
    if (failOpen) {
      throw openError ?? const SocketException('no session');
    }
    final lease =
        _scripted.isNotEmpty ? _scripted.removeAt(0) : _FakeLease();
    leases.add(lease);
    return lease;
  }
}

/// 认领失败的哨兵（不是网络失败）。
final class _AlreadyDispatched implements Exception {
  const _AlreadyDispatched();
}

/// 5xx 的鸭子类型替身（默认分类器把 5xx 视为网络失败）。
final class _Http5xx implements Exception {
  const _Http5xx(this.message);
  final String message;
  int get statusCode => 502;
  @override
  String toString() => 'HttpException(502): $message';
}

void main() {
  late PersistentOutboxManager outbox;
  late NetworkStateManager network;

  setUp(() {
    outbox = PersistentOutboxManager(InMemoryOutboxStore(), accountId: 'me');
    network = NetworkStateManager();
  });

  tearDown(() {
    network.dispose();
    outbox.dispose();
  });

  MessageSendScheduler schedulerFor(_FakeSender? sender,
          {OutboxLeaseFactory? leaseFactory}) =>
      MessageSendScheduler(
        outbox: outbox,
        networkState: network,
        senderFor: (roomId) =>
            sender != null && sender.roomId == roomId && sender.canSend
                ? sender
                : null,
        leaseFactory: leaseFactory,
      );

  group('MessageSendScheduler', () {
    test('离线：不派发，状态落到 waitingNetwork（不是 failed）', () async {
      final sender = _FakeSender('!room:test', outbox);
      final scheduler = schedulerFor(sender)..start();
      network.report(transportAvailable: false);
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      await scheduler.drain();

      expect(sender.txids, isEmpty, reason: '离线不做无谓的派发尝试');
      final stored = await outbox.byLocalId(row!.localId);
      expect(stored!.status, OutboxStatus.waitingNetwork);
      expect(stored.status, isNot(OutboxStatus.failed),
          reason: '网络问题永远不能变成红色失败');
      scheduler.dispose();
    });

    test('网络恢复：自动派发等待网络的行（复用同一 txid）', () async {
      final sender = _FakeSender('!room:test', outbox);
      final scheduler = schedulerFor(sender)..start();
      network.report(transportAvailable: false);
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');
      await scheduler.drain();
      expect(sender.txids, isEmpty);

      network.reportSuccess();
      await pumpEventQueue();

      expect(sender.txids, <String>[row!.txid]);
      expect(await outbox.unsent(), isEmpty, reason: '送达后从 outbox 移除');
      scheduler.dispose();
    });

    test('房间未打开：行原封不动保留，绝不为了发送去打开房间', () async {
      final scheduler = schedulerFor(null)..start();
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      await scheduler.drain();

      expect(
          (await outbox.byLocalId(row!.localId))!.status, OutboxStatus.queued);
      expect(scheduler.dispatchedCount, 0);
      scheduler.dispose();
    });

    test('没有房间号的行留给 pending conversation 绑定', () async {
      final sender = _FakeSender('!room:test', outbox);
      final scheduler = schedulerFor(sender)..start();
      final row =
          await outbox.save(receiverId: '@peer:test', content: 'hello');

      await scheduler.drain();

      expect(sender.txids, isEmpty);
      expect((await outbox.byLocalId(row!.localId))!.roomId, isNull);
      scheduler.dispose();
    });

    test('重复派发保护：两个调度器并发处理同一行 → 只发一次', () async {
      final sender = _FakeSender('!room:test', outbox);
      final inFlight = Completer<String>();
      sender.responses.add(() => inFlight.future);
      final first = schedulerFor(sender);
      final second = schedulerFor(sender);
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      final firstDrain = first.drain();
      final secondDrain = second.drain();
      // 两个调度器都走到"认领"这一步（第一个已交给传输层并在途）。
      await pumpEventQueue();
      expect(sender.txids, <String>[row!.txid],
          reason: '同一行只能派发一次（原子认领是唯一闸门）');

      inFlight.complete('event-1');
      await Future.wait(<Future<int>>[firstDrain, secondDrain]);
      expect(sender.txids, <String>[row.txid]);
      first.dispose();
      second.dispose();
    });

    test('dispose 之后不再派发', () async {
      final sender = _FakeSender('!room:test', outbox);
      final scheduler = schedulerFor(sender)..start();
      network.report(transportAvailable: false);
      await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      scheduler.dispose();
      network.reportSuccess();
      await pumpEventQueue();

      expect(sender.txids, isEmpty);
    });

    test('服务端拒绝：行落 failed（红色重试），恢复信号不会自动重发', () async {
      final sender = _FakeSender('!room:test', outbox);
      sender.responses
          .add(() => Future<String>.error(StateError('M_FORBIDDEN')));
      final scheduler = schedulerFor(sender)..start();
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      await scheduler.drain();

      expect(
          (await outbox.byLocalId(row!.localId))!.status, OutboxStatus.failed);
      expect(network.current, NetworkState.online,
          reason: '业务拒绝不是网络问题，不得改变网络状态');

      network.reportSuccess();
      await pumpEventQueue();
      expect(sender.txids, hasLength(1), reason: 'failed 只能手动重试');
      scheduler.dispose();
    });

    test('5xx（服务器暂时不可用）按网络失败处理 → waitingNetwork 并自动续发', () async {
      final sender = _FakeSender('!room:test', outbox);
      sender.responses
          .add(() => Future<String>.error(const _Http5xx('bad gateway')));
      final scheduler = schedulerFor(sender)..start();
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      await scheduler.drain();
      expect((await outbox.byLocalId(row!.localId))!.status,
          OutboxStatus.waitingNetwork);

      network.reportSuccess();
      await pumpEventQueue();

      expect(sender.txids, <String>[row.txid, row.txid],
          reason: '服务器暂时不可用恢复后自动继续，且复用同一 txid');
      expect(await outbox.unsent(), isEmpty);
      scheduler.dispose();
    });
  });

  group('OutboxRecoveryService', () {
    test('启动恢复：roomId 已知的行尝试发送；未知的等绑定后再发', () async {
      final sender = _FakeSender('!room:test', outbox);
      final scheduler = schedulerFor(sender);
      final recovery =
          OutboxRecoveryService(outbox: outbox, scheduler: scheduler);
      final withRoom = await outbox.save(
          receiverId: '@peer:test', content: '已有房间', roomId: '!room:test');
      final withoutRoom =
          await outbox.save(receiverId: '@peer:test', content: '等会话');

      final report = await recovery.recoverOnStartup();

      expect(report.awaitingRoom, 1);
      expect(report.dispatched, 1);
      expect(sender.txids, <String>[withRoom!.txid]);
      expect(await outbox.byLocalId(withRoom.localId), isNull);
      expect((await outbox.byLocalId(withoutRoom!.localId))!.status,
          OutboxStatus.queued);

      // 会话建立 → 绑定房间号并继续发送。
      final resumed = await recovery.resumeRoom(
          receiverId: '@peer:test', roomId: '!room:test');

      expect(resumed.bound, 1);
      expect(resumed.dispatched, 1);
      expect(sender.txids, <String>[withRoom.txid, withoutRoom.txid],
          reason: '绑定后必须复用行内 txid');
      expect(await outbox.unsent(), isEmpty);
      scheduler.dispose();
    });

    test('启动恢复：上次死在"派发中"的行复位后重发（复用 txid）', () async {
      final sender = _FakeSender('!room:test', outbox);
      final scheduler = schedulerFor(sender);
      final recovery =
          OutboxRecoveryService(outbox: outbox, scheduler: scheduler);
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');
      // 模拟"进程在派发中被杀"：状态停在 sending。
      await outbox.claim(row!.localId);

      final report = await recovery.recoverOnStartup();

      expect(report.resetInFlight, 1);
      expect(sender.txids, <String>[row.txid]);
      expect(await outbox.unsent(), isEmpty);
      scheduler.dispose();
    });

    test('房间未打开时启动恢复不丢行：留着等进入会话', () async {
      final scheduler = schedulerFor(null);
      final recovery =
          OutboxRecoveryService(outbox: outbox, scheduler: scheduler);
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      final report = await recovery.recoverOnStartup();

      expect(report.unsent, 1);
      expect(report.dispatched, 0);
      expect(
          (await outbox.byLocalId(row!.localId))!.status, OutboxStatus.queued);
      scheduler.dispose();
    });
  });

  group('临时租约路径（房间没有打开时）', () {
    test('房间未打开 + 注入 lease 工厂 → 启动恢复里真的发出去（不导航）', () async {
      final factory = _LeaseFactory();
      final scheduler = schedulerFor(null, leaseFactory: factory.open);
      final recovery =
          OutboxRecoveryService(outbox: outbox, scheduler: scheduler);
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      final report = await recovery.recoverOnStartup();

      expect(factory.openedRooms, <String>['!room:test']);
      expect(factory.leases.single.txids, <String>[row!.txid],
          reason: '后台发送必须复用持久化的 txid');
      expect(report.dispatched, 1);
      expect(await outbox.unsent(), isEmpty);
      expect(factory.leases.single.releases, 1, reason: '成功路径必须释放租约');
      scheduler.dispose();
    });

    test('与已打开房间并发时不双发：registry 优先，根本不开临时租约', () async {
      final factory = _LeaseFactory();
      final live = _FakeSender('!room:test', outbox);
      final scheduler = schedulerFor(live, leaseFactory: factory.open);
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      await scheduler.drain();

      expect(factory.opens, 0, reason: '房间已打开时不得再开临时租约');
      expect(live.txids, <String>[row!.txid]);
      expect(await outbox.unsent(), isEmpty);
      scheduler.dispose();
    });

    test('派发途中用户打开房间 → 交给已打开会话，不重复发送', () async {
      final lease = _FakeLease();
      final factory = _LeaseFactory(scripted: <_FakeLease>[lease]);
      var live = <OutboxSender>[];
      final roomSender = _FakeSender('!room:test', outbox);
      final scheduler = MessageSendScheduler(
        outbox: outbox,
        networkState: network,
        senderFor: (roomId) => live.isEmpty ? null : roomSender,
        leaseFactory: factory.open,
      );
      final first = await outbox.save(
          receiverId: '@peer:test', content: '第一条', roomId: '!room:test');
      final second = await outbox.save(
          receiverId: '@peer:test', content: '第二条', roomId: '!room:test');
      // 第一条发出后，用户打开了会话。
      lease.responses.add(() {
        live = <OutboxSender>[roomSender];
        return Future<String>.value('event-1');
      });

      await scheduler.drain();

      expect(lease.txids, hasLength(1));
      expect(roomSender.txids, hasLength(1),
          reason: '另一条在用户打开房间后交给已打开会话（不双发、也不留在队列里）');
      expect(
        <String>{lease.txids.single, roomSender.txids.single},
        <String>{first!.txid, second!.txid},
        reason: '两条消息各发一次，且都复用各自行内的 txid',
      );
      expect(await outbox.unsent(), isEmpty);
      expect(lease.releases, 1);
      scheduler.dispose();
    });

    test('租约不可用 → 行保持 waitingNetwork（绝不 failed）', () async {
      final factory = _LeaseFactory(
          failOpen: true, openError: const SocketException('down'));
      final scheduler = schedulerFor(null, leaseFactory: factory.open);
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      await scheduler.drain();

      final stored = await outbox.byLocalId(row!.localId);
      expect(stored!.status, OutboxStatus.waitingNetwork);
      expect(stored.status, isNot(OutboxStatus.failed),
          reason: '租约不可用是暂时性问题，不是服务端业务拒绝');

      scheduler.start();
      network.reportSuccess();
      await pumpEventQueue();
      expect(factory.opens, 2, reason: '网络恢复后自动重试临时租约路径');
      scheduler.dispose();
    });

    test('服务端拒绝 → failed；网络失败 → waitingNetwork；失败路径也释放租约', () async {
      final lease = _FakeLease();
      final factory = _LeaseFactory(scripted: <_FakeLease>[lease]);
      final scheduler = schedulerFor(null, leaseFactory: factory.open);
      final rejected = await outbox.save(
          receiverId: '@peer:test', content: '被拒绝', roomId: '!room:test');
      final offlineRow = await outbox.save(
          receiverId: '@peer:test', content: '网络失败', roomId: '!room:test');
      lease.failuresByText
        ..['被拒绝'] = StateError('M_FORBIDDEN')
        ..['网络失败'] = const SocketException('reset');

      await scheduler.drain();

      expect((await outbox.byLocalId(rejected!.localId))!.status,
          OutboxStatus.failed);
      expect((await outbox.byLocalId(offlineRow!.localId))!.status,
          OutboxStatus.waitingNetwork);
      expect(lease.releases, 1, reason: '失败路径也必须释放租约');
      scheduler.dispose();
    });

    test('dispose（取消路径）也释放租约', () async {
      final lease = _FakeLease();
      final factory = _LeaseFactory(scripted: <_FakeLease>[lease]);
      final scheduler = schedulerFor(null, leaseFactory: factory.open);
      final first = await outbox.save(
          receiverId: '@peer:test', content: '第一条', roomId: '!room:test');
      final second = await outbox.save(
          receiverId: '@peer:test', content: '第二条', roomId: '!room:test');
      lease.responses.add(() {
        scheduler.dispose();
        return Future<String>.value('event-1');
      });

      await scheduler.drain();

      expect(lease.releases, 1);
      expect(lease.txids, hasLength(1));
      final remaining = await outbox.unsent();
      expect(remaining, hasLength(1),
          reason: 'dispose 后剩下的行不再派发，留给下次恢复');
      expect(
        <String>{first!.txid, second!.txid}.difference(lease.txids.toSet()),
        <String>{remaining.single.txid},
      );
    });

    test('没有注入 lease 工厂时保持旧行为：行原样留着', () async {
      final scheduler = schedulerFor(null);
      final row = await outbox.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      await scheduler.drain();

      expect(
          (await outbox.byLocalId(row!.localId))!.status, OutboxStatus.queued);
      scheduler.dispose();
    });
  });

  group('OutboxRoomSenderRegistry', () {
    test('注册/注销与租约失效', () {
      final registry = OutboxRoomSenderRegistry();
      final sender = _FakeSender('!room:test', outbox);
      registry.register(sender);
      expect(registry.senderFor('!room:test'), same(sender));
      expect(registry.senderFor('!other:test'), isNull);

      sender.revoke();
      expect(registry.senderFor('!room:test'), isNull,
          reason: '租约失效的句柄按"房间没打开"处理');

      registry.clear();
      expect(registry.length, 0);
    });
  });
}
