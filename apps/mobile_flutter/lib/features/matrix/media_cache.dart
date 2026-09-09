import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Device-only content objects. References and object identities never leave
/// this device. Each account has a separate namespace, including memory.
final class MediaCache {
  MediaCache._();
  static const diskSoftQuotaBytes = 384 * 1024 * 1024;
  static const diskHardQuotaBytes = 512 * 1024 * 1024;
  static final _storeFlights = <String, Future<File>>{};
  static final _objectFlights = <String, Future<File>>{};
  static final _legacyCleanups = <String, Future<void>>{};

  /// Legacy entries have no account owner. Discard only that managed cache;
  /// reusing them across accounts would cross the authorization boundary.
  static Future<void> discardLegacyCache() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/chat-media');
    return _legacyCleanups.putIfAbsent(root.path, () async {
      if (!await root.exists()) return;
      await for (final entry in root.list(followLinks: false)) {
        if (entry is! Directory) continue;
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (!RegExp(r'^[A-Za-z0-9._-]+_[a-f0-9]{8}$').hasMatch(name)) continue;
        // list() returns only direct children, and links are never followed.
        try {
          await entry.delete(recursive: true);
        } on FileSystemException { /* Retry on the next process start. */ }
      }
    });
  }

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static Future<Directory> _root(String accountId) async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/chat-media/v2/${_digest(accountId)}')
        .create(recursive: true);
  }

  static Future<File> _reference(
      String accountId, String roomId, String eventId) async {
    final root = await _root(accountId);
    final dir = await Directory('${root.path}/refs').create(recursive: true);
    return File('${dir.path}/${_digest(jsonEncode([roomId, eventId]))}.ref');
  }

  static Future<File?> cached(String roomId, String eventId,
      {String accountId = ''}) async {
    final ref = await _reference(accountId, roomId, eventId);
    try {
      if (!await ref.exists()) return null;
      final name = await ref.readAsString();
      if (!RegExp(r'^[a-f0-9]{64}(\.mp4|\.mov)?$').hasMatch(name)) return null;
      final root = await _root(accountId);
      final file = File('${root.path}/objects/$name');
      if (!await _valid(file)) return null;
      await file.setLastModified(DateTime.now());
      return file;
    } on FileSystemException {
      return null;
    }
  }

  static Future<bool> _valid(File file) async {
    try {
      if (!await file.exists()) return false;
      final expected =
          int.tryParse(await File('${file.path}.len').readAsString());
      if (expected != null && expected == await file.length()) return true;
    } on FileSystemException {/* Interrupted writes are cache misses. */}
    await _deleteQuietly(file);
    await _deleteQuietly(File('${file.path}.len'));
    return false;
  }

  static Future<void> _deleteQuietly(FileSystemEntity file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {/* Best effort cleanup. */}
  }

  static Future<void> _atomicBytes(File file, List<int> bytes) async {
    final tmp = File('${file.path}.${const Uuid().v4()}.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } finally {
      await _deleteQuietly(tmp);
    }
  }

  static Future<File> store(String roomId, String eventId, Uint8List bytes,
      {String accountId = ''}) async {
    final flightKey = _digest(jsonEncode([accountId, roomId, eventId]));
    final existing = _storeFlights[flightKey];
    if (existing != null) return existing;
    final flight = _root(accountId)
        .then((root) => _store(root, accountId, roomId, eventId, bytes));
    _storeFlights[flightKey] = flight;
    try {
      return await flight;
    } finally {
      _storeFlights.remove(flightKey);
    }
  }

  static Future<File> _store(Directory root, String accountId, String roomId,
      String eventId, Uint8List bytes) async {
    final digest = sha256.convert(bytes).toString();
    final name = '$digest${_videoContainerSuffix(bytes) ?? ''}';
    final objectKey = '${root.path}/objects/$name';
    final existing = _objectFlights[objectKey];
    final flight = existing ?? _storeObject(File(objectKey), bytes);
    if (existing == null) _objectFlights[objectKey] = flight;
    late File file;
    try {
      file = await flight;
    } finally {
      if (existing == null) _objectFlights.remove(objectKey);
    }
    final ref = await _reference(accountId, roomId, eventId);
    await _atomicBytes(ref, utf8.encode(name));
    await _enforceDiskQuota(file);
    return file;
  }

  static Future<File> _storeObject(File file, Uint8List bytes) async {
    await file.parent.create(recursive: true);
    if (await _valid(file)) return file;
    await _atomicBytes(
        File('${file.path}.len'), utf8.encode('${bytes.length}'));
    await _atomicBytes(file, bytes);
    return file;
  }

  static Future<File> preparePlaybackFile(String roomId, String eventId,
      {String accountId = ''}) async {
    final flightKey = _digest(jsonEncode([accountId, roomId, eventId]));
    final flight = _storeFlights[flightKey];
    if (flight != null) await flight;
    final file = await cached(roomId, eventId, accountId: accountId);
    if (file == null) throw FileSystemException('Video cache is unavailable');
    return file;
  }

  static String? _videoContainerSuffix(Uint8List header) {
    if (header.length < 16 ||
        String.fromCharCodes(header.sublist(4, 8)) != 'ftyp') {
      return null;
    }
    final brand = String.fromCharCodes(header.sublist(8, 12));
    if (brand == 'qt  ') return '.mov';
    if (RegExp(r'^iso[0-9m]$').hasMatch(brand) ||
        const {'mp41', 'mp42', 'avc1', 'M4V ', 'M4VH', 'M4VP', 'MSNV', 'dash'}
            .contains(brand)) {
      return '.mp4';
    }
    return null;
  }

  static bool _isData(File file) =>
      !file.path.endsWith('.len') &&
      !file.path.endsWith('.ref') &&
      !file.path.endsWith('.tmp');
  static Future<List<File>> _files() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/chat-media');
    if (!await root.exists()) return [];
    return root
        .list(recursive: true, followLinks: false)
        .where((e) => e is File && _isData(e))
        .cast<File>()
        .toList();
  }

  static Future<int> totalCachedBytes() async {
    var total = 0;
    for (final file in await _files()) {
      try {
        total += await file.length();
      } on FileSystemException {/* Concurrent eviction. */}
    }
    return total;
  }

  static Future<void> _enforceDiskQuota(File keep) async {
    try {
      final files = await _files();
      var total = 0;
      for (final file in files) {
        total += await file.length();
      }
      if (total <= diskHardQuotaBytes) return;
      files.sort((a, b) =>
          a.modifiedSyncOrDefault().compareTo(b.modifiedSyncOrDefault()));
      for (final file in files) {
        if (total <= diskSoftQuotaBytes) break;
        if (file.path == keep.path) continue;
        final size = await file.length();
        await file.delete();
        await _deleteQuietly(File('${file.path}.len'));
        total -= size;
      }
    } on FileSystemException {/* Cache quota maintenance is best effort. */}
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
  int _generation = 0;
  void clear() {
    _generation++;
    _entries.clear();
    _inFlight.clear();
    _totalBytes = 0;
  }

  /// 当前内存占用（字节；诊断/测试）。
  int get totalBytes => _totalBytes;

  /// Seed an outgoing local preview before network work. This preserves any
  /// existing source flight and enforces the same byte/entry budget as loads.
  void put(String eventId, Uint8List bytes) {
    final previous = _entries.remove(eventId);
    if (previous != null) _totalBytes -= previous.length;
    _entries[eventId] = bytes;
    _totalBytes += bytes.length;
    _evictToBudget();
  }

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
    final generation = _generation;
    final flight = load();
    _inFlight[eventId] = flight;
    // 成功转正式缓存并做字节加权 LRU 收缩；失败仅清除在途记录，允许
    // 后续重试（失败不占预算）。
    unawaited(flight.then(
      (bytes) {
        if (generation != _generation) return;
        _inFlight.remove(eventId);
        final previous = _entries.remove(eventId);
        if (previous != null) _totalBytes -= previous.length;
        _entries[eventId] = bytes;
        _totalBytes += bytes.length;
        _evictToBudget();
      },
      onError: (_) {
        if (generation != _generation) return;
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
final _sharedMediaBytes = MediaMemoryCache();
final _mediaLoads = <String, Future<Uint8List>>{};
int _mediaGeneration = 0;

/// Call when clearing cache or signing out. In-flight work cannot repopulate
/// the shared memory cache after this boundary.
void clearMediaMemoryCaches() {
  _mediaGeneration++;
  _sharedMediaBytes.clear();
  videoMemoryCache.clear();
  _mediaLoads.clear();
}

Future<Uint8List> loadMediaWithCache(
    MediaCacheKey key, Future<Uint8List> Function() decrypt) async {
  final generation = _mediaGeneration;
  final root = await MediaCache._root(key.accountId);
  if (generation != _mediaGeneration) {
    throw StateError('Media cache session changed');
  }
  unawaited(MediaCache.discardLegacyCache().catchError((_) {}));
  final identity = '${root.path}/${key.identity}';
  final existing = _mediaLoads[identity];
  final flight = existing ??
      (() async {
        var disk = await MediaCache.cached(key.roomId, key.eventId,
            accountId: key.accountId);
        if (disk == null && key.sourceIdentity != null) {
          disk = await MediaCache.cached('source', key.sourceIdentity!,
              accountId: key.accountId);
        }
        final bytes = disk == null ? await decrypt() : null;
        if (generation != _mediaGeneration) {
          throw StateError('Media cache session changed');
        }
        final file = disk ??
            await MediaCache.store(key.roomId, key.eventId, bytes!,
                accountId: key.accountId);
        if (key.sourceIdentity != null) {
          final ref = await MediaCache._reference(
              key.accountId, 'source', key.sourceIdentity!);
          await MediaCache._atomicBytes(
              ref, utf8.encode(file.uri.pathSegments.last));
        }
        final messageRef =
            await MediaCache._reference(key.accountId, key.roomId, key.eventId);
        await MediaCache._atomicBytes(
            messageRef, utf8.encode(file.uri.pathSegments.last));
        if (generation != _mediaGeneration) return file.readAsBytes();
        return _sharedMediaBytes.putIfAbsent(file.path, file.readAsBytes);
      })();
  if (existing == null) _mediaLoads[identity] = flight;
  try {
    final bytes = await flight;
    // A source flight can serve a different message: persist its reference too.
    if (existing != null && generation == _mediaGeneration) {
      await MediaCache.store(key.roomId, key.eventId, bytes,
          accountId: key.accountId);
    }
    return bytes;
  } finally {
    if (identical(_mediaLoads[identity], flight)) _mediaLoads.remove(identity);
  }
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
  final disk = await MediaCache.cached(key.roomId, key.eventId,
      accountId: key.accountId);
  if (disk != null) {
    return MediaCache.preparePlaybackFile(key.roomId, key.eventId,
        accountId: key.accountId);
  }
  final bytes = await (memoryCache ?? videoMemoryCache)
      .putIfAbsent(key.identity, () => loadMediaWithCache(key, decrypt));
  if (await MediaCache.cached(key.roomId, key.eventId,
          accountId: key.accountId) ==
      null) {
    await MediaCache.store(key.roomId, key.eventId, bytes,
        accountId: key.accountId);
  }
  return MediaCache.preparePlaybackFile(key.roomId, key.eventId,
      accountId: key.accountId);
}

final class MediaCacheKey {
  const MediaCacheKey(
      {required this.roomId,
      required this.eventId,
      this.accountId = '',
      this.sourceIdentity});
  final String accountId;

  /// Full authenticated source identity, including encryption descriptor.
  final String? sourceIdentity;
  String get identity => jsonEncode([
        accountId,
        sourceIdentity ?? [roomId, eventId]
      ]);
  final String roomId;
  final String eventId;

  @override
  bool operator ==(Object other) =>
      other is MediaCacheKey &&
      other.accountId == accountId &&
      other.sourceIdentity == sourceIdentity &&
      other.roomId == roomId &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(accountId, sourceIdentity, roomId, eventId);
}

/// Compute only from the already authorized event's attachment descriptor.
/// Never transmit or log this identifier. An incomplete encrypted descriptor
/// cannot be treated as a plain MXC URL or coalesced with another event.
String? matrixMediaSourceIdentity(Map<String, dynamic> content,
    {bool thumbnail = false}) {
  final info = content['info'];
  final Map data = thumbnail ? (info is Map ? info : const {}) : content;
  final fileKey = thumbnail ? 'thumbnail_file' : 'file';
  final urlKey = thumbnail ? 'thumbnail_url' : 'url';
  final encrypted = data[fileKey];
  Object? descriptor;
  if (data.containsKey(fileKey)) {
    if (encrypted is! Map ||
        encrypted['url'] is! String ||
        encrypted['key'] is! Map ||
        (encrypted['key'] as Map)['k'] is! String ||
        encrypted['iv'] is! String ||
        encrypted['hashes'] is! Map ||
        (encrypted['hashes'] as Map)['sha256'] is! String) {
      return null;
    }
    descriptor = encrypted;
  } else {
    final url = data[urlKey];
    if (url is! String || !url.startsWith('mxc://')) return null;
    descriptor = url;
  }
  Object? canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  return sha256
      .convert(utf8.encode(jsonEncode([thumbnail, canonical(descriptor)])))
      .toString();
}
