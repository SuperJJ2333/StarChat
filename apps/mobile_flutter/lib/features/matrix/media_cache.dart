import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// 解密媒体本地缓存：以 (roomId, eventId) 为键落盘于应用文档目录
/// chat-media/。
///
/// 完整性与容量治理（审计 M03/M04）：
/// - **原子写**：先写同目录唯一临时文件，校验长度元数据后 rename 到
///   最终路径——进程中止/磁盘满不会留下"看似命中"的半文件；
/// - **损坏检测**：`.len` 元数据记录字节数；命中时长度不符即判损坏，
///   删除缓存与元数据按未命中处理（重下载闭环）；无元数据的旧条目
///   （历史数据）按有效接受，不制造假未命中；
/// - **写入合并**：同键并发写共享一次落盘；
/// - **磁盘配额**：chat-media 仅存"可重新下载"的解密副本（键=事件 ID，
///   永可重新拉取），超过硬配额按 LRU（最后修改时间）回收到软配额，
///   不触碰用户唯一文件（相册原件不在本目录）。
final class MediaCache {
  MediaCache._();

  /// 磁盘软/硬配额（字节）：超硬回收至软以下。
  static const diskSoftQuotaBytes = 384 * 1024 * 1024;
  static const diskHardQuotaBytes = 512 * 1024 * 1024;

  /// 同键在途写合并。
  static final _storeFlights = <String, Future<File>>{};

  /// 文件系统安全段：Matrix ID 含 `!` `:` `$/` 等非法路径字符
  /// （Windows 全平台禁止），清洗后追加短散列防不同 ID 清洗碰撞。
  static String _safeSegment(String id) {
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final digest = md5.convert(id.codeUnits).toString().substring(0, 8);
    return '${safe}_$digest';
  }

  static Future<Directory> _dirFor(String roomId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}chat-media'
        '${Platform.pathSeparator}${_safeSegment(roomId)}');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _fileFor(String roomId, String eventId) async {
    final dir = await _dirFor(roomId);
    return File(
        '${dir.path}${Platform.pathSeparator}${_safeSegment(eventId)}');
  }

  /// 长度元数据（`.len`）：损坏检测依据。
  static File _metaFor(File file) => File('${file.path}.len');

  /// 已缓存则返回本地文件（含完整性校验），否则返回 null。
  ///
  /// 损坏（长度不符）：删除数据与元数据，按未命中返回——调用方会重新
  /// 下载解密并经 [store] 修复缓存。
  static Future<File?> cached(String roomId, String eventId) async {
    final file = await _fileFor(roomId, eventId);
    if (!await file.exists()) return null;
    final meta = _metaFor(file);
    if (await meta.exists()) {
      try {
        final expected = int.tryParse(await meta.readAsString());
        if (expected != null) {
          final actual = await file.length();
          if (actual != expected) {
            // 半写入/截断/磁盘错：损坏项删除后可重新获取。
            await _deleteQuietly(file);
            await _deleteQuietly(meta);
            return null;
          }
        }
      } catch (_) {
        // 元数据不可读：按未命中重下（保守），并清掉坏缓存。
        await _deleteQuietly(file);
        await _deleteQuietly(meta);
        return null;
      }
    }
    return file;
  }

  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete();
    } catch (_) {}
  }

  /// 解密数据写入缓存并返回文件（同键并发写合并为一次落盘）。
  static Future<File> store(
      String roomId, String eventId, Uint8List bytes) async {
    final flightKey = '$roomId\u0000$eventId';
    final existing = _storeFlights[flightKey];
    if (existing != null) return existing;
    final flight = _storeAtomic(roomId, eventId, bytes);
    _storeFlights[flightKey] = flight;
    try {
      return await flight;
    } finally {
      _storeFlights.remove(flightKey);
    }
  }

  static Future<File> _storeAtomic(
      String roomId, String eventId, Uint8List bytes) async {
    final file = await _fileFor(roomId, eventId);
    final tmp = File('${file.path}.${const Uuid().v4()}.tmp');
    try {
      // ① 同目录唯一临时文件写完并落盘（同目录 rename 具原子性）。
      await tmp.writeAsBytes(bytes, flush: true);
      // ② 元数据先行：rename 窗口内任何中断都会以"长度不符"暴露，
      //    不会把半文件当命中。
      await _metaFor(file).writeAsString('${bytes.length}', flush: true);
      // ③ 原子替换（Windows rename 不覆盖已存在目标：先删旧再换，
      //    窗口内旧条目缺失=未命中→重下，安全）。
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      await tmp.rename(file.path);
    } catch (_) {
      await _deleteQuietly(tmp);
      rethrow;
    }
    // ④ 磁盘配额治理（尽力而为，不影响写入结果）。
    await _enforceDiskQuota(keep: file);
    return file;
  }

  /// 超硬配额时按 LRU 回收可再下载副本至软配额以下。
  static Future<void> _enforceDiskQuota({required File keep}) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = Directory('${docs.path}${Platform.pathSeparator}chat-media');
      if (!await root.exists()) return;
      final files = <File>[];
      var total = 0;
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (entity.path.endsWith('.len') || entity.path.endsWith('.tmp')) {
          continue;
        }
        files.add(entity);
        total += await entity.length();
      }
      if (total <= diskHardQuotaBytes) return;
      files.sort((a, b) => a.modifiedSyncOrDefault().compareTo(b.modifiedSyncOrDefault()));
      for (final candidate in files) {
        if (total <= diskSoftQuotaBytes) break;
        if (candidate.path == keep.path) continue;
        final length = await candidate.length();
        await _deleteQuietly(candidate);
        await _deleteQuietly(_metaFor(candidate));
        total -= length;
      }
    } catch (_) {
      // 配额治理失败不影响已完成的写入。
    }
  }

  /// 列出指定房间的全部缓存键（clearAll 枚举用）。
  /// 键 = 文件名去掉 `.len` 后缀后的原始段（即调用方传入的 cacheKey）。
  static Future<List<String>> listCachedKeys(String roomId) async {
    try {
      final dir = await _dirFor(roomId);
      final keys = <String>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.endsWith('.len') || name.endsWith('.tmp')) continue;
        keys.add(name);
      }
      return keys;
    } catch (_) {
      return const [];
    }
  }

  /// 当前缓存用量（字节；供设置页展示）。
  static Future<int> totalCachedBytes() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = Directory('${docs.path}${Platform.pathSeparator}chat-media');
      if (!await root.exists()) return 0;
      var total = 0;
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is File && !entity.path.endsWith('.len')) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}

extension _FileStatOrNull on File {
  /// stat 失败（并发删除等）按最旧处理，不中断配额回收。
  DateTime modifiedSyncOrDefault() {
    try {
      return statSync().modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }
}

/// 会话页内存级媒体缓存：按 eventId 保存已解密字节，命中时同步返回，
/// 彻底避免列表滚动过程中对同一消息重复解密/读盘触发重建与抽动；
/// 相同实例也保证 Image.memory 的解码缓存按身份命中，重建不重复解码。
/// 并发加载按 eventId 去重（在途 Future 复用）。
///
/// M04：LRU 同时受**字节预算**与条目上限约束——大视频按实际字节数
/// 加权，不再出现"3 条 4K 视频"式的条数掩盖内存失控；超预算从最旧
/// 条目开始回收。
final class MediaMemoryCache {
  MediaMemoryCache({
    this.maxEntries = 48,
    this.maxBytes = 64 * 1024 * 1024,
  });

  final int maxEntries;
  final int maxBytes;

  final _entries = <String, Uint8List>{};
  final _inFlight = <String, Future<Uint8List>>{};
  int _totalBytes = 0;

  /// 当前内存占用（字节；诊断/测试）。
  int get totalBytes => _totalBytes;

  Uint8List? get(String eventId) {
    final bytes = _entries.remove(eventId);
    if (bytes == null) return null;
    _entries[eventId] = bytes; // 刷新 LRU 访问顺序
    return bytes;
  }

  Future<Uint8List> putIfAbsent(
    String eventId,
    Future<Uint8List> Function() load,
  ) {
    final cached = get(eventId);
    if (cached != null) return SynchronousFuture<Uint8List>(cached);
    final existing = _inFlight[eventId];
    if (existing != null) return existing;
    final flight = load();
    _inFlight[eventId] = flight;
    // 成功转正式缓存并做字节加权 LRU 收缩；失败仅清除在途记录，允许
    // 后续重试（失败不占预算）。
    unawaited(flight.then(
      (bytes) {
        _inFlight.remove(eventId);
        final previous = _entries.remove(eventId);
        if (previous != null) _totalBytes -= previous.length;
        _entries[eventId] = bytes;
        _totalBytes += bytes.length;
        _evictToBudget();
      },
      onError: (_) {
        _inFlight.remove(eventId);
      },
    ));
    return flight;
  }

  void _evictToBudget() {
    while (_entries.isNotEmpty &&
        (_totalBytes > maxBytes || _entries.length > maxEntries)) {
      final oldestKey = _entries.keys.first;
      final removed = _entries.remove(oldestKey);
      if (removed != null) _totalBytes -= removed.length;
    }
  }
}

/// 解密并缓存媒体附件：优先命中本地缓存；未命中时调用 loader 解密、
/// 落盘后返回字节。
Future<Uint8List> loadMediaWithCache(
  MediaCacheKey key,
  Future<Uint8List> Function() decrypt,
) async {
  final cached = await MediaCache.cached(key.roomId, key.eventId);
  if (cached != null) return await cached.readAsBytes();
  final bytes = await decrypt();
  await MediaCache.store(key.roomId, key.eventId, bytes);
  return bytes;
}

/// 视频播放的页级共享内存缓存（在途去重 + LRU）；视频字节大，
/// 按字节预算（256MB）与条目上限双重约束，大视频优先经磁盘文件播放。
final videoMemoryCache = MediaMemoryCache(
  maxEntries: 6,
  maxBytes: 256 * 1024 * 1024,
);

/// 解析视频播放文件（E2E 修复：重复打开全量下载 + 临时文件泄漏）。
///
/// 顺序：磁盘缓存直读（零下载零解密）→ 内存在途去重下载解密 →
/// 落盘返回。播放器直接使用该缓存文件，不再复制到系统临时目录。
Future<File> resolveCachedVideoFile({
  required MediaCacheKey key,
  required Future<Uint8List> Function() decrypt,
  MediaMemoryCache? memoryCache,
}) async {
  final disk = await MediaCache.cached(key.roomId, key.eventId);
  if (disk != null) return disk;
  final bytes = await (memoryCache ?? videoMemoryCache)
      .putIfAbsent(key.eventId, () => loadMediaWithCache(key, decrypt));
  return (await MediaCache.cached(key.roomId, key.eventId)) ??
      await MediaCache.store(key.roomId, key.eventId, bytes);
}

final class MediaCacheKey {
  const MediaCacheKey({required this.roomId, required this.eventId});
  final String roomId;
  final String eventId;

  @override
  bool operator ==(Object other) =>
      other is MediaCacheKey &&
      other.roomId == roomId &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(roomId, eventId);
}
