import 'package:shared_preferences/shared_preferences.dart';

/// 最近转发目标（“选择聊天”页首屏“最近转发”横排区）：
/// 本地持久化最近转发过的会话 id，按最近使用排序，最多保留 10 个。
final class RecentForwardStore {
  RecentForwardStore(this._prefs);

  static const _key = 'recent-forward-room-ids';
  static const maxEntries = 10;

  final SharedPreferences _prefs;

  List<String> load() => _prefs.getStringList(_key) ?? const [];

  /// 把本次转发的目标（第一个为最后使用）插入队首并去重、截断。
  Future<void> record(List<String> roomIds) async {
    if (roomIds.isEmpty) return;
    final previous = load();
    final next = <String>[];
    for (final id in roomIds) {
      if (!next.contains(id)) next.add(id);
    }
    for (final id in previous) {
      if (!next.contains(id) && !roomIds.contains(id)) next.add(id);
    }
    await _prefs.setStringList(_key, next.take(maxEntries).toList());
  }

}
