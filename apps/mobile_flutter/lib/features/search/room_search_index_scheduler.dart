import 'dart:collection';

/// 单次时间线观察的结论。
class Observation {
  const Observation(this.toIndex, this.toRemove);
  final List<String> toIndex;
  final List<String> toRemove;
}

/// E1：会话页 → 全局搜索索引的**增量**调度（纯逻辑，可单测）。
///
/// 旧行为在每次时间线变化时把房间**全部**消息重建进索引（分配 + 排序
/// O(N log N)，UI 线程执行）——活跃群聊里每条新消息都触发一遍，低端机
/// 在键盘输入时直接卡死数秒。改为：
/// - 增量：只为未见过的消息产生索引/删除动作；
/// - echo 行（本地回显 txid）只登记不提交，等终态事件到达后再索引，
///   避免同一内容以 txid 与 eventId 重复入库；
/// - 已索引消息后被撤回 → 转入删除队列（撤回内容不得再被搜索到）；
/// - 已见集合有界，长会话不无限增长。
final class RoomSearchIndexScheduler {
  RoomSearchIndexScheduler({this.maxTrackedIds = 6000})
      : assert(maxTrackedIds > 0);

  final int maxTrackedIds;
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();

  /// [seenIds]：本次时间线全部消息标识（echo 也登记）。
  /// [indexableIds]：本次**新出现**且可索引（非撤回/非闪照/有文本）的 id。
  /// [recalledIds]：本次新观察到的撤回消息 id（含此前已索引的）。
  Observation observe({
    required Iterable<String> seenIds,
    required Set<String> indexableIds,
    required Set<String> recalledIds,
  }) {
    final toIndex = <String>[];
    for (final id in seenIds) {
      if (_seen.add(id)) {
        if (indexableIds.contains(id)) toIndex.add(id);
      }
    }
    _trim();
    final toRemove = <String>[];
    for (final id in recalledIds) {
      if (_seen.contains(id)) toRemove.add(id);
    }
    return Observation(toIndex, toRemove);
  }

  void reset() => _seen.clear();

  void _trim() {
    while (_seen.length > maxTrackedIds) {
      _seen.remove(_seen.first);
    }
  }
}
