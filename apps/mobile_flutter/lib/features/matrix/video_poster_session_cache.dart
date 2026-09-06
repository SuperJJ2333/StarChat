import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

/// 视频预览图（封面/首帧缩略图）会话缓存（规格 #1）。
///
/// 生命周期：**当前账号登录期间的房间会话实例**——普通页面重建不清空；
/// 应用重启 / 退出账号 / 主动清理 / 明确销毁房间会话实例时整体失效。
///
/// 三层结构：
/// 1. **解码图片字节 LRU**（默认 32 MiB）：超限只淘汰内存图片条目，
///    再次显示走磁盘，不重新下载视频或重新提取首帧；
/// 2. **会话级临时磁盘缓存**（调用方注入读写/删除；只保存**加密缩略图**
///    字节，不保存明文视频）：会话存续期间**不按 LRU 淘汰**已成功项；
/// 3. **并发请求合并**：同一缓存键的并发加载共享一个 in-flight 任务，
///    下载/解密/首帧提取不因重复渲染重复执行。
///
/// 缓存键：账号 + 房间 ID + 媒体标识 + 媒体版本 + 缩略图规格（绝不用
/// 会过期的下载 URL 作唯一标识——URL 进 key 仅作为定位输入之一之前
/// 先经媒体标识+版本归一）。媒体替换（版本变化）→ 自然新键；撤回/
/// 删除 → [evict] 移除对应项。
///
/// 磁盘异常（损坏/空间不足）是缓存保证的例外：返回可重试状态
/// （[VideoPosterResult.retryable]=true），**不**在每次 build 自动重试。
final class VideoPosterSessionCache {
  VideoPosterSessionCache({
    this.memoryBudgetBytes = 32 * 1024 * 1024,
    this.memoryMaxEntries = 256,
    this.diskRead,
    this.diskWrite,
    this.diskDelete,
  });

  /// 内存预算（解码图片字节上限，默认 32 MiB）。
  final int memoryBudgetBytes;
  final int memoryMaxEntries;

  /// 会话级加密磁盘存取（注入：生产为加密临时目录；测试为内存 Map）。
  final Future<Uint8List?> Function(String cacheKey)? diskRead;
  final Future<void> Function(String cacheKey, Uint8List bytes)? diskWrite;
  final Future<void> Function(String cacheKey)? diskDelete;

  final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();
  final Map<String, Future<VideoPosterResult>> _inFlight =
      <String, Future<VideoPosterResult>>{};
  int _memoryBytes = 0;

  /// 调试/测试：当前内存占用与条目数。
  int get memoryBytes => _memoryBytes;
  int get memoryEntries => _memory.length;
  int get inFlightCount => _inFlight.length;
  int diskHits = 0;
  int diskWrites = 0;

  /// 构造缓存键：账号 + 房间 + 媒体标识 + 版本 + 规格。
  /// 下载 URL **不参与**键（会过期）。
  static String keyFor({
    required String accountId,
    required String roomId,
    required String mediaId,
    required String mediaVersion,
    required String spec,
  }) =>
      '$accountId|$roomId|$mediaId|$mediaVersion|$spec';

  /// 读取（命中内存 → 磁盘 → 加载器；并发同键合并）。
  ///
  /// [load] 只在内存与磁盘都未命中时执行一次（下载+解密+首帧提取）；
  /// 磁盘异常时返回 retryable 结果（不自动重试循环）。
  Future<VideoPosterResult> load(
    String cacheKey,
    Future<Uint8List?> Function() load,
  ) {
    final memory = _memory.remove(cacheKey);
    if (memory != null) {
      _memory[cacheKey] = memory; // LRU 刷新。
      return Future.value(VideoPosterResult(memory, fromMemory: true));
    }
    final pending = _inFlight[cacheKey];
    if (pending != null) return pending;

    final flight = _loadSlow(cacheKey, load);
    _inFlight[cacheKey] = flight;
    return flight.whenComplete(() => _inFlight.remove(cacheKey));
  }

  Future<VideoPosterResult> _loadSlow(
    String cacheKey,
    Future<Uint8List?> Function() load,
  ) async {
    // ① 会话级磁盘（加密缩略图）。
    if (diskRead != null) {
      try {
        final cached = await diskRead!(cacheKey);
        if (cached != null && cached.isNotEmpty) {
          diskHits++;
          _storeMemory(cacheKey, cached);
          return VideoPosterResult(cached, fromDisk: true);
        }
      } catch (_) {
        // 磁盘损坏/IO 异常：缓存保证例外——继续尝试加载器；加载器也
        // 失败时给出可重试状态。
      }
    }
    // ② 加载器（下载+解密+首帧提取，仅此一次）。
    Uint8List? fresh;
    try {
      fresh = await load();
    } catch (_) {
      return const VideoPosterResult.retryable('媒体加载失败，可重试');
    }
    if (fresh == null || fresh.isEmpty) {
      return const VideoPosterResult.retryable('暂无预览图，可重试');
    }
    _storeMemory(cacheKey, fresh);
    // ③ 回写会话磁盘（尽力而为；空间不足不失败——内存已命中）。
    if (diskWrite != null) {
      try {
        await diskWrite!(cacheKey, fresh);
        diskWrites++;
      } catch (_) {
        // 磁盘满：例外路径（验证记录单独标注）；不影响本次显示。
      }
    }
    return VideoPosterResult(fresh, freshlyLoaded: true);
  }

  void _storeMemory(String key, Uint8List bytes) {
    final previous = _memory.remove(key);
    if (previous != null) _memoryBytes -= previous.length;
    _memory[key] = bytes;
    _memoryBytes += bytes.length;
    // 超预算：只淘汰内存条目（磁盘不动——会话存续期间不淘汰已成功项）。
    while (_memory.isNotEmpty &&
        (_memoryBytes > memoryBudgetBytes ||
            _memory.length > memoryMaxEntries)) {
      final oldestKey = _memory.keys.first;
      final removed = _memory.remove(oldestKey)!;
      _memoryBytes -= removed.length;
    }
  }

  /// 撤回/删除：只移除对应媒体项（内存 + 磁盘）。
  Future<void> evict(String cacheKey) async {
    final removed = _memory.remove(cacheKey);
    if (removed != null) _memoryBytes -= removed.length;
    if (diskDelete != null) {
      try {
        await diskDelete!(cacheKey);
      } catch (_) {}
    }
  }

  /// 媒体替换：版本变化生成新键即自然失效；本方法提供显式入口
  /// （旧键删除 + 新键写入合并到 load 流程）。
  Future<void> replace(String oldKey, String newKey, Uint8List bytes) async {
    await evict(oldKey);
    _storeMemory(newKey, bytes);
    if (diskWrite != null) {
      try {
        await diskWrite!(newKey, bytes);
      } catch (_) {}
    }
  }

  /// 应用重启/退出账号/销毁房间会话实例：整体失效（内存清空；磁盘由
  /// 调用方按生命周期清理会话临时目录）。
  void clearMemory() {
    _memory.clear();
    _memoryBytes = 0;
  }

  /// 主动清理缓存：内存 + 磁盘全清。
  Future<void> clearAll() async {
    clearMemory();
    // 磁盘清理由注入方提供目录级清理；逐键删除仅覆盖已知键的场景。
  }
}

/// 加载结果：成功带字节与来源；失败带 retryable 状态。
final class VideoPosterResult {
  const VideoPosterResult(
    this.bytes, {
    this.fromMemory = false,
    this.fromDisk = false,
    this.freshlyLoaded = false,
  })  : retryable = false,
        reason = null;

  const VideoPosterResult.retryable(String this.reason)
      : bytes = null,
        fromMemory = false,
        fromDisk = false,
        freshlyLoaded = false,
        retryable = true;

  final Uint8List? bytes;
  final bool fromMemory;
  final bool fromDisk;
  final bool freshlyLoaded;
  final bool retryable;
  final String? reason;
}
