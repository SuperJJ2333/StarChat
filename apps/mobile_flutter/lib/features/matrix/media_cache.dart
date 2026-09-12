import 'dart:async';
import 'content_addressed_media.dart';
import 'media_load_scheduler.dart';
import 'media_consumer_scope.dart';
import 'media_memory_budget.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/performance_metrics.dart';

/// Device-only content objects. References and object identities never leave
/// this device. Each account has a separate namespace, including memory.
final class MediaCache {
  MediaCache._();
  static const diskSoftQuotaBytes = 384 * 1024 * 1024;
  static const diskHardQuotaBytes = 512 * 1024 * 1024;
  static final _storeFlights = <String, Future<File>>{};
  static final _objectFlights = <String, Future<File>>{};
  static final _legacyCleanups = <String, Future<void>>{};
  static final _clearingAccounts = <String>{};
  static final _clearingRoots = <String>{};
  static final _storeAccounts = <String, String>{};
  static final _atomicWrites = <String, Future<void>>{};
  static final _accountGenerations = <String, int>{};

  static int accountGeneration(String accountId) =>
      _accountGenerations[accountId] ?? 0;

  static Future<File> _clearEpochFile(String accountId) async {
    final docs = await getApplicationDocumentsDirectory();
    return File(
        '${docs.path}/media-clear-epochs/v1/${_digest(accountId)}.epoch');
  }

  static Future<void> _writeClearEpoch(String accountId) async {
    final file = await _clearEpochFile(accountId);
    await file.parent.create(recursive: true);
    await _writeAtomicBytes(
        file, utf8.encode(DateTime.now().millisecondsSinceEpoch.toString()));
  }

  /// Returns true only when a legacy CacheManager file predates this account's
  /// durable clear boundary. Missing boundaries keep pre-upgrade offline files
  /// eligible for one authorized local migration.
  static Future<bool> legacyEntryPredatesAccountClear(
      String accountId, DateTime modifiedAt) async {
    final file = await _clearEpochFile(accountId);
    if (!await file.exists()) return false;
    final epoch = int.tryParse(await file.readAsString());
    if (epoch == null) {
      throw StateError('Media cache clear epoch is invalid');
    }
    return modifiedAt.millisecondsSinceEpoch <= epoch;
  }

  /// Removes only this account's managed objects and references. Late network
  /// decrypts are fenced; local writes finish before their directory is removed.
  static Future<void> clearAccount(String accountId) async {
    if (!_clearingAccounts.add(accountId)) {
      throw StateError('Media cache clear already in progress');
    }
    _accountGenerations[accountId] = accountGeneration(accountId) + 1;
    clearMediaMemoryCaches();
    String? rootPath;
    Object? clearFailure;
    StackTrace? clearStackTrace;
    void recordFailure(Object error, StackTrace stackTrace) {
      clearFailure ??= error;
      clearStackTrace ??= stackTrace;
    }

    try {
      try {
        await _writeClearEpoch(accountId);
      } catch (error, stackTrace) {
        recordFailure(error, stackTrace);
      }
      for (final clear in List.of(_accountMediaCacheClearers)) {
        try {
          await clear(accountId);
        } catch (error, stackTrace) {
          recordFailure(error, stackTrace);
        }
      }
      final docs = await getApplicationDocumentsDirectory();
      rootPath = '${docs.path}/chat-media/v2/${_digest(accountId)}';
      _clearingRoots.add(rootPath);
      final writes = <Future<dynamic>>[
        for (final entry in _storeFlights.entries)
          if (_storeAccounts[entry.key] == accountId) entry.value,
        for (final entry in _atomicWrites.entries)
          if (entry.key.startsWith('$rootPath/')) entry.value,
      ];
      await Future.wait(writes
          .map((future) => future.then<void>((_) {}, onError: (Object _) {})));
      final root = Directory(rootPath);
      if (await root.exists()) await root.delete(recursive: true);
    } finally {
      if (rootPath != null) _clearingRoots.remove(rootPath);
      _clearingAccounts.remove(accountId);
    }
    if (clearFailure != null) {
      Error.throwWithStackTrace(clearFailure!, clearStackTrace!);
    }
  }

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
        } on FileSystemException {/* Retry on the next process start. */}
      }
    });
  }

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static Future<Directory> _root(String accountId) async {
    if (_clearingAccounts.contains(accountId)) {
      throw StateError('Media cache is being cleared');
    }
    final docs = await getApplicationDocumentsDirectory();
    if (_clearingAccounts.contains(accountId)) {
      throw StateError('Media cache is being cleared');
    }
    return Directory('${docs.path}/chat-media/v2/${_digest(accountId)}')
        .create(recursive: true);
  }

  static Future<File> _reference(
      String accountId, String roomId, String eventId,
      {int? generation}) async {
    final root = await _root(accountId);
    if (generation != null && generation != _mediaGeneration) {
      throw StateError('Media cache session changed');
    }
    final dir = await Directory('${root.path}/refs').create(recursive: true);
    if (generation != null && generation != _mediaGeneration) {
      throw StateError('Media cache session changed');
    }
    return File('${dir.path}/${_digest(jsonEncode([roomId, eventId]))}.ref');
  }

  static Future<File?> cached(String roomId, String eventId,
      {String accountId = '', String? contentSha256}) async {
    if (contentSha256 != null) {
      validateContentSha256(contentSha256);
      final root = await _root(accountId);
      for (final suffix in ['', '.mp4', '.mov']) {
        final file = File('${root.path}/objects/$contentSha256$suffix');
        if (await _valid(file)) {
          await file.setLastModified(DateTime.now());
          PerformanceMetrics.instance
              .increment(PerformanceCounter.mediaDiskHit);
          return file;
        }
      }
      return null;
    }
    final ref = await _reference(accountId, roomId, eventId);
    try {
      if (!await ref.exists()) return null;
      final name = await ref.readAsString();
      if (!RegExp(r'^[a-f0-9]{64}(\.mp4|\.mov)?$').hasMatch(name)) return null;
      final root = await _root(accountId);
      final file = File('${root.path}/objects/$name');
      if (!await _valid(file)) return null;
      await file.setLastModified(DateTime.now());
      PerformanceMetrics.instance.increment(PerformanceCounter.mediaDiskHit);
      return file;
    } on FileSystemException {
      return null;
    }
  }

  /// Removes a logical reference without deleting its potentially shared
  /// account-local content object.
  static Future<void> removeReference(String roomId, String eventId,
      {String accountId = ''}) async {
    final ref = await _reference(accountId, roomId, eventId);
    await _deleteQuietly(ref);
  }

  static Future<bool> _valid(File file) async {
    try {
      if (!await file.exists()) return false;
      final expected =
          int.tryParse(await File('${file.path}.len').readAsString());
      if (expected != null && expected == await file.length()) {
        final name = file.uri.pathSegments.last.split('.').first;
        validateContentSha256(name);
        await verifyMediaContentStream(file.openRead(), name);
        return true;
      }
    } on FileSystemException {
      /* Interrupted writes are cache misses. */
    } on FormatException {/* Modified content is a cache miss. */}
    await _deleteQuietly(file);
    await _deleteQuietly(File('${file.path}.len'));
    return false;
  }

  static Future<void> _deleteQuietly(FileSystemEntity file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {/* Best effort cleanup. */}
  }

  static Future<void> _atomicBytes(File file, List<int> bytes,
      {int? generation}) async {
    if (generation != null && generation != _mediaGeneration) {
      throw StateError('Media cache session changed');
    }
    if (_clearingRoots.any((root) => file.path.startsWith('$root/'))) {
      throw StateError('Media cache is being cleared');
    }
    final previous = _atomicWrites[file.path];
    final flight = (() async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {/* A failed reference can retry. */}
      }
      if (generation != null && generation != _mediaGeneration) {
        throw StateError('Media cache session changed');
      }
      if (_clearingRoots.any((root) => file.path.startsWith('$root/'))) {
        throw StateError('Media cache is being cleared');
      }
      await _writeAtomicBytes(file, bytes);
    })();
    _atomicWrites[file.path] = flight;
    try {
      await flight;
    } finally {
      if (identical(_atomicWrites[file.path], flight)) {
        _atomicWrites.remove(file.path);
      }
    }
  }

  static Future<void> _writeAtomicBytes(File file, List<int> bytes) async {
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
      {String accountId = '',
      String? contentSha256,
      int? expectedAccountGeneration}) async {
    if (expectedAccountGeneration != null &&
        expectedAccountGeneration != accountGeneration(accountId)) {
      throw StateError('Media cache account was cleared');
    }
    final generation = _mediaGeneration;
    verifyMediaContent(bytes, contentSha256);
    final flightKey = '${_digest(jsonEncode([accountId, roomId, eventId]))}'
        ':${sha256.convert(bytes)}';
    final existing = _storeFlights[flightKey];
    if (existing != null) return existing;
    final flight = _root(accountId).then((root) {
      if (generation != _mediaGeneration) {
        throw StateError('Media cache session changed');
      }
      if (expectedAccountGeneration != null &&
          expectedAccountGeneration != accountGeneration(accountId)) {
        throw StateError('Media cache account was cleared');
      }
      return _store(root, accountId, roomId, eventId, bytes);
    });
    _storeFlights[flightKey] = flight;
    _storeAccounts[flightKey] = accountId;
    try {
      return await flight;
    } finally {
      _storeFlights.remove(flightKey);
      _storeAccounts.remove(flightKey);
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
      {String accountId = '', String? contentSha256}) async {
    final flightKey = _digest(jsonEncode([accountId, roomId, eventId]));
    await Future.wait([
      for (final entry in _storeFlights.entries)
        if (entry.key.startsWith('$flightKey:')) entry.value,
    ]);
    final file = await cached(roomId, eventId,
        accountId: accountId, contentSha256: contentSha256);
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

/// Byte-budgeted memory cache. Shared chat media uses account + actual digest;
/// room-local preview users may supply their own stable keys. Reusing the same
/// byte instance lets MemoryImage share its decoded image/animated codec.
///
/// M04：LRU 同时受**字节预算**与条目上限约束——大视频按实际字节数
/// 加权，不再出现"3 条 4K 视频"式的条数掩盖内存失控；超预算从最旧
/// 条目开始回收。
final class _VerifiedMediaBytes {
  const _VerifiedMediaBytes(this.digest, this.namespace);
  final String digest;
  final Object namespace;
}

final class MediaMemoryCache {
  MediaMemoryCache({
    this.maxEntries = 48,
    this.maxBytes = 64 * 1024 * 1024,
    this.budget,
    this.accountNamespace,
  }) {
    budget?.register(_budgetOwner, clear);
  }

  final int maxEntries;
  final int maxBytes;
  final MediaMemoryBudget? budget;
  final String? accountNamespace;
  final _budgetOwner = Object();
  static final _verified = Expando<_VerifiedMediaBytes>();
  bool _disposed = false;

  final _entries = <String, Uint8List>{};
  final _inFlight = <String, OwnedMediaFlight<Uint8List>>{};
  int _totalBytes = 0;
  int _generation = 0;
  void clear() {
    _generation++;
    for (final key in _entries.keys) {
      budget?.forget(_budgetOwner, key);
    }
    _entries.clear();
    _inFlight.clear();
    _totalBytes = 0;
  }

  /// 当前内存占用（字节；诊断/测试）。
  int get totalBytes => _totalBytes;

  /// Token for external asynchronous local reads that seed this cache.
  int get generation => _generation;

  void dispose() {
    clear();
    budget?.unregister(_budgetOwner);
    _disposed = true;
  }

  /// Seed an outgoing local preview before network work. This preserves any
  /// existing source flight and enforces the same byte/entry budget as loads.
  Uint8List put(String eventId, Uint8List bytes) {
    if (_disposed) throw StateError('Media cache disposed');
    final owned = _ownVerifiedBytes(eventId, bytes);
    _store(eventId, owned);
    return owned;
  }

  static final _contentKey =
      RegExp(r'(?:content:|[/\\])([a-f0-9]{64})(?:\.mp4|\.mov)?$');

  // Copy before validating: neither the producer nor a consumer may mutate
  // verified bytes. Warm reads can then reuse the same image identity in O(1).
  Uint8List _ownVerifiedBytes(String key, Uint8List bytes) {
    if (identical(_entries[key], bytes)) return bytes;
    final namespace = _namespace(key);
    final hash = _contentKey.firstMatch(key)?.group(1);
    final known = _verified[bytes];
    final owned = known != null && known.namespace == namespace
        ? bytes
        : Uint8List.fromList(bytes).asUnmodifiableView();
    final digest = known?.digest ??
        (hash != null || budget != null
            ? sha256.convert(owned).toString()
            : null);
    if (hash != null && digest != hash) {
      throw const FormatException('Media content hash mismatch');
    }
    if (digest == null) return owned;
    final canonical = budget?.find(namespace, digest) ?? owned;
    _verified[canonical] = _VerifiedMediaBytes(digest, namespace);
    return canonical;
  }

  Object _namespace(String key) {
    if (accountNamespace != null) return accountNamespace!;
    final raw = key.startsWith('thumb:') ? key.substring(6) : key;
    try {
      final separator = raw.lastIndexOf(':content:');
      final parsed =
          jsonDecode(separator < 0 ? raw : raw.substring(0, separator));
      if (parsed is String) return parsed;
      if (parsed is List && parsed.isNotEmpty && parsed.first is String) {
        return parsed.first as String;
      }
    } on FormatException {/* Unscoped legacy keys remain cache-local. */}
    return _budgetOwner;
  }

  void _store(String key, Uint8List bytes) {
    budget?.forget(_budgetOwner, key);
    final previous = _entries.remove(key);
    if (previous != null) _totalBytes -= previous.length;
    _entries[key] = bytes;
    _totalBytes += bytes.length;
    _evictToBudget();
    if (identical(_entries[key], bytes) && budget != null) {
      final verified = _verified[bytes]!;
      budget!.retain(_budgetOwner, key, verified.namespace, verified.digest,
          bytes, () => _removeEntry(key));
    }
  }

  void _removeEntry(String key) {
    final bytes = _entries.remove(key);
    if (bytes != null) _totalBytes -= bytes.length;
    budget?.forget(_budgetOwner, key);
  }

  Uint8List? get(String eventId) {
    final bytes = _entries.remove(eventId);
    if (bytes == null) return null;
    _entries[eventId] = bytes;
    budget?.touch(_budgetOwner, eventId);
    PerformanceMetrics.instance.increment(PerformanceCounter.mediaMemoryHit);
    return bytes;
  }

  Future<Uint8List> putIfAbsent(
    String eventId,
    Future<Uint8List> Function() load,
  ) {
    if (_disposed) return Future.error(StateError('Media cache disposed'));
    final cached = get(eventId);
    if (cached != null) return SynchronousFuture<Uint8List>(cached);
    final scope = MediaConsumerScope.current;
    if (scope != null && !scope.isActive) {
      return Future.error(MediaLoadCanceled());
    }
    final existing = _inFlight[eventId];
    if (existing != null) {
      PerformanceMetrics.instance.increment(PerformanceCounter.mediaFlightJoin);
      return existing.join(scope);
    }
    final generation = _generation;
    late final OwnedMediaFlight<Uint8List> flight;
    flight = OwnedMediaFlight<Uint8List>(() async {
      final bytes = await load();
      if (!flight.isActive) throw MediaLoadCanceled();
      final owned = _ownVerifiedBytes(eventId, bytes);
      if (generation == _generation && flight.isActive) _store(eventId, owned);
      return owned;
    });
    flight.onInactive = () {
      if (identical(_inFlight[eventId], flight)) _inFlight.remove(eventId);
    };
    _inFlight[eventId] = flight;
    return flight.join(scope);
  }

  void _evictToBudget() {
    while (_entries.isNotEmpty &&
        (_totalBytes > maxBytes || _entries.length > maxEntries)) {
      final oldestKey = _entries.keys.first;
      _removeEntry(oldestKey);
    }
  }
}

/// 解密并缓存媒体附件：优先命中本地缓存；未命中时调用 loader 解密、
/// 落盘后返回字节。
final _sharedMediaBytes = MediaMemoryCache(budget: sharedMediaMemoryBudget);
final contentMediaMemoryCache = _sharedMediaBytes;
final _mediaLoads = <String, OwnedMediaFlight<Uint8List>>{};
int _mediaGeneration = 0;
final _decodedMediaCacheClearers = <VoidCallback>{};
final _accountMediaCacheClearers = <Future<void> Function(String)>{};

/// A renderer registers lazily, after Flutter has created its painting binding.
/// Pure storage users do not need to initialize the Flutter widget runtime.
void registerDecodedMediaCacheClearer(VoidCallback clear) {
  _decodedMediaCacheClearers.add(clear);
}

/// Allows a local cache to join account deletion without creating a UI import
/// from this storage layer. Each clearer is responsible for only its account.
VoidCallback registerAccountMediaCacheClearer(
    Future<void> Function(String) clear) {
  _accountMediaCacheClearers.add(clear);
  return () => _accountMediaCacheClearers.remove(clear);
}

/// Call when clearing cache or signing out. In-flight work cannot repopulate
/// the shared memory cache after this boundary.
void clearMediaMemoryCaches() {
  _mediaGeneration++;
  sharedMediaMemoryBudget.clear();
  _sharedMediaBytes.clear();
  videoMemoryCache.clear();
  _mediaLoads.clear();
  mediaLoadScheduler.cancelAll();
  for (final clear in _decodedMediaCacheClearers) {
    clear();
  }
}

Future<Uint8List> loadMediaWithCache(
    MediaCacheKey key, Future<Uint8List> Function() decrypt,
    {MediaLoadPriority? priority, bool? isVideo}) async {
  final scope = MediaConsumerScope.current;
  if (scope != null && !scope.isActive) throw MediaLoadCanceled();
  final generation = _mediaGeneration;
  final root = await MediaCache._root(key.accountId);
  if (scope != null && !scope.isActive) throw MediaLoadCanceled();
  if (generation != _mediaGeneration) {
    throw StateError('Media cache session changed');
  }
  unawaited(MediaCache.discardLegacyCache().catchError((_) {}));
  final identity = '${root.path}/${key.identity}';
  // Immutable content bytes are verified at insertion. Do not read the same
  // multi-megabyte GIF from disk for every event that references its digest.
  final warm =
      key.contentSha256 == null ? null : _sharedMediaBytes.get(key.cacheId);
  if (warm != null) {
    await _linkMediaReference(key, warm, generation);
    if (scope != null && !scope.isActive) throw MediaLoadCanceled();
    return warm;
  }
  final existing = _mediaLoads[identity];
  if (existing != null) {
    PerformanceMetrics.instance.increment(PerformanceCounter.mediaFlightJoin);
  }
  var demand = priority ?? currentMediaLoadPriority;
  if (scope != null && scope.priority.index < demand.index) {
    demand = scope.priority;
  }
  final taskKey = '$generation:$identity';
  late final OwnedMediaFlight<Uint8List> flight;
  flight = existing ??
      OwnedMediaFlight<Uint8List>(() async {
        var disk = await MediaCache.cached(key.roomId, key.eventId,
            accountId: key.accountId, contentSha256: key.contentSha256);
        if (disk == null && key.sourceIdentity != null) {
          disk = await MediaCache.cached('source', key.sourceIdentity!,
              accountId: key.accountId, contentSha256: key.contentSha256);
        }
        if (generation != _mediaGeneration) {
          throw StateError('Media cache session changed');
        }
        final child = MediaConsumerScope.current!;
        if (!child.isActive) throw MediaLoadCanceled();
        Uint8List? bytes;
        if (disk == null) {
          final lease = mediaLoadScheduler.request(taskKey, () async {
            PerformanceMetrics.instance
                .increment(PerformanceCounter.mediaDownload);
            return decrypt();
          },
              priority: child.priority,
              isVideo: isVideo ?? currentMediaLoadIsVideo);
          void promote(MediaLoadPriority priority) =>
              mediaLoadScheduler.promote(taskKey, priority);
          child.addCancelListener(lease.cancel);
          child.addPriorityListener(promote);
          try {
            if (!child.isActive) throw MediaLoadCanceled();
            bytes = await lease.value;
          } finally {
            child.removeCancelListener(lease.cancel);
            child.removePriorityListener(promote);
          }
        }
        if (!child.isActive) throw MediaLoadCanceled();
        if (bytes != null) verifyMediaContent(bytes, key.contentSha256);
        if (generation != _mediaGeneration) {
          throw StateError('Media cache session changed');
        }
        final file = disk ??
            await MediaCache.store(key.roomId, key.eventId, bytes!,
                accountId: key.accountId, contentSha256: key.contentSha256);
        if (key.sourceIdentity != null) {
          final ref = await MediaCache._reference(
              key.accountId, 'source', key.sourceIdentity!,
              generation: generation);
          await MediaCache._atomicBytes(
              ref, utf8.encode(file.uri.pathSegments.last),
              generation: generation);
        }
        final messageRef = await MediaCache._reference(
            key.accountId, key.roomId, key.eventId,
            generation: generation);
        await MediaCache._atomicBytes(
            messageRef, utf8.encode(file.uri.pathSegments.last),
            generation: generation);
        if (generation != _mediaGeneration) {
          throw StateError('Media cache session changed');
        }
        // Legacy sources discover their digest after decrypting; converge on
        // the same memory identity as newer events carrying a trusted digest.
        final memoryKey = MediaCacheKey(
                accountId: key.accountId,
                roomId: key.roomId,
                eventId: key.eventId,
                contentSha256: file.uri.pathSegments.last.split('.').first)
            .cacheId;
        return _sharedMediaBytes.putIfAbsent(memoryKey, () async {
          final result = bytes ?? await file.readAsBytes();
          verifyMediaContent(result, key.contentSha256);
          return result;
        });
      });
  flight.childScope.promote(demand);
  if (existing == null) {
    flight.onInactive = () {
      if (identical(_mediaLoads[identity], flight)) {
        _mediaLoads.remove(identity);
      }
    };
    _mediaLoads[identity] = flight;
  }
  final bytes = await withMediaLoadPriority(demand, () => flight.join(scope));
  if (scope != null && !scope.isActive) throw MediaLoadCanceled();
  // A source flight can serve a different message: persist its reference too.
  if (existing != null && generation == _mediaGeneration) {
    await _linkMediaReference(key, bytes, generation);
    if (scope != null && !scope.isActive) throw MediaLoadCanceled();
  }
  return bytes;
}

Future<void> _linkMediaReference(
    MediaCacheKey key, Uint8List bytes, int generation) async {
  final hash = key.contentSha256 ?? sha256.convert(bytes).toString();
  final name = '$hash${MediaCache._videoContainerSuffix(bytes) ?? ''}';
  for (final reference in [
    (key.roomId, key.eventId),
    if (key.sourceIdentity != null) ('source', key.sourceIdentity!),
  ]) {
    final ref = await MediaCache._reference(
        key.accountId, reference.$1, reference.$2,
        generation: generation);
    await MediaCache._atomicBytes(ref, utf8.encode(name),
        generation: generation);
  }
  if (generation != _mediaGeneration) {
    throw StateError('Media cache session changed');
  }
}

/// Retain actual outgoing content before encryption/upload. A returned copy can
/// then resolve its trusted digest even if the original was never opened.
Future<Uint8List> cacheOutgoingMedia({
  required String accountId,
  required String roomId,
  required Uint8List bytes,
}) {
  final hash = sha256.convert(bytes).toString();
  return loadMediaWithCache(
      MediaCacheKey(
          accountId: accountId,
          roomId: roomId,
          eventId: 'outgoing:$hash',
          contentSha256: hash),
      () async => bytes);
}

/// Video source flights share the same 32 MiB encoded-byte budget as images.
/// Playback uses persistent files; resident bytes are evicted under that budget.
final videoMemoryCache = MediaMemoryCache(
  maxEntries: 6,
  maxBytes: 32 * 1024 * 1024,
  budget: sharedMediaMemoryBudget,
);

/// 解析视频播放文件（E2E 修复：重复打开全量下载 + 临时文件泄漏）。
///
/// 顺序：磁盘缓存直读（零下载零解密）→ 内存在途去重下载解密 →
/// 落盘返回。播放器直接使用该缓存文件，不再复制到系统临时目录。
Future<File> resolveCachedVideoFile({
  required MediaCacheKey key,
  required Future<Uint8List> Function() decrypt,
  MediaMemoryCache? memoryCache,
  // SDK attachment loaders already own the content-cache flight. They must
  // not be wrapped in another same-key content-cache request.
  bool loaderCachesContent = false,
}) async {
  final generation = _mediaGeneration;
  final disk = await MediaCache.cached(key.roomId, key.eventId,
      accountId: key.accountId, contentSha256: key.contentSha256);
  if (generation != _mediaGeneration) {
    throw StateError('Media cache session changed');
  }
  if (disk != null) {
    return disk;
  }
  final bytes = await (memoryCache ?? videoMemoryCache).putIfAbsent(
      key.identity,
      () => loaderCachesContent
          ? withMediaLoadPriority(MediaLoadPriority.interactive, decrypt,
              isVideo: true)
          : loadMediaWithCache(key, decrypt,
              priority: MediaLoadPriority.interactive, isVideo: true));
  if (generation != _mediaGeneration) {
    throw StateError('Media cache session changed');
  }
  if (await MediaCache.cached(key.roomId, key.eventId,
          accountId: key.accountId, contentSha256: key.contentSha256) ==
      null) {
    if (generation != _mediaGeneration) {
      throw StateError('Media cache session changed');
    }
    await MediaCache.store(key.roomId, key.eventId, bytes,
        accountId: key.accountId, contentSha256: key.contentSha256);
  }
  final playback = await MediaCache.preparePlaybackFile(key.roomId, key.eventId,
      accountId: key.accountId, contentSha256: key.contentSha256);
  if (generation != _mediaGeneration) {
    throw StateError('Media cache session changed');
  }
  return playback;
}

final class MediaCacheKey {
  const MediaCacheKey(
      {required this.roomId,
      required this.eventId,
      this.accountId = '',
      this.sourceIdentity,
      this.contentSha256});
  final String accountId;
  final String? contentSha256;
  String get cacheId => identity;

  /// Full authenticated source identity, including encryption descriptor.
  final String? sourceIdentity;
  String get identity {
    final hash = contentSha256;
    if (hash != null) {
      validateContentSha256(hash);
      return '${jsonEncode(accountId)}:content:$hash';
    }
    return jsonEncode([
      accountId,
      sourceIdentity ?? [roomId, eventId]
    ]);
  }

  final String roomId;
  final String eventId;

  @override
  bool operator ==(Object other) =>
      other is MediaCacheKey &&
      other.accountId == accountId &&
      other.contentSha256 == contentSha256 &&
      other.sourceIdentity == sourceIdentity &&
      other.roomId == roomId &&
      other.eventId == eventId;

  @override
  int get hashCode =>
      Object.hash(accountId, sourceIdentity, contentSha256, roomId, eventId);
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
