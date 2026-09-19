import 'package:flutter/foundation.dart';

/// 红包领取明细的**会话级（进程内）**缓存。
///
/// 微信级加载模型要求「本地优先 → 立即展示 → 后台同步 → 失败不覆盖」。
/// 明细页每次进入都会新建一个 `RedPacketController` 重新请求详情，于是从聊天
/// 财务卡片再点进去一次也要先看一次整页加载圈，断网时直接变成"红包详情加载失败"。
/// 这里把本次会话已经成功拿到的明细留在内存里，再次进入先渲染、再后台刷新。
///
/// 设计取舍（重要，勿随意改成落盘）：
/// - **只放内存、不落盘**：明细包含群成员各自的领取金额，属于第三方资金展示数据；
///   仓库的本地持久化缓存（`CacheRepository`）明确排除资金与凭据，因此这里
///   只做会话内复用，进程结束即消失，不写 SharedPreferences / SQLite。
/// - **按会话 epoch + 红包 id 隔离**：登录态切换后 `sessionEpoch` 变化，
///   上一个账号的明细不会被复用，明细绝不跨账号展示。
/// - **只给只读明细页用**：领取/拆红包弹窗仍走服务端实时状态，避免缓存里
///   过期的 `OPEN` 误导用户去点"领取"（资金动作以服务端为准）。
final class RedPacketDetailStore {
  RedPacketDetailStore({this.maxEntries = 20});

  /// 最多保留多少个红包的明细（会话内 LRU，防止长时间使用后无限增长）。
  final int maxEntries;

  final Map<String, Map<String, dynamic>> _entries = {};

  String _key(String scope, String packetId) => '$scope|$packetId';

  /// 同步读取：页面首帧就要用。
  Map<String, dynamic>? read(String scope, String packetId) =>
      _entries[_key(scope, packetId)];

  /// 写入并做容量淘汰（最早写入的先淘汰）。
  void write(String scope, String packetId, Map<String, dynamic> detail) {
    final key = _key(scope, packetId);
    _entries.remove(key);
    _entries[key] = detail;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() => _entries.clear();

  @visibleForTesting
  int get entryCount => _entries.length;

  @visibleForTesting
  Iterable<String> get keys => _entries.keys;
}

/// 进程级共享实例：明细页默认取用；测试可注入或重置。
final class RedPacketDetailStores {
  RedPacketDetailStores._();

  static RedPacketDetailStore _shared = RedPacketDetailStore();

  static RedPacketDetailStore get shared => _shared;

  @visibleForTesting
  static void reset() => _shared = RedPacketDetailStore();

  @visibleForTesting
  static set shared(RedPacketDetailStore value) => _shared = value;
}
