import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/performance_trace.dart';
import 'media_load_scheduler.dart';
import 'video_poster_diagnostics.dart';
import 'video_poster_extractor.dart';
import 'video_poster_session_cache.dart';

/// 视频封面来源（优先级顺序即本枚举的声明顺序）。
///
/// **结构性保证**：枚举里没有「远端视频下载」这一项——封面流水线不存在
/// 任何视频下载依赖，因此「为了封面下载完整视频」在类型层面不可能发生。
enum VideoPosterSource {
  /// 会话内存 LRU（最快）。
  memory('memory'),

  /// 会话/持久磁盘缓存。
  disk('disk'),

  /// 服务端已有 poster：消息事件自带的加密缩略图附件（≤480px 小图）。
  server('server'),

  /// 本地视频抽帧：**仅当本地已存在视频文件**（自己发的 / 已离线缓存 /
  /// 此前播放已落盘的），绝不为了抽帧下载远端视频。
  localFrame('local_frame'),

  /// 占位图（前端 videocam 占位底）：没有封面可用，等待后续时机。
  placeholder('placeholder');

  const VideoPosterSource(this.label);

  final String label;
}

/// 本地抽帧候选时间点：跳过近黑片头。
///
/// 不复用发送端 `extractVideoPoster` 的默认列表——那个默认列表首项是
/// `0ms` 且命中即返回（会拿到黑帧）。加载侧追求「一眼能看出内容」，
/// 因此显式用带黑帧判定的时间点。
const List<int> kLocalVideoPosterFramePositions = [200, 500, 1000, 2000];

/// 会话缓存键的规格位（语义变更时升级，避免复用旧语义条目）。
const String chatVideoPosterSpec = 'chat-poster-v2';

/// 本机持久封面缓存的「虚拟事件 ID」。
///
/// 复用 `MediaCache`（账号命名空间 `chat-media/v2/<sha256(account)>` +
/// 内容寻址 `objects/<sha256>` + `refs/` 引用 + mtime LRU 配额），因此
/// 封面自动获得：多账号隔离、跨房间同字节去重、落盘上限与账号级清理。
String videoPosterCacheRefId(String mediaId) => '$mediaId#video-poster-v1';

typedef VideoPosterExtractor = Future<Uint8List?> Function(
    File file, void Function(int micros)? onFrameDecoded);

/// 一次封面解析的结果。
@immutable
final class VideoPosterOutcome {
  const VideoPosterOutcome({
    required this.bytes,
    required this.source,
    required this.cacheHit,
    this.generateMs = 0,
    this.decodeMs = 0,
    this.retryable = false,
    this.reason,
  });

  const VideoPosterOutcome.placeholder({this.reason, this.retryable = false})
      : bytes = null,
        source = VideoPosterSource.placeholder,
        cacheHit = false,
        generateMs = 0,
        decodeMs = 0;

  final Uint8List? bytes;
  final VideoPosterSource source;

  /// 命中已有缓存（内存/磁盘）而非本次新生成。
  final bool cacheHit;

  /// 生成阶段耗时（服务端取图 / 读磁盘 / 本地抽帧）。
  final int generateMs;

  /// 近黑帧判定所用的解码耗时（仅本地抽帧 > 0）。
  final int decodeMs;

  /// **恒为 0**：封面路径不下载视频（类型层面无下载入口）。
  int get downloadBytes => 0;

  final bool retryable;
  final String? reason;

  bool get hasPoster => bytes != null && bytes!.isNotEmpty;

  @override
  String toString() =>
      'VideoPosterOutcome(source: ${source.label}, cacheHit: $cacheHit, '
      'generateMs: $generateMs, decodeMs: $decodeMs, reason: $reason)';
}

/// 视频封面流水线（Phase 1）。
///
/// 解析顺序：
/// ```
/// ① 会话内存 LRU / 会话磁盘（VideoPosterSessionCache：单飞 + LRU，复用）
/// ② 服务端 poster（事件缩略图附件；只有小图）
/// ③ 本机持久封面缓存（MediaCache 账号命名空间 + 配额 LRU）
/// ④ 本地视频抽帧（仅当本地已存在视频文件）
/// ⑤ 占位图（无封面可用）
/// ```
///
/// 关键不变量：
/// - **绝不为了封面下载视频**：构造参数里没有任何下载入口，
///   [findLocalVideoFile] 只做「本地是否已有文件」的探测；
/// - 生成任务受**可见性门控**（调用方只在可见/即将可见时调用）与
///   `mediaLoadScheduler`（`isVideo: true` → 全局并发 1）双重约束；
/// - 同一媒体并发解析共享一次生成（`VideoPosterSessionCache` 单飞）；
/// - 生成失败有冷却（[retryCooldown]），避免滚动时反复调用原生抽帧。
final class VideoPosterPipeline {
  VideoPosterPipeline({
    required this.accountId,
    required this.roomId,
    required VideoPosterSessionCache memory,
    required Future<Uint8List?> Function(String mediaId) loadServerPoster,
    required Future<Uint8List?> Function(String mediaId) readCachedPoster,
    required Future<void> Function(String mediaId, Uint8List bytes)
        writeCachedPoster,
    required Future<File?> Function(String mediaId) findLocalVideoFile,
    VideoPosterExtractor? extract,
    this.diagnostics,
    PerformanceTraceRecorder? performanceRecorder,
    this.retryCooldown = const Duration(seconds: 20),
    this.serverTimeout = const Duration(seconds: 6),
    DateTime Function()? now,
  })  : _memory = memory,
        _loadServerPoster = loadServerPoster,
        _readCachedPoster = readCachedPoster,
        _writeCachedPoster = writeCachedPoster,
        _findLocalVideoFile = findLocalVideoFile,
        _extract = extract ?? _defaultExtract,
        _performanceRecorder =
            performanceRecorder ?? PerformanceTraceRecorder.instance,
        _now = now ?? DateTime.now;

  final String accountId;
  final String roomId;
  final VideoPosterSessionCache _memory;
  final Future<Uint8List?> Function(String mediaId) _loadServerPoster;
  final Future<Uint8List?> Function(String mediaId) _readCachedPoster;
  final Future<void> Function(String mediaId, Uint8List bytes)
      _writeCachedPoster;
  final Future<File?> Function(String mediaId) _findLocalVideoFile;
  final VideoPosterExtractor _extract;
  final VideoPosterDiagnostics? diagnostics;
  final PerformanceTraceRecorder _performanceRecorder;

  /// 抽帧失败后的冷却：冷却期内同一媒体不再探测/抽帧（走占位）。
  final Duration retryCooldown;

  /// 服务端 poster 附件的取图超时（不影响视频播放路径）。
  final Duration serverTimeout;

  final DateTime Function() _now;

  static Future<Uint8List?> _defaultExtract(
          File file, void Function(int micros)? onFrameDecoded) =>
      extractVideoPoster(file.path,
          positionsMs: kLocalVideoPosterFramePositions,
          onFrameDecoded: onFrameDecoded);

  /// 诊断归属表（有界）：cacheKey → 本次生成真实使用的来源。
  static const int _maxRecords = 128;
  final Map<String, VideoPosterSource> _sources = {};
  final Map<String, int> _generateMs = {};
  final Map<String, int> _decodeMs = {};
  final Map<String, DateTime> _attemptedAt = {};

  /// 统计（测试/证据用）。
  int memoryHits = 0;
  int diskHits = 0;
  int serverHits = 0;
  int localFrameGenerations = 0;
  int placeholders = 0;
  int extractionFailures = 0;
  int localFileProbes = 0;

  /// **恒为 0**：封面路径不下载任何视频字节。
  int get downloadBytes => 0;

  String keyFor(String mediaId, {String spec = chatVideoPosterSpec}) =>
      VideoPosterSessionCache.keyFor(
        accountId: accountId,
        roomId: roomId,
        mediaId: mediaId,
        // Matrix 事件不可变；媒体替换会产生新的 eventId。
        mediaVersion: mediaId,
        spec: spec,
      );

  /// 解析封面。[forceGenerate] 用于「视频刚播放完，本地已有文件」的补生成。
  Future<VideoPosterOutcome> resolve(
    String mediaId, {
    MediaLoadPriority priority = MediaLoadPriority.visible,
    bool forceGenerate = false,
    PerformanceTrace? trace,
  }) async {
    final ownedTrace = trace == null && _performanceRecorder.recordingEnabled
        ? _performanceRecorder.start(PerformanceOperationType.videoPoster)
        : null;
    final activeTrace = trace ?? ownedTrace;
    activeTrace?.setMedia(type: PerformanceMediaType.video);
    var cancelled = false;
    try {
      if (mediaId.isEmpty) {
        final outcome =
            const VideoPosterOutcome.placeholder(reason: 'empty_media_id');
        activeTrace?.setMedia(source: PerformanceCacheSource.miss);
        ownedTrace?.finish();
        return outcome;
      }
      final key = keyFor(mediaId);
      if (forceGenerate) _attemptedAt.remove(mediaId);
      final result = await _memory.load(
          key,
          () => _generate(key, mediaId, priority, forceGenerate, activeTrace,
              () => cancelled = true));
      final outcome = _outcomeFor(mediaId, key, result);
      activeTrace?.setMedia(
          source: switch (outcome.source) {
        VideoPosterSource.memory => PerformanceCacheSource.memory,
        VideoPosterSource.disk => PerformanceCacheSource.disk,
        VideoPosterSource.server => PerformanceCacheSource.serverPoster,
        VideoPosterSource.localFrame => PerformanceCacheSource.localFrame,
        VideoPosterSource.placeholder => PerformanceCacheSource.miss,
      });
      ownedTrace?.finish(
          result: cancelled || result.stale
              ? PerformanceResult.cancelled
              : PerformanceResult.success);
      return outcome;
    } catch (_) {
      ownedTrace?.finish(result: PerformanceResult.failed);
      rethrow;
    } finally {
      ownedTrace?.dispose();
    }
  }

  VideoPosterOutcome _outcomeFor(
      String mediaId, String key, VideoPosterResult result) {
    final bytes = result.bytes;
    // stale：在途生成完成时目标已被移除/会话已清理——绝不复活已删内容。
    if (bytes == null || bytes.isEmpty || result.stale) {
      placeholders++;
      final outcome = VideoPosterOutcome.placeholder(
          reason: result.reason ?? (result.stale ? 'stale' : 'no_poster'),
          retryable: result.retryable || result.stale);
      _record(mediaId, outcome);
      return outcome;
    }
    final source = result.fromMemory
        ? VideoPosterSource.memory
        : result.fromDisk
            ? VideoPosterSource.disk
            : (_sources[key] ?? VideoPosterSource.server);
    if (source == VideoPosterSource.memory) {
      memoryHits++;
    } else if (source == VideoPosterSource.disk) {
      diskHits++;
    }
    // cache_hit 语义：本次解析**没有生成新封面**，字节来自任一本机缓存层
    // （会话内存 LRU / 会话磁盘 / 本机持久封面缓存）。服务端 poster 与
    // 本地抽帧都算「本次解析路径」，不计入 cache_hit。
    final fromLocalCache = result.fromMemory ||
        result.fromDisk ||
        source == VideoPosterSource.memory ||
        source == VideoPosterSource.disk;
    final outcome = VideoPosterOutcome(
      bytes: bytes,
      source: source,
      cacheHit: fromLocalCache,
      generateMs: fromLocalCache ? 0 : (_generateMs[key] ?? 0),
      decodeMs: fromLocalCache ? 0 : (_decodeMs[key] ?? 0),
    );
    _record(mediaId, outcome);
    return outcome;
  }

  void _record(String mediaId, VideoPosterOutcome outcome) {
    diagnostics?.record(
      videoId: mediaId,
      source: outcome.source.label,
      cacheHit: outcome.cacheHit,
      generateMs: outcome.generateMs,
      decodeMs: outcome.decodeMs,
      downloadBytes: outcome.downloadBytes,
    );
  }

  Future<Uint8List?> _generate(
      String key,
      String mediaId,
      MediaLoadPriority priority,
      bool forceGenerate,
      PerformanceTrace? trace,
      void Function() onCancelled) async {
    final started = _now();

    // ① 服务端 poster：事件自带的加密缩略图附件（≤480px），**不是**视频。
    final server = await _attempt(() => _loadServerPoster(mediaId),
        timeout: serverTimeout);
    if (_hasBytes(server)) {
      serverHits++;
      _remember(key, VideoPosterSource.server, started, 0);
      return server;
    }

    // ② 本机持久封面缓存（含本地抽帧产物与账号命名空间）。
    trace?.mark(PerformanceStage.cacheLoadStarted);
    final cached = await _attempt(() => _readCachedPoster(mediaId));
    trace?.mark(PerformanceStage.cacheLoadDone);
    if (_hasBytes(cached)) {
      _remember(key, VideoPosterSource.disk, started, 0);
      return cached;
    }

    // ③ 本地抽帧：只在「本地已有视频文件」时进行；冷却期内不重复尝试。
    if (!forceGenerate) {
      final attempted = _attemptedAt[mediaId];
      if (attempted != null && _now().difference(attempted) < retryCooldown) {
        _remember(key, VideoPosterSource.placeholder, started, 0);
        return null;
      }
    }
    _attemptedAt[mediaId] = _now();
    _trimAttempts();
    localFileProbes++;
    final file = await _attempt(() => _findLocalVideoFile(mediaId));
    if (file == null) {
      // 没有本地文件 → 占位。**绝不**为了封面下载远端视频。
      _remember(key, VideoPosterSource.placeholder, started, 0);
      return null;
    }
    final timing = VideoPosterTiming();
    final bytes =
        await _extractBounded(key, file, priority, timing, trace, onCancelled);
    if (!_hasBytes(bytes)) {
      extractionFailures++;
      _remember(key, VideoPosterSource.placeholder, started, timing.decodeMs);
      return null;
    }
    localFrameGenerations++;
    // 写回持久缓存：下次直接命中（「生成后更新缓存」）。
    try {
      await _writeCachedPoster(mediaId, bytes!);
    } on Exception {
      // 磁盘满/权限等问题不阻断本次显示（内存已命中）。
    }
    _remember(key, VideoPosterSource.localFrame, started, timing.decodeMs);
    return bytes;
  }

  /// 抽帧走既有媒体调度器（`isVideo: true` → 全局视频并发上限），
  /// 避免首屏多行同时调用原生解码。
  Future<Uint8List?> _extractBounded(
      String key,
      File file,
      MediaLoadPriority priority,
      VideoPosterTiming timing,
      PerformanceTrace? trace,
      void Function() onCancelled) async {
    final lease = mediaLoadScheduler.request(
      'video-poster:$key',
      () async {
        final bytes = await _extract(file, timing.onFrameDecoded);
        if (bytes == null || bytes.isEmpty) {
          throw StateError('video poster extraction produced no frame');
        }
        return bytes;
      },
      priority: priority,
      isVideo: true,
      trace: trace,
    );
    try {
      return await lease.value;
    } on MediaLoadCanceled {
      onCancelled();
      return null;
    } on StateError {
      // 抽帧拿不到可用帧（全黑/解码失败）：可重试的占位，不是编程错误。
      return null;
    } on Exception {
      // 原生解码失败（容器不支持/文件忙）：同样是可重试占位。
      // 失败会通过诊断日志与 outcome.source=placeholder 对外可见。
      return null;
    }
  }

  void _remember(
      String key, VideoPosterSource source, DateTime started, int decodeMs) {
    _sources.remove(key);
    _sources[key] = source;
    _generateMs.remove(key);
    _generateMs[key] =
        _now().difference(started).inMilliseconds.clamp(0, 1 << 31);
    _decodeMs.remove(key);
    _decodeMs[key] = decodeMs;
    while (_sources.length > _maxRecords) {
      final oldest = _sources.keys.first;
      _sources.remove(oldest);
      _generateMs.remove(oldest);
      _decodeMs.remove(oldest);
    }
  }

  /// 撤回/删除某媒体：丢弃来源归属与冷却状态（缓存条目由调用方 evict）。
  ///
  /// 不做这一步的后果：1) 冷却会阻止撤回后重新出现的同 ID 内容立即生成；
  /// 2) 诊断里会残留已删除媒体的来源归属。
  void forget(String mediaId) {
    final key = keyFor(mediaId);
    _sources.remove(key);
    _generateMs.remove(key);
    _decodeMs.remove(key);
    _attemptedAt.remove(mediaId);
  }

  void _trimAttempts() {
    while (_attemptedAt.length > _maxRecords) {
      _attemptedAt.remove(_attemptedAt.keys.first);
    }
  }

  static bool _hasBytes(Uint8List? bytes) => bytes != null && bytes.isNotEmpty;

  /// 失败安全：服务端/磁盘/探测的异常都降级为「没有封面」，
  /// 失败原因保留在 outcome.reason 与诊断日志里（不静默吞掉语义）。
  Future<T?> _attempt<T>(Future<T?> Function() action,
      {Duration? timeout}) async {
    try {
      final pending = action();
      return timeout == null ? await pending : await pending.timeout(timeout);
    } on TimeoutException {
      return null;
    } on StateError {
      return null;
    } on Exception {
      return null;
    }
  }
}

/// 一次本地抽帧的耗时分段：抽帧内部回调 → pipeline → 诊断日志。
final class VideoPosterTiming {
  int decodeMs = 0;

  /// 近黑帧判定所用的解码耗时（微秒）。
  void onFrameDecoded(int micros) => decodeMs += micros ~/ 1000;
}
