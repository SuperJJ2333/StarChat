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

/// 已打开房间的发送句柄注册表（按 roomId 去重）。
final class OutboxRoomSenderRegistry {
  OutboxRoomSenderRegistry();

  static final OutboxRoomSenderRegistry shared = OutboxRoomSenderRegistry();

  final Map<String, OutboxSender> _senders = <String, OutboxSender>{};

  int get length => _senders.length;

  /// 同一房间后注册的句柄覆盖先前的（页面重建），先前的注销不会误删新的。
  void register(OutboxSender sender) {
    _senders[sender.roomId] = sender;
  }

  void unregister(OutboxSender sender) {
    if (identical(_senders[sender.roomId], sender)) {
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

  void clear() => _senders.clear();
}
