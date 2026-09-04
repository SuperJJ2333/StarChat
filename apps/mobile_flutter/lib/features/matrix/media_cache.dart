import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 解密媒体本地缓存：以 (roomId, eventId) 为键落盘于应用文档目录
/// chat-media/。再次进入会话时直接读本地文件（毫秒级），不再重复
/// 下载与解密；缓存仅追加，从不自动清除用户数据。
final class MediaCache {
  MediaCache._();

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

  /// 已缓存则返回本地文件，否则返回 null。
  static Future<File?> cached(String roomId, String eventId) async {
    final file = await _fileFor(roomId, eventId);
    return await file.exists() ? file : null;
  }

  /// 解密数据写入缓存并返回文件。
  static Future<File> store(
      String roomId, String eventId, Uint8List bytes) async {
    final file = await _fileFor(roomId, eventId);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}

/// 会话页内存级媒体缓存：按 eventId 保存已解密字节，命中时同步返回，
/// 彻底避免列表滚动过程中对同一消息重复解密/读盘触发重建与抽动；
/// 相同实例也保证 Image.memory 的解码缓存按身份命中，重建不重复解码。
/// 并发加载按 eventId 去重（在途 Future 复用）。LRU 上限控制内存占用。
final class MediaMemoryCache {
  MediaMemoryCache({this.maxEntries = 48});

  final int maxEntries;
  final _entries = <String, Uint8List>{};
  final _inFlight = <String, Future<Uint8List>>{};

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
    // 成功转正式缓存并做 LRU 收缩；失败仅清除在途记录，允许后续重试。
    unawaited(flight.then(
      (bytes) {
        _inFlight.remove(eventId);
        _entries[eventId] = bytes;
        while (_entries.length > maxEntries) {
          _entries.remove(_entries.keys.first);
        }
      },
      onError: (_) {
        _inFlight.remove(eventId);
      },
    ));
    return flight;
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
/// 条目上限远小于图片缓存。
final videoMemoryCache = MediaMemoryCache(maxEntries: 3);

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
