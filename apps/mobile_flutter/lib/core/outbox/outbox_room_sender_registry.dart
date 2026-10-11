import 'dart:async';

import 'outbox_message.dart';

/// 一个**当前打开着**的房间会话的发送句柄。
///
/// 由 `RoomPage` 在时间线就绪时注册、页面销毁时注销。调度器只把行交给
/// 已经打开的会话；它自己**绝不**打开房间、申请租约或创建定时器——
/// 房间打开路径仍由既有的 `RoomOpeningPolicy` / `RoomNavigationCoordinator`
/// 唯一拥有。
abstract interface class OutboxSender {
  String get roomId;

  /// 租约是否仍然有效、时间线是否可用。
  bool get canSend;

  /// 复用行内 txid 发送；成功返回服务端 event id。
  Future<String> send(OutboxMessage message);
}

/// Optional ownership bridge for senders with a shorter UI observation future.
/// A pending future must complete only after the underlying transport settles,
/// including after local cancellation, row deletion or page disposal.
abstract interface class OutboxTransportSettlement {
  Future<void>? pendingTransportSettlement(String transactionId);

  /// Includes foreground sends whose durable rows may already be removed.
  Future<void>? get pendingRoomTransportSettlement;
}

/// 已打开房间的发送句柄注册表（按 roomId 去重）。
final class OutboxRoomSenderRegistry {
  OutboxRoomSenderRegistry();

  static final OutboxRoomSenderRegistry shared = OutboxRoomSenderRegistry();

  final Map<String, OutboxSender> _senders = <String, OutboxSender>{};
  final Map<String, Set<Future<void>>> _detachedSettlements = {};

  int get length => _senders.length;

  /// 同一房间后注册的句柄覆盖先前的（页面重建），先前的注销不会误删新的。
  void register(OutboxSender sender) {
    final previous = _senders[sender.roomId];
    if (previous != null && !identical(previous, sender)) {
      _retainSettlement(previous);
    }
    _senders[sender.roomId] = sender;
  }

  void unregister(OutboxSender sender) {
    if (identical(_senders[sender.roomId], sender)) {
      _retainSettlement(sender);
      _senders.remove(sender.roomId);
    }
  }

  /// 房间当前是否有一个可发送的句柄；不可发送（租约取消/页面销毁）按
  /// "没有句柄"处理，调度器会保留该行等待下一次进入会话。
  OutboxSender? senderFor(String roomId) {
    final sender = _senders[roomId];
    if (sender == null || !sender.canSend) return null;
    return sender;
  }

  /// Transport ownership is independent of whether a page can still send.
  /// Unregistered/replaced pages retain only their actual settlement futures.
  Map<String, Future<void>> pendingRoomTransportSettlements() => {
        for (final room in {..._senders.keys, ..._detachedSettlements.keys})
          if (pendingRoomTransportSettlement(room) case final pending?)
            room: pending,
      };

  Future<void>? pendingRoomTransportSettlement(String roomId) {
    final sender = _senders[roomId];
    final current = sender is OutboxTransportSettlement
        ? (sender as OutboxTransportSettlement).pendingRoomTransportSettlement
        : null;
    final pending = [
      ...?_detachedSettlements[roomId],
      if (current != null) current,
    ];
    return pending.isEmpty ? null : Future.wait(pending).then<void>((_) {});
  }

  void _retainSettlement(OutboxSender sender) {
    if (sender is! OutboxTransportSettlement) return;
    final pending =
        (sender as OutboxTransportSettlement).pendingRoomTransportSettlement;
    if (pending == null) return;
    final roomId = sender.roomId;
    final retained = _detachedSettlements.putIfAbsent(roomId, () => {});
    if (!retained.add(pending)) return;
    void release() {
      retained.remove(pending);
      if (retained.isEmpty &&
          identical(_detachedSettlements[roomId], retained)) {
        _detachedSettlements.remove(roomId);
      }
    }

    unawaited(pending.then<void>((_) => release(),
        onError: (Object _, StackTrace __) => release()));
  }

  void clear() {
    for (final sender in _senders.values) {
      _retainSettlement(sender);
    }
    _senders.clear();
  }
}
