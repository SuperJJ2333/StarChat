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
/// - **不轮询**：派发由网络状态通知与显式 [drain] 驱动，仅使用操作超时；
/// - **有界顺序处理**：超时的请求仍持有原认领，其他房间可以继续处理；
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
    this.authorizeSend,
    this.resolveUnbound,
    this.leaseFactory,
    this.operationTimeout = const Duration(seconds: 30),
  });

  final PersistentOutboxManager outbox;

  /// 取某个房间当前打开的发送句柄；返回 null 表示房间没打开。
  final OutboxSender? Function(String roomId) senderFor;

  final NetworkStateManager? networkState;

  /// 附加门禁（例如互动权限）：返回 false 时该行不派发。
  final bool Function(OutboxMessage message)? canDispatch;

  /// Authoritative account, canonical destination and interaction check.
  /// Denial or unavailable evidence fails closed before invoking transport.
  final Future<bool> Function(OutboxMessage message)? authorizeSend;

  /// Resolve a durable row's peer through authoritative coordination without
  /// opening a page. The composition root checks account/relationship identity.
  /// Null means still pending; never rebind rows which already have a room.
  final Future<String?> Function(OutboxMessage message)? resolveUnbound;

  /// 没有已打开会话时使用的临时租约工厂（可空 = 不做后台发送尝试）。
  final OutboxLeaseFactory? leaseFactory;
  final Duration operationTimeout;

  final Set<String> _inFlight = <String>{};
  NetworkStateManager? _attached;
  bool _draining = false;
  bool _drainRequested = false;
  bool _reportingFailure = false;
  int _recoveryRevision = 0;
  final Set<String> _openingRooms = <String>{};
  final Set<String> _resolvingReceivers = <String>{};
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
    if (_disposed || _reportingFailure) return;
    if (!_networkUsable) return;
    _recoveryRevision++;
    unawaited(drain());
  }

  /// 扫描并派发一轮；返回本次成功派发的行数。
  ///
  /// 串行处理：先按房间分组（保持创建顺序），房间之间依次处理，每个房间
  /// 最多开一个临时租约。并发调用（网络恢复信号 + 显式 drain）由 [_draining]
  /// 与逐行原子认领双重去重。
  Future<int> drain() async {
    if (_disposed) return 0;
    if (_draining) {
      _drainRequested = true;
      return 0;
    }
    _draining = true;
    var sent = 0;
    try {
      do {
        _drainRequested = false;
        sent += await _drainBatch();
      } while (!_disposed && _drainRequested);
    } finally {
      _draining = false;
    }
    return sent;
  }

  Future<int> _drainBatch() async {
    var sent = 0;
    var rows = await outbox.queryPending();
    if (_disposed) return 0;
    if (_networkUsable && resolveUnbound != null) {
      await _resolveUnboundRows(rows);
      if (_disposed) return 0;
      rows = await outbox.queryPending();
      if (_disposed) return 0;
    }
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
    return sent;
  }

  Future<void> _resolveUnboundRows(List<OutboxMessage> rows) async {
    final peers = <String, OutboxMessage>{};
    for (final row in rows) {
      if (!row.hasRoom) peers.putIfAbsent(row.receiverId, () => row);
    }
    for (final row in peers.values) {
      if (_disposed || !_networkUsable) return;
      if (!_resolvingReceivers.add(row.receiverId)) continue;
      var timedOut = false;
      final revision = _recoveryRevision;
      final resolving = () async {
        try {
          final roomId = await resolveUnbound!(row);
          if (_disposed) return;
          if (roomId == null || roomId.trim().isEmpty) {
            await _settleUnbound(row.receiverId, OutboxStatus.waitingNetwork,
                'conversation_pending');
            return;
          }
          await outbox.bindRoomForReceiver(row.receiverId, roomId.trim());
        } catch (error) {
          if (_disposed) return;
          final networkFailure = defaultNetworkFailureClassifier(error);
          await _settleUnbound(
              row.receiverId,
              networkFailure
                  ? OutboxStatus.waitingNetwork
                  : OutboxStatus.failed,
              networkFailure
                  ? 'conversation_unavailable'
                  : 'conversation_denied');
          if (_disposed) return;
          if (networkFailure &&
              revision != _recoveryRevision &&
              _networkUsable) {
            _drainRequested = true;
          } else if (networkFailure) {
            _reportFailure(error);
          }
        } finally {
          _resolvingReceivers.remove(row.receiverId);
        }
      }();
      unawaited(resolving.then<void>((_) {
        if (timedOut && !_disposed && _networkUsable) unawaited(drain());
      }));
      await resolving.timeout(operationTimeout, onTimeout: () async {
        timedOut = true;
        // The underlying alias resolution remains single-flight. Only its
        // eventual result may bind the original durable rows.
        await _settleUnbound(row.receiverId, OutboxStatus.waitingNetwork,
            'conversation_resolution_timeout');
      });
    }
  }

  Future<void> _settleUnbound(
      String receiverId, OutboxStatus status, String reason) async {
    final rows = await outbox.queryPending(receiverId: receiverId);
    for (final row in rows) {
      if (_disposed) return;
      if (row.hasRoom) continue;
      if (await outbox.claim(row.localId,
          from: const {OutboxStatus.queued, OutboxStatus.waitingNetwork},
          countRetry: false)) {
        if (_disposed) return;
        await outbox.updateStatus(row.localId, status, lastError: reason);
      }
    }
  }

  /// 路径 1：房间已打开 → 交回会话的发送状态机（时间线有本地气泡）。
  Future<int> _dispatchViaRoomSender(
      OutboxSender sender, List<OutboxMessage> rows) async {
    var sent = 0;
    for (final row in rows) {
      if (_disposed) break;
      if (canDispatch != null && !canDispatch!(row)) continue;
      if (!_inFlight.add(row.localId)) continue;
      var timedOut = false;
      try {
        if (!await _authorize(row, claimed: false) || _disposed) continue;
        final sending = sender.send(row);
        final eventId = await sending.timeout(operationTimeout, onTimeout: () {
          timedOut = true;
          // The live sender still owns its claim. Do not release that
          // claim or dispatch the same request while its outcome is unknown.
          unawaited(sending
              .then<void>((_) {}, onError: (Object _) {})
              .whenComplete(() => _inFlight.remove(row.localId)));
          return '';
        });
        if (eventId.isEmpty) {
          continue;
        }
        _dispatched++;
        sent++;
      } catch (error) {
        // 行内状态由会话的发送状态机与 outbox 日志落定；这里只把网络事实
        // 上报给网络状态机，让恢复信号照常产生。
        if (defaultNetworkFailureClassifier(error)) {
          _reportFailure(error);
        }
      } finally {
        if (!timedOut) _inFlight.remove(row.localId);
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
    if (!_openingRooms.add(roomId)) return 0;
    OutboxLease? lease;
    var acquisitionExpired = false;
    try {
      final acquiring = factory(roomId);
      unawaited(acquiring.then<void>((value) async {
        if (acquisitionExpired) await _release(value);
      }, onError: (Object _) {}).whenComplete(
          () => _openingRooms.remove(roomId)));
      lease = await acquiring.timeout(operationTimeout, onTimeout: () {
        acquisitionExpired = true;
        throw TimeoutException(
            'Outbox room acquisition timed out', operationTimeout);
      });
    } catch (error) {
      if (!acquisitionExpired) _openingRooms.remove(roomId);
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
          sent += await _dispatchViaRoomSender(
              live, rows.sublist(rows.indexOf(row)));
          break;
        }
        if (canDispatch != null && !canDispatch!(row)) continue;
        if (!_inFlight.add(row.localId)) continue;
        final activeLease = lease!;
        final recoveryRevision = _recoveryRevision;
        var retryAfterSettlement = false;
        final sending = () async {
          try {
            // 原子认领：失败说明已被别的派发者认领/已送达。
            if (!await outbox.claim(row.localId)) return false;
            if (_disposed) {
              await outbox.updateStatus(row.localId, OutboxStatus.queued);
              return false;
            }
            if (!await _authorize(row, claimed: true)) return false;
            if (_disposed) {
              await outbox.updateStatus(row.localId, OutboxStatus.queued);
              return false;
            }
            final eventId = await activeLease.send(row.content, row.txid);
            if (eventId.isEmpty) {
              throw StateError('Matrix event was not accepted');
            }
            await outbox.updateStatus(row.localId, OutboxStatus.sent);
            await outbox.removeOrArchive(row.localId);
            _dispatched++;
            return true;
          } catch (error) {
            // 网络问题 → 等待网络（自动续发）；服务端明确拒绝 → failed。
            final networkFailure = defaultNetworkFailureClassifier(error);
            await outbox.updateStatus(
              row.localId,
              networkFailure
                  ? OutboxStatus.waitingNetwork
                  : OutboxStatus.failed,
              lastError: error.toString(),
            );
            retryAfterSettlement = networkFailure &&
                recoveryRevision != _recoveryRevision &&
                _networkUsable;
            // A recovery observed after this request began supersedes its
            // stale transport failure. Consume that edge once after settlement.
            if (networkFailure && !retryAfterSettlement) _reportFailure(error);
            return false;
          } finally {
            _inFlight.remove(row.localId);
            if (retryAfterSettlement && !_disposed) unawaited(drain());
          }
        }();
        final outcome = await sending
            .then<bool?>((value) => value)
            .timeout(operationTimeout, onTimeout: () => null);
        if (outcome == null) {
          // Keep the row sending until the original request settles. A timeout
          // only frees this scheduler to service other rooms, never the claim.
          lease = null;
          unawaited(sending.whenComplete(() => _release(activeLease)));
          break;
        }
        if (outcome) sent++;
      }
    } finally {
      if (lease != null) await _release(lease);
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
      _reportFailure(error);
    }
  }

  void _reportFailure(Object error) {
    _reportingFailure = true;
    try {
      networkState?.reportFailure(error);
    } finally {
      _reportingFailure = false;
    }
  }

  Future<bool> _authorize(OutboxMessage row, {required bool claimed}) async {
    final authorize = authorizeSend;
    if (authorize == null) return true;
    var reason = 'send_authorization_denied';
    var status = OutboxStatus.failed;
    try {
      if (await authorize(row).timeout(operationTimeout)) return true;
    } catch (error) {
      // Do not store exception text: authority errors can contain private data.
      reason = 'send_authorization_unavailable';
      if (defaultNetworkFailureClassifier(error)) {
        status = OutboxStatus.waitingNetwork;
        _reportFailure(error);
      }
    }
    // A registered page sender owns claiming on its successful path. On denial,
    // claim only a still-pending row so another dispatcher's live claim is safe.
    if (claimed ||
        await outbox.claim(row.localId, from: const {
          OutboxStatus.queued,
          OutboxStatus.waitingNetwork,
        })) {
      await outbox.updateStatus(row.localId, status, lastError: reason);
    }
    return false;
  }

  Future<void> _release(OutboxLease lease) async {
    try {
      await lease.release().timeout(operationTimeout);
    } catch (_) {
      // Resource teardown must not block unrelated rooms or replace send state.
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
