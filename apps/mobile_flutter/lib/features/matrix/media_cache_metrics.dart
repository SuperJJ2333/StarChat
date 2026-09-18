import 'package:flutter/foundation.dart';

/// 本地媒体缓存性能指标（Phase 2）。
///
/// 进程内计数器，**无持久化、无网络、无 PII**：
/// 只记录字节数、耗时与计数，不记录用户 ID / 文件名 / roomId / eventId /
/// token / Matrix 密钥 / 聊天内容。需要标识时使用加盐 sha256 短指纹
/// （约定同 `VideoPosterDiagnostics.fingerprint`）。
final class MediaCacheMetrics {
  MediaCacheMetrics._();

  /// 是否记录耗时（字节计数始终累计，成本可忽略）。
  static bool enabled = kProfileMode ||
      const bool.fromEnvironment('CHATFLOW_PERFORMANCE_METRICS');

  // —— 耗时（微秒累计 + 次数）——
  static int cacheLookupMicros = 0;
  static int cacheLookups = 0;
  static int indexLookupMicros = 0;
  static int indexLookups = 0;
  static int evictionMicros = 0;
  static int evictions = 0;
  static int gcMicros = 0;
  static int gcRuns = 0;

  // —— 字节与对象 ——
  /// **为完整性校验而读取的字节数**。
  ///
  /// P0-1 的核心观测点：索引命中必须让本计数**零增长**
  /// （即不再为了一次"缓存命中"重读并哈希整个大文件）。
  static int hashBytesRead = 0;
  static int hashFilesVerified = 0;
  static int diskBytesRead = 0;
  static int diskBytesWritten = 0;
  static int indexHits = 0;
  static int indexMisses = 0;
  static int indexWrites = 0;
  static int touchFlushes = 0;
  static int touchedObjects = 0;
  static int evictedObjects = 0;
  static int evictedBytes = 0;
  static int gcCollectedObjects = 0;
  static int gcCollectedBytes = 0;
  static int pinnedPaths = 0;

  static void reset() {
    cacheLookupMicros = 0;
    cacheLookups = 0;
    indexLookupMicros = 0;
    indexLookups = 0;
    evictionMicros = 0;
    evictions = 0;
    gcMicros = 0;
    gcRuns = 0;
    hashBytesRead = 0;
    hashFilesVerified = 0;
    diskBytesRead = 0;
    diskBytesWritten = 0;
    indexHits = 0;
    indexMisses = 0;
    indexWrites = 0;
    touchFlushes = 0;
    touchedObjects = 0;
    evictedObjects = 0;
    evictedBytes = 0;
    gcCollectedObjects = 0;
    gcCollectedBytes = 0;
    pinnedPaths = 0;
  }

  static void recordLookup(Stopwatch? watch) {
    cacheLookups++;
    if (enabled && watch != null) cacheLookupMicros += watch.elapsedMicroseconds;
  }

  static void recordIndexLookup(Stopwatch? watch) {
    indexLookups++;
    if (enabled && watch != null) indexLookupMicros += watch.elapsedMicroseconds;
  }

  /// 一次完整性校验：整个文件都被读取并哈希。
  static void recordHash(int bytes) {
    hashFilesVerified++;
    hashBytesRead += bytes;
    diskBytesRead += bytes;
  }

  static void recordRead(int bytes) => diskBytesRead += bytes;

  static void recordWrite(int bytes) => diskBytesWritten += bytes;

  /// 只包含计数与字节数——可直接进日志/测试断言。
  static Map<String, Object?> snapshot() => {
        'cache_lookups': cacheLookups,
        'cache_lookup_ms': cacheLookupMicros ~/ 1000,
        'index_lookups': indexLookups,
        'index_lookup_ms': indexLookupMicros ~/ 1000,
        'index_hits': indexHits,
        'index_misses': indexMisses,
        'index_writes': indexWrites,
        'hash_files_verified': hashFilesVerified,
        'hash_bytes_read': hashBytesRead,
        'disk_bytes_read': diskBytesRead,
        'disk_bytes_written': diskBytesWritten,
        'touch_flushes': touchFlushes,
        'touched_objects': touchedObjects,
        'evictions': evictions,
        'eviction_ms': evictionMicros ~/ 1000,
        'evicted_objects': evictedObjects,
        'evicted_bytes': evictedBytes,
        'gc_runs': gcRuns,
        'gc_ms': gcMicros ~/ 1000,
        'gc_collected_objects': gcCollectedObjects,
        'gc_collected_bytes': gcCollectedBytes,
        'pinned_paths': pinnedPaths,
      };

  /// 单行诊断（字段固定、无 PII）。
  static String debugLine() => '[chatflow/mediacache] '
      '${snapshot().entries.map((entry) => '${entry.key}=${entry.value}').join(' ')}';
}
