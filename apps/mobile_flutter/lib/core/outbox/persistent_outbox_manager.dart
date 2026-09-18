import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'outbox_message.dart';
import 'outbox_store.dart';

/// 时钟注入点（测试可固定时间）。
typedef OutboxClock = DateTime Function();

/// 标识生成注入点（测试可固定 localId / txid）。
typedef OutboxIdGenerator = String Function();

/// 房间内发送路径使用的持久化日志（`RoomTimelineController` 的注入点）。
///
/// 只有这一个接缝：控制器在**派发之前**把消息写进 outbox，并在结果回来时
/// 更新状态；它不需要知道房间号、接收方或数据库形状。
abstract interface class OutboxJournal {
  Future<OutboxMessage?> findByTxid(String txid);

  /// 插入（幂等：txid 已存在时返回既有行，不产生第二行）。
  Future<OutboxMessage?> persist({
    required String txid,
    required String content,
    OutboxStatus status = OutboxStatus.queued,
    String? localId,
  });

  /// 认领：把行翻成 [OutboxStatus.sending]；返回 false 表示别的派发者
  /// 已经认领/已送达，本次**不得**再发一次。
  Future<bool> claim(String localId, {Set<OutboxStatus>? from});

  /// 结果落定（等待网络 / 发送失败）。
  Future<void> settle(String localId, OutboxStatus status, {String? lastError});

  /// 服务端已确认：先记 `sent`，再从表里移除（不保留正文副本）。
  Future<void> complete(String localId);
}

/// 出站消息管理器：**发送前先持久化**的唯一入口。
///
/// 职责：
/// - [save]：创建一条消息（生成一次 localId/txid）并落盘；
/// - [queryPending] / [unsent]：读取待处理行；
/// - [claim] / [updateStatus]：状态迁移（认领是原子的）；
/// - [removeOrArchive]：已确认送达的行从表里移除（保留正文没有价值，
///   反而扩大明文暴露面）；
/// - [recoverOnStartup]：进程重启后把"派发中"的行复位为 queued 再交给调度器；
/// - [bindRoomForReceiver]：pending conversation 拿到真实房间号后把行绑定过去。
///
/// 所有存储异常都被吞进 [lastError] 并记日志式暴露，**绝不**让持久化故障
/// 变成"消息发不出去"——可用性优先，但失败可见（`lastError`）。
final class PersistentOutboxManager extends ChangeNotifier {
  PersistentOutboxManager(
    this.store, {
    this.accountId = '',
    OutboxClock? clock,
    OutboxIdGenerator? newLocalId,
    OutboxIdGenerator? newTxid,
  })  : _clock = clock ?? DateTime.now,
        _newLocalId = newLocalId ?? (() => const Uuid().v4()),
        _newTxid =
            newTxid ?? (() => const Uuid().v4().replaceAll('-', ''));

  /// 组合根写入的进程级实例；测试与纯逻辑层可保持 null。
  static PersistentOutboxManager? shared;

  final OutboxStore store;
  final String accountId;
  final OutboxClock _clock;
  final OutboxIdGenerator _newLocalId;
  final OutboxIdGenerator _newTxid;

  /// 最近一次持久化故障（诊断用；不影响发送路径）。
  Object? lastError;

  bool _disposed = false;

  bool get isDisposed => _disposed;

  String newLocalId() => _newLocalId();

  /// 事务 ID **只在这里生成一次**；重试/重启一律复用同一行里的 txid。
  String newTxid() => _newTxid();

  /// 创建并落盘一条待发送文本。
  ///
  /// [localId]/[txid] 允许调用方预先提供（pending 页面先做乐观展示，
  /// 再落盘同一身份），默认由本管理器生成。
  Future<OutboxMessage?> save({
    required String receiverId,
    required String content,
    String? roomId,
    String? localId,
    String? txid,
    OutboxStatus status = OutboxStatus.queued,
    DateTime? createdAt,
  }) async {
    final now = _clock();
    final message = OutboxMessage(
      localId: localId ?? newLocalId(),
      txid: txid ?? newTxid(),
      roomId: roomId,
      receiverId: receiverId,
      content: content,
      status: status,
      createdAt: createdAt ?? now,
      updatedAt: now,
      accountId: accountId,
    );
    return saveMessage(message);
  }

  /// 幂等落盘：`local_id`/`txid` 已存在时返回既有行（不新增第二行）。
  Future<OutboxMessage?> saveMessage(OutboxMessage message) async {
    if (_disposed) return null;
    final scoped = message.accountId.isEmpty && accountId.isNotEmpty
        ? message.copyWith(accountId: accountId)
        : message;
    try {
      await store.insert(scoped);
      final persisted = await store.byLocalId(scoped.localId) ??
          await store.byTxid(scoped.txid);
      lastError = null;
      _notify();
      return persisted ?? scoped;
    } catch (error) {
      lastError = error;
      return null;
    }
  }

  /// 无条件状态迁移（不认领）。
  Future<bool> updateStatus(
    String localId,
    OutboxStatus status, {
    String? lastError,
    bool countRetry = false,
  }) async {
    if (_disposed) return false;
    try {
      final changed = await store.updateStatus(
        localId,
        status,
        lastError: lastError,
        incrementRetry: countRetry,
        updatedAt: _clock(),
        clearLastError: lastError == null && status == OutboxStatus.sent,
      );
      this.lastError = null;
      if (changed) _notify();
      return changed;
    } catch (error) {
      this.lastError = error;
      return false;
    }
  }

  /// 原子认领：把行翻成 [OutboxStatus.sending]。
  ///
  /// 默认只允许从"可派发/可手动重试"的状态认领（queued / waitingNetwork /
  /// failed）。返回 false 说明这一行已经被别人派发（sending）或已送达
  /// （sent），调用方必须放弃本次派发——这就是"两次尝试只发一次"的实现。
  Future<bool> claim(
    String localId, {
    Set<OutboxStatus>? from,
    bool countRetry = true,
  }) async {
    if (_disposed) return false;
    try {
      final changed = await store.updateStatus(
        localId,
        OutboxStatus.sending,
        incrementRetry: countRetry,
        updatedAt: _clock(),
        from: from ?? const <OutboxStatus>{
          OutboxStatus.queued,
          OutboxStatus.waitingNetwork,
          OutboxStatus.failed,
        },
      );
      lastError = null;
      if (changed) {
        _notify();
        return true;
      }
      // 没改到行有两种可能：行已不存在（可以发），或已被别的派发者认领/
      // 已送达（绝对不能再发一次）。必须读一次才能区分。
      final current = await store.byLocalId(localId);
      if (current == null) return true;
      return !(current.status.isSettled || current.status.isInFlight);
    } catch (error) {
      lastError = error;
      // 持久化故障时不阻断发送：可用性优先（状态无法落盘由 lastError 暴露）。
      return true;
    }
  }

  /// 所有"未送达"行（含失败与等待网络），按创建顺序。
  Future<List<OutboxMessage>> unsent() => _query(unsent: true);

  /// 需要自动派发的行（`queued` + `waitingNetwork`）。
  ///
  /// `failed` 不在其中：服务端明确拒绝只能由用户手动重试发起。
  Future<List<OutboxMessage>> queryPending({
    String? roomId,
    String? receiverId,
  }) =>
      _query(
        statuses: const <OutboxStatus>{
          OutboxStatus.queued,
          OutboxStatus.waitingNetwork,
        },
        roomId: roomId,
        receiverId: receiverId,
      );

  Future<List<OutboxMessage>> _query({
    Set<OutboxStatus>? statuses,
    bool unsent = false,
    String? roomId,
    String? receiverId,
  }) async {
    try {
      final rows = await store.query(
        statuses: statuses,
        unsent: unsent,
        roomId: roomId,
        receiverId: receiverId,
        accountId: accountId.isEmpty ? null : accountId,
      );
      lastError = null;
      return rows;
    } catch (error) {
      lastError = error;
      return const <OutboxMessage>[];
    }
  }

  Future<OutboxMessage?> byTxid(String txid) async {
    try {
      return await store.byTxid(txid);
    } catch (error) {
      lastError = error;
      return null;
    }
  }

  Future<OutboxMessage?> byLocalId(String localId) async {
    try {
      return await store.byLocalId(localId);
    } catch (error) {
      lastError = error;
      return null;
    }
  }

  /// 从 outbox 移除（默认实现即删除）。
  ///
  /// "归档"在这里等价于删除：消息已经由服务端确认（或由用户撤销），
  /// 本地再留一份正文只增加明文暴露面，没有任何恢复价值。
  Future<void> removeOrArchive(String localId) async {
    if (_disposed) return;
    try {
      await store.delete(localId);
      lastError = null;
      _notify();
    } catch (error) {
      lastError = error;
    }
  }

  Future<void> bindRoom(String localId, String roomId) async {
    if (_disposed) return;
    try {
      final changed = await store.bindRoom(localId, roomId, updatedAt: _clock());
      lastError = null;
      if (changed) _notify();
    } catch (error) {
      lastError = error;
    }
  }

  /// pending conversation 拿到真实房间号后，把该接收方所有"还没有房间号"
  /// 的行绑定过去；返回受影响行数。
  Future<int> bindRoomForReceiver(
    String receiverId,
    String roomId, {
    Iterable<String>? localIds,
  }) async {
    if (_disposed) return 0;
    try {
      final changed = await store.bindRoomForReceiver(
        receiverId,
        roomId,
        accountId: accountId.isEmpty ? null : accountId,
        localIds: localIds,
        updatedAt: _clock(),
      );
      lastError = null;
      if (changed > 0) _notify();
      return changed;
    } catch (error) {
      lastError = error;
      return 0;
    }
  }

  /// 进程启动恢复。
  ///
  /// 读取全部 `status != sent` 的行；把上次进程死在"派发中"的行复位为
  /// [OutboxStatus.queued]（它是否真的发出去了由 txid 幂等兜底），
  /// 返回复位后的未送达行清单供调度器继续。
  Future<List<OutboxMessage>> recoverOnStartup() async {
    if (_disposed) return const <OutboxMessage>[];
    final rows = await unsent();
    var changed = false;
    for (final row in rows) {
      if (!row.status.isInFlight) continue;
      final ok = await updateStatus(
        row.localId,
        OutboxStatus.queued,
        lastError: 'interrupted',
      );
      changed = changed || ok;
    }
    if (changed) _notify();
    return unsent();
  }

  /// 清理（退出登录/清空聊天记录时按账号调用）。
  Future<void> clear({String? accountId}) async {
    try {
      await store.clear(accountId: accountId ?? this.accountId);
      lastError = null;
      _notify();
    } catch (error) {
      lastError = error;
    }
  }

  /// 已确认送达的行不应长期留存正文；启动恢复时顺手清理。
  Future<int> pruneSent() async {
    try {
      return await store.deleteSent(
          accountId: accountId.isEmpty ? null : accountId);
    } catch (error) {
      lastError = error;
      return 0;
    }
  }

  /// 房间内发送路径的持久化日志。
  OutboxJournal journalFor({
    required String roomId,
    required String receiverId,
  }) =>
      RoomOutboxJournal(
          manager: this, roomId: roomId, receiverId: receiverId);

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

/// 绑定到"房间 + 接收方"的日志视图。
final class RoomOutboxJournal implements OutboxJournal {
  RoomOutboxJournal({
    required PersistentOutboxManager manager,
    required this.roomId,
    required this.receiverId,
  }) : _manager = manager;

  final PersistentOutboxManager _manager;
  final String roomId;
  final String receiverId;

  @override
  Future<OutboxMessage?> findByTxid(String txid) => _manager.byTxid(txid);

  @override
  Future<OutboxMessage?> persist({
    required String txid,
    required String content,
    OutboxStatus status = OutboxStatus.queued,
    String? localId,
  }) =>
      _manager.save(
        receiverId: receiverId,
        content: content,
        roomId: roomId,
        localId: localId,
        txid: txid,
        status: status,
      );

  @override
  Future<bool> claim(String localId, {Set<OutboxStatus>? from}) =>
      _manager.claim(localId, from: from);

  @override
  Future<void> settle(String localId, OutboxStatus status,
          {String? lastError}) =>
      _manager.updateStatus(localId, status, lastError: lastError);

  @override
  Future<void> complete(String localId) async {
    await _manager.updateStatus(localId, OutboxStatus.sent);
    await _manager.removeOrArchive(localId);
  }
}
