import 'package:shared_preferences/shared_preferences.dart';

/// 统计助手会话状态缓存：按会话（Matrix room.id）隔离读写清理。
///
/// 存储归宿主（Flutter）持有，WebView 是瞬态 UI——因此删除会话时能可靠清理。
/// key 形如 `stats.tool.v2.<roomId>`（前缀 + conversationId，同 `announcement-read` 先例）。
abstract final class StatisticsStateStore {
  static String _key(String roomId) => 'stats.tool.v2.$roomId';

  /// 读取某会话的统计工具状态 JSON；无缓存返回 null。
  static Future<String?> read(String roomId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key(roomId));
  }

  /// 写入某会话的统计工具状态 JSON。
  static Future<void> write(String roomId, String json) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(roomId), json);
  }

  /// 清理某会话的统计工具缓存（删除会话时调用）。
  static Future<void> clear(String roomId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(roomId));
  }
}
