import 'package:flutter/foundation.dart';

import 'room_timeline_controller.dart';

/// 会话消息 timeline 缓存（进程级、按账号 + 房间隔离、有界 LRU）。
///
/// 存在意义：引用消息（`m.in_reply_to`）的原消息可能远在当前 timeline
/// 窗口之外（例如 1000 条以前）。按 event_id 直接解析成功后，把**已解密
/// 投影**留在这里，重新进入同一会话时引用卡片立即命中，不再重复发起
/// 网络请求。
///
/// **E2EE 边界（重要）**：本缓存**只存内存，绝不落盘**。Matrix 明文只允许
/// 存在于设备内存与 SDK 的加密本地库（SQLCipher）中；把解密正文写进
/// SharedPreferences 或其它明文文件会削弱 E2EE 保证。跨进程恢复走 SDK
/// `Room.getEventById`（先查加密本地库，未命中才请求服务器）。
///
/// 账号隔离沿用 `RoomMentionStore` 的键约定（`<accountId>:<roomId>:<eventId>`），
/// 避免切换账号后读到上一账号房间的消息投影。
final class MessageTimelineCache {
  MessageTimelineCache._();

  static final MessageTimelineCache shared = MessageTimelineCache._();

  /// 默认容量：只保留最近解析过的引用目标；终局投影很小（无媒体字节）。
  static const int defaultCapacity = 256;

  final _entries = <String, RoomMessageViewModel>{};

  int get length => _entries.length;

  @visibleForTesting
  int get capacity => defaultCapacity;

  String _key(String accountId, String roomId, String eventId) =>
      '$accountId:$roomId:$eventId';

  RoomMessageViewModel? lookup(
          String accountId, String roomId, String eventId) =>
      _entries[_key(accountId, roomId, eventId)];

  /// 写入并提升为最近使用；超出容量时淘汰最久未使用的一条。
  void remember(String accountId, String roomId, RoomMessageViewModel message) {
    final key = _key(accountId, roomId, message.id);
    _entries.remove(key);
    _entries[key] = message;
    while (_entries.length > defaultCapacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 房间内消息被撤回/删除或本地历史被清空时，丢弃对应投影。
  void forget(String accountId, String roomId, String eventId) {
    _entries.remove(_key(accountId, roomId, eventId));
  }

  void clearRoom(String accountId, String roomId) {
    final prefix = '$accountId:$roomId:';
    _entries.removeWhere((key, _) => key.startsWith(prefix));
  }

  void clearAccount(String accountId) {
    final prefix = '$accountId:';
    _entries.removeWhere((key, _) => key.startsWith(prefix));
  }

  void clear() => _entries.clear();
}
