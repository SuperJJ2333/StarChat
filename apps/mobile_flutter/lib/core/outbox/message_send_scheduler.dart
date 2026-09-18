import 'dart:async';

import '../../core/network_state_manager.dart';
import 'outbox_message.dart';
import 'outbox_room_sender_registry.dart';
import 'persistent_outbox_manager.dart';

/// 临时房间租约：由组合根注入的工厂打开（`MatrixRoomLease` + timeline），
/// **只用于发送**，不导航、不 push 页面。
///
/// 生命周期约定：[release] 必须在成功、失败、取消三条路径上都被调用一次
/// （调度器用 `finally` 保证）。
abstract interface class OutboxLease {
  /// 复用行内 txid 发送；成功返回服务端 event id。
  Future<String> send(String text, String transactionId);

  /// 释放租约与临时时间线（幂等）。
  Future<void> release();
}

/// 打开某个房间的临时租约；抛错表示当前租约不可用（会话未就绪、房间本地
/// 不存在等），调用方必须把行保持在"等待网络"而不是判为终局失败。
typedef OutboxLeaseFactory = Future<OutboxLease> Function(String roomId);

/// 出站消息调度器（Offline First）。
///
/// 只听一个信号：[NetworkStateManager.state]。进入 `online`（或 `recovering`）
/// 时扫描 `queued` + `waitingNetwork` 的行并派发。
///
/// 派发有两条路径，按优先级：
/// 1. **已打开的房间会话**（[senderFor] 返回句柄）：把行交回 `RoomPage` 的
///    发送状态机，消息在时间线上有本地气泡与实时状态；
/// 2. **没有打开的房间**：若注入了 [leaseFactory]，则临时取一次租约
///    （不导航、不 push 页面）发送后立即释放；否则原封不动留着等用户下次
///    进入会话。
///
/// 硬约束：
/// - **不创建任何定时器、不轮询**：唯一的驱动是网络状态通知与显式 [drain]；
/// - **串行**：同一时刻最多一条派发路径在跑（房间之间也串行），启动恢复
///   不会同时打开多个租约；
/// - **幂等**：无论走哪条路径，派发前都必须原子认领该行
///   （[PersistentOutboxManager.claim]），因此同一 txid 只会真正发一次；
/// - 网络问题一律 `waitingNetwork`，**绝不**降级为 `failed`；
/// - [dispose] 后不再有任何派发，且不会漏掉租约释放。
final class MessageSendScheduler {
  MessageSendScheduler({
    required this.outbox,
    required this.senderFor,
    this.networkState,
    this.canDispatch,
    this.leaseFactory,
  });

  final PersistentOutboxManager outbox;

  /// 取某个房间当前打开的发送句柄；返回 null 表示房间没打开。
  final OutboxSender? Function(String roomId) senderFor;

  final NetworkStateManager? networkState;

  /// 附加门禁（例如互动权限）：返回 false 时该行不派发。
  final bool Function(OutboxMessage message)? canDispatch;

  /// 没有已打开会话时使用的临时租约工厂（可空 = 不做后台发送尝试）。
  final OutboxLeaseFactory? leaseFactory;

  final Set<String> _inFlight = <String>{};
  NetworkStateManager? _attached;
  bool _draining = false;
  bool _disposed = false;
  int _dispatched = 0;

  /// 本调度器成功派发的行数（测试与诊断用）。
  int get dispatchedCount => _dispatched;

  bool get isDraining => _draining;

  bool get isDisposed => _disposed;

  bool get _networkUsable {
    final state = networkState?.current;
    return state == null ||
        state == NetworkState.online ||
        state == NetworkState.recovering;
  }

  /// 挂载网络恢复监听。幂等；不创建定时器。
  void start() {
    if (_disposed || _attached != null) return;
    final manager = networkState;
    if (manager == null) return;
    _attached = manager;
    manager.state.addListener(_onNetworkStateChanged);
    // 挂载时可能已经在线（例如恢复服务在同步成功之后才启动）。
    if (manager.current == NetworkState.online ||
        manager.current == NetworkState.recovering) {
      unawaited(drain());
    }
  }

  void _onNetworkStateChanged() {
    if (_disposed) return;
    if (!_networkUsable) return;
    unawaited(drain());
  }

  /// 扫描并派发一轮；返回本次成功派发的行数。
  ///
  /// 串行处理：先按房间分组（保持创建顺序），房间之间依次处理，每个房间
  /// 最多开一个临时租约。并发调用（网络恢复信号 + 显式 drain）由 [_draining]
  /// 与逐行原子认领双重去重。
  Future<int> drain() async {
    if (_disposed || _draining) return 0;
    _draining = true;
    var sent = 0;
    try {
      final rows = await outbox.queryPending();
      if (_disposed) return 0;
      final offline = networkState?.current == NetworkState.offline;
      final byRoom = <String, List<OutboxMessage>>{};
      for (final row in rows) {
        final roomId = row.roomId?.trim() ?? '';
        if (roomId.isEmpty) {
          // 会话还没建立：等 pending conversation 绑定房间号。
          continue;
        }
        byRoom.putIfAbsent(roomId, () => <OutboxMessage>[]).add(row);
      }
      if (offline) {
        // 离线不尝试派发：状态落到"等待网络"，恢复后由监听自动继续。
        for (final roomRows in byRoom.values) {
          for (final row in roomRows) {
            await outbox.updateStatus(row.localId, OutboxStatus.waitingNetwork,
                lastError: 'offline', countRetry: false);
          }
        }
        return 0;
      }
      for (final entry in byRoom.entries) {
        if (_disposed) break;
        final sender = senderFor(entry.key);
        if (sender != null) {
          sent += await _dispatchViaRoomSender(sender, entry.value);
          continue;
        }
        final factory = leaseFactory;
        if (factory == null) continue;
        sent += await _dispatchViaLease(entry.key, entry.value, factory);
      }
    } finally {
      _draining = false;
    }
    return sent;
  }

  /// 路径 1：房间已打开 → 交回会话的发送状态机（时间线有本地气泡）。
  Future<int> _dispatchViaRoomSender(
      OutboxSender sender, List<OutboxMessage> rows) async {
    var sent = 0;
    for (final row in rows) {
      if (_disposed) break;
      if (canDispatch != null && !canDispatch!(row)) continue;
      if (!_inFlight.add(row.localId)) continue;
      try {
        final eventId = await sender.send(row);
        if (eventId.isEmpty) {
          throw StateError('Matrix event was not accepted');
        }
        _dispatched++;
        sent++;
      } catch (error) {
        // 行内状态由会话的发送状态机与 outbox 日志落定；这里只把网络事实
        // 上报给网络状态机，让恢复信号照常产生。
        if (defaultNetworkFailureClassifier(error)) {
          networkState?.reportFailure(error);
        }
      } finally {
        _inFlight.remove(row.localId);
      }
    }
    return sent;
  }

  /// 路径 2：房间没有打开 → 临时租约发送，**成功/失败/取消都必须释放**。
  ///
  /// 租约打不开（会话未就绪、房间本地不存在、SDK 生命周期拒绝）时，行保持
  /// "等待网络"，绝不判为终局失败：这不是服务端的业务拒绝。
  Future<int> _dispatchViaLease(
    String roomId,
    List<OutboxMessage> rows,
    OutboxLeaseFactory factory,
  ) async {
    OutboxLease? lease;
    try {
      lease = await factory(roomId);
    } catch (error) {
      await _keepWaitingNetwork(rows, error);
      return 0;
    }
    var sent = 0;
    try {
      for (final row in rows) {
        if (_disposed) break;
        // 在此期间用户可能已经打开了这个房间：把剩下的行交给已打开会话
        // （时间线有气泡），避免同一条消息在两条路径上各发一次。
        final live = senderFor(roomId);
        if (live != null) {
          sent += await _dispatchViaRoomSender(live, rows.sublist(rows.indexOf(row)));
          break;
        }
        if (canDispatch != null && !canDispatch!(row)) continue;
        if (!_inFlight.add(row.localId)) continue;
        try {
          // 原子认领：失败说明已被别的派发者认领/已送达。
          if (!await outbox.claim(row.localId)) continue;
          final eventId = await lease.send(row.content, row.txid);
          if (eventId.isEmpty) {
            throw StateError('Matrix event was not accepted');
          }
          await outbox.updateStatus(row.localId, OutboxStatus.sent);
          await outbox.removeOrArchive(row.localId);
          _dispatched++;
          sent++;
        } catch (error) {
          // 网络问题 → 等待网络（自动续发）；服务端明确拒绝 → failed。
          final networkFailure = defaultNetworkFailureClassifier(error);
          await outbox.updateStatus(
            row.localId,
            networkFailure ? OutboxStatus.waitingNetwork : OutboxStatus.failed,
            lastError: error.toString(),
          );
          if (networkFailure) networkState?.reportFailure(error);
        } finally {
          _inFlight.remove(row.localId);
        }
      }
    } finally {
      await lease.release();
    }
    return sent;
  }

  /// 租约不可用：保持"等待网络"（绝不 failed），只上报网络事实。
  Future<void> _keepWaitingNetwork(
      List<OutboxMessage> rows, Object error) async {
    for (final row in rows) {
      await outbox.updateStatus(row.localId, OutboxStatus.waitingNetwork,
          lastError: error.toString());
    }
    if (defaultNetworkFailureClassifier(error)) {
      networkState?.reportFailure(error);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _attached?.state.removeListener(_onNetworkStateChanged);
    _attached = null;
    _inFlight.clear();
  }
}
