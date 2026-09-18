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
import 'media_cache_metrics.dart';
import 'media_index.dart';

/// 本地媒体磁盘配额策略（Phase 2：账号内软配额 + 设备硬上限）。
@immutable
final class MediaQuotaPolicy {
  const MediaQuotaPolicy({
    this.accountSoftQuotaBytes = defaultAccountSoftQuotaBytes,
    this.deviceHardQuotaBytes = defaultDeviceHardQuotaBytes,
  });

  static const defaultAccountSoftQuotaBytes = 384 * 1024 * 1024;
  static const defaultDeviceHardQuotaBytes = 1024 * 1024 * 1024;

  final int accountSoftQuotaBytes;
  final int deviceHardQuotaBytes;

  @override
  String toString() => 'MediaQuotaPolicy(accountSoft: $accountSoftQuotaBytes, '
      'deviceHard: $deviceHardQuotaBytes)';
}

/// Device-only content objects. References and object identities never leave
/// this device. Each account has a separate namespace, including memory.
///
/// Phase 2：两级配额（账号内软配额 + 设备硬上限）、索引加速命中（不再重复
/// 整文件哈希）、批量 LRU touch、pin/GC。目录保持 `chat-media/v2/<sha256(account)>`
/// （已账号隔离，不做机械迁移）。
final class MediaCache {
  MediaCache._();

  /// 生效配额策略（集中配置；测试可临时覆盖，生产使用默认值）。
  ///
  /// - 账号软配额默认 **384 MiB**（沿用线上既有软配额值）：超过只淘汰
  ///   **本账号**最久未访问对象，直到回到该值；
  /// - 设备硬上限默认 **1024 MiB**：跨账号兜底。账号隔离后若仍沿用旧的
  ///   512MiB 全局值，两个账号各用满软配额就会立刻互相驱逐（等于没解决
  ///   P1），故上限抬到 1GiB 以容纳 2–3 个活跃账号，同时仍约束最坏磁盘占用。
  static MediaQuotaPolicy quotaPolicy = const MediaQuotaPolicy();

  static int get accountSoftQuotaBytes => quotaPolicy.accountSoftQuotaBytes;

  static int get deviceHardQuotaBytes => quotaPolicy.deviceHardQuotaBytes;

  /// 恢复默认配额（测试收尾用）。
  static void resetQuotaPolicy() => quotaPolicy = const MediaQuotaPolicy();

  /// 测试：按字节覆盖配额。
  @visibleForTesting
  static void useQuotaForTest({int? accountSoft, int? deviceHard}) {
    quotaPolicy = MediaQuotaPolicy(
      accountSoftQuotaBytes:
          accountSoft ?? MediaQuotaPolicy.defaultAccountSoftQuotaBytes,
      deviceHardQuotaBytes:
          deviceHard ?? MediaQuotaPolicy.defaultDeviceHardQuotaBytes,
    );
  }

  /// 无引用对象的保护期：晚于 `now - gcGracePeriod` 的对象不回收
  /// （覆盖"对象已写、引用尚未写"的窗口）。
  static const gcGracePeriod = Duration(seconds: 60);

  /// 廉价完整性校验的 mtime 容差。
  ///
  /// 取 0（严格）：已索引对象的 mtime 只在写入时设定（LRU 走索引列，命中
  /// 不再改写 mtime），因此"mtime 晚于校验时间"必然是校验之后的改动。
  /// 极少数粗粒度文件系统（FAT32 等）可能出现 mtime 向上取整导致的假阳性，
  /// 代价只是多一次完整校验并回填索引（自愈），不会误判为损坏。
  static const _mtimeToleranceMs = 0;

  /// 允许走"廉价元数据"索引路径的最小对象尺寸（P0-1 的收益只在大文件上）。
  ///
  /// 小于该尺寸的对象整文件 SHA-256 的成本可忽略（< 1 MiB，亚毫秒级），
  /// 因此索引命中后仍然做完整校验：Phase 1 已经交付的
  /// "同尺寸原地篡改必被发现" 保证不因 Phase 2 而退化。
  /// 只有达到该尺寸的媒体才使用 "精确大小 + mtime 锚点" 的廉价路径。
  static const _cheapPathMinBytes = 1024 * 1024;

  static int? _cheapPathMinBytesOverride;

  static int get _minCheapPathBytes =>
      _cheapPathMinBytesOverride ?? _cheapPathMinBytes;

  /// 测试专用：把"廉价路径"门槛调低（或调 0）以便用小对象验证 P0-1 语义。
  @visibleForTesting
  static void useCheapPathMinBytesForTest(int? bytes) {
    _cheapPathMinBytesOverride = bytes;
  }

  static final _storeFlights = <String, Future<File>>{};
  static final _objectFlights = <String, Future<File>>{};
  static final _legacyCleanups = <String, Future<void>>{};
  static final _clearingAccounts = <String>{};
  static final _clearingRoots = <String>{};
  static final _storeAccounts = <String, String>{};
  static final _atomicWrites = <String, Future<void>>{};
  static final _accountGenerations = <String, int>{};

  /// 正在使用中的对象路径（播放/解码/上传下载）→ 引用计数。
  static final _pinned = <String, int>{};

  /// 进程内设备用量估计（null = 未知，需要在下次写入时重新统计一次）。
  static int? _deviceBytesEstimate;

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
      // 索引行随之清理（对象已删，索引不得继续声称可用）。
      await MediaIndex.shared.clearAccount(accountId);
      _deviceBytesEstimate = null;
      clearPinsForTest();
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
    final watch =
        MediaCacheMetrics.enabled ? (Stopwatch()..start()) : null;
    try {
      // ① 索引快路径：只做廉价校验（命名空间/存在/精确大小），**不重算哈希**。
      if (contentSha256 != null) {
        validateContentSha256(contentSha256);
        final indexed = await _cachedViaIndex(accountId,
            objectHash: contentSha256, roomId: roomId, eventId: eventId);
        if (indexed != null) return indexed;
        // ② legacy：按对象摘要直接定位（一次完整校验后回填索引）。
        final root = await _root(accountId);
        for (final suffix in ['', '.mp4', '.mov']) {
          final file = File('${root.path}/objects/$contentSha256$suffix');
          if (await _valid(file)) {
            await _indexVerified(accountId, roomId, eventId, file,
                objectHash: contentSha256);
            _touchIndex(accountId, roomId, eventId, file,
                objectHash: contentSha256);
            PerformanceMetrics.instance
                .increment(PerformanceCounter.mediaDiskHit);
            return file;
          }
        }
        return null;
      }
      final indexed = await _cachedViaIndex(accountId,
          roomId: roomId, eventId: eventId);
      if (indexed != null) return indexed;
      // ② legacy：refs/<digest>.ref → objects/<name>，完整校验后回填索引。
      final ref = await _reference(accountId, roomId, eventId);
      try {
        if (!await ref.exists()) return null;
        final name = await ref.readAsString();
        if (!RegExp(r'^[a-f0-9]{64}(\.mp4|\.mov)?$').hasMatch(name)) {
          return null;
        }
        final root = await _root(accountId);
        final file = File('${root.path}/objects/$name');
        if (!await _valid(file)) return null;
        await _indexVerified(accountId, roomId, eventId, file);
        _touchIndex(accountId, roomId, eventId, file);
        PerformanceMetrics.instance.increment(PerformanceCounter.mediaDiskHit);
        return file;
      } on FileSystemException {
        return null;
      }
    } finally {
      if (watch != null) MediaCacheMetrics.recordLookup(watch);
    }
  }

  /// 索引命中快路径（Phase 2）。
  ///
  /// 禁止"信索引不验文件"：索引只替代**重复的整文件哈希**，仍然校验
  /// 账号命名空间、文件存在与精确大小；任一不符即失效索引行并回退 legacy。
  static Future<File?> _cachedViaIndex(String accountId,
      {String? roomId, String? eventId, String? objectHash}) async {
    final entry = objectHash != null
        ? await MediaIndex.shared.lookupObject(accountId, objectHash)
        : await MediaIndex.shared.lookup(accountId, roomId!, eventId!);
    if (entry == null || !entry.verified) return null;
    final root = await _root(accountId);
    final objectsRoot = '${root.path}/objects/';
    if (!'$objectsRoot${entry.objectName}'.startsWith(objectsRoot)) {
      // 命名空间/路径不合法：索引行不可信。
      await MediaIndex.shared.forgetObjects(accountId, {entry.objectName});
      return null;
    }
    final file = File('$objectsRoot${entry.objectName}');
    try {
      if (!await file.exists()) {
        await MediaIndex.shared.forgetObjects(accountId, {entry.objectName});
        return null;
      }
      final stat = await file.stat();
      if (entry.sizeBytes > 0 && stat.size != entry.sizeBytes) {
        // 截断/替换：失效索引，交 legacy 处理（legacy 会删除损坏对象）。
        await MediaIndex.shared.forgetObjects(accountId, {entry.objectName});
        return null;
      }
      // 大对象（≥ 门槛）：廉价完整性锚点为**内容最后修改时间**。已索引对象的
      // mtime 只在写入时设定（LRU 走索引列，命中不再改写 mtime），因此
      // "mtime 晚于校验时间" 说明文件在校验之后被改动过 → 失效并回退完整校验。
      if (stat.size >= _minCheapPathBytes) {
        if (entry.verifiedAt > 0 &&
            stat.modified.millisecondsSinceEpoch >
                entry.verifiedAt + _mtimeToleranceMs) {
          await MediaIndex.shared.forgetObjects(accountId, {entry.objectName});
          return null;
        }
      } else if (!await _valid(file)) {
        // 小对象：哈希成本可忽略，直接完整校验，保持"同尺寸篡改必被发现"。
        await MediaIndex.shared.forgetObjects(accountId, {entry.objectName});
        return null;
      }
    } on FileSystemException {
      return null;
    }
    if (roomId != null && eventId != null) {
      _touchIndex(accountId, roomId, eventId, file, objectHash: objectHash);
    } else if (objectHash != null) {
      MediaIndex.shared.touchObject(accountId, objectHash,
          objectPath: file.path);
    }
    PerformanceMetrics.instance.increment(PerformanceCounter.mediaDiskHit);
    return file;
  }

  /// LRU 命中登记：只写内存 pending（同一对象 60s 内至多落库一次）。
  static void _touchIndex(String accountId, String roomId, String eventId,
      File file, {String? objectHash}) {
    if (objectHash != null) {
      MediaIndex.shared.touchObject(accountId, objectHash,
          objectPath: file.path);
      MediaIndex.shared.touch(accountId, roomId, eventId,
          objectPath: file.path);
      return;
    }
    MediaIndex.shared.touch(accountId, roomId, eventId, objectPath: file.path);
  }

  /// 内容校验判定损坏：删除对象与长度标记 + 失效索引行。
  /// 下一次 `cached()` 会重新走"未命中 → 下载/解密 → 落盘"。
  static Future<void> _discardCorruptObject(MediaCacheKey key, File file) async {
    await _deleteQuietly(file);
    await _deleteQuietly(File('${file.path}.len'));
    await MediaIndex.shared
        .forgetObjects(key.accountId, {file.uri.pathSegments.last});
    _deviceBytesEstimate = null;
  }

  static Future<void> _indexVerified(
      String accountId, String roomId, String eventId, File file,
      {String? objectHash,
      MediaVariantKind variant = MediaVariantKind.unknown,
      String? familyId,
      String? mimeType,
      int? width,
      int? height,
      int? durationMs}) async {
    final name = file.uri.pathSegments.last;
    final hash = objectHash ?? name.split('.').first;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) return;
    int size;
    try {
      size = await file.length();
    } on FileSystemException {
      return;
    }
    if (size <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await MediaIndex.shared.put(MediaIndexEntry(
      accountNamespace: MediaIndex.shared.namespaceFor(accountId),
      referenceKey: MediaIndex.shared.referenceKeyFor(roomId, eventId),
      objectHash: hash,
      objectName: name,
      sizeBytes: size,
      createdAt: now,
      lastAccessAt: now,
      verifiedAt: now,
      variant: variant,
      familyId: familyId,
      mimeType: mimeType,
      width: width,
      height: height,
      durationMs: durationMs,
    ));
  }

  /// 轻量存在性探测：只读引用文件 + 检查对象文件是否存在，
  /// **不重算哈希**（[cached] 会为完整性校验重算整个文件的 sha256——
  /// 在 50–500MB 视频上非常昂贵）。
  ///
  /// 用途：需要「本地是否已有该媒体的文件」这类廉价判断的场景
  /// （例如本地视频抽帧封面：有文件才抽帧，绝不为此下载）。
  /// 需要完整性保证的读取**必须**用 [cached] / [preparePlaybackFile]。
  static Future<File?> probeCachedObject(String roomId, String eventId,
      {String accountId = '', String? contentSha256}) async {
    try {
      final root = await _root(accountId);
      if (contentSha256 != null) {
        validateContentSha256(contentSha256);
        for (final suffix in ['', '.mp4', '.mov']) {
          final file = File('${root.path}/objects/$contentSha256$suffix');
          if (await file.exists()) return file;
        }
        return null;
      }
      final ref = await _reference(accountId, roomId, eventId);
      if (!await ref.exists()) return null;
      final name = await ref.readAsString();
      if (!RegExp(r'^[a-f0-9]{64}(\.mp4|\.mov)?$').hasMatch(name)) return null;
      final file = File('${root.path}/objects/$name');
      return await file.exists() ? file : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Removes a logical reference without deleting its potentially shared
  /// account-local content object（Phase 2：同时失效对应索引行，避免索引
  /// 继续声称该引用存在）。
  static Future<void> removeReference(String roomId, String eventId,
      {String accountId = ''}) async {
    final ref = await _reference(accountId, roomId, eventId);
    await _deleteQuietly(ref);
    await MediaIndex.shared.invalidate(accountId, roomId, eventId);
  }

  static Future<bool> _valid(File file) async {
    try {
      if (!await file.exists()) return false;
      final expected =
          int.tryParse(await File('${file.path}.len').readAsString());
      if (expected != null && expected == await file.length()) {
        final name = file.uri.pathSegments.last.split('.').first;
        validateContentSha256(name);
        // 完整性校验的代价（整文件流式哈希）单独计量：索引命中时该计数
        // 必须零增长（Phase 2 P0-1 验收）。
        MediaCacheMetrics.recordHash(await file.length());
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
      int? expectedAccountGeneration,
      MediaVariantKind variant = MediaVariantKind.unknown,
      String? familyId,
      String? mimeType,
      int? width,
      int? height,
      int? durationMs}) async {
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
      return _store(root, accountId, roomId, eventId, bytes,
          variant: variant,
          familyId: familyId,
          mimeType: mimeType,
          width: width,
          height: height,
          durationMs: durationMs);
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
      String eventId, Uint8List bytes,
      {MediaVariantKind variant = MediaVariantKind.unknown,
      String? familyId,
      String? mimeType,
      int? width,
      int? height,
      int? durationMs}) async {
    final digest = sha256.convert(bytes).toString();
    final name = '$digest${_videoContainerSuffix(bytes) ?? ''}';
    final objectKey = '${root.path}/objects/$name';
    final existing = _objectFlights[objectKey];
    final flight = existing ?? _storeObject(accountId, File(objectKey), bytes);
    if (existing == null) _objectFlights[objectKey] = flight;
    late File file;
    try {
      file = await flight;
    } finally {
      if (existing == null) _objectFlights.remove(objectKey);
    }
    MediaCacheMetrics.recordWrite(bytes.length);
    final ref = await _reference(accountId, roomId, eventId);
    await _atomicBytes(ref, utf8.encode(name));
    // 对象与引用都落盘成功之后才写索引（崩溃时最多缺索引行，绝不指向坏对象）。
    await _indexVerified(accountId, roomId, eventId, file,
        objectHash: digest,
        variant: variant,
        familyId: familyId,
        mimeType: mimeType,
        width: width,
        height: height,
        durationMs: durationMs);
    await _enforceDiskQuota(accountId, file);
    return file;
  }

  static Future<File> _storeObject(
      String accountId, File file, Uint8List bytes) async {
    await file.parent.create(recursive: true);
    if (await _knownObjectValid(accountId, file, bytes.length)) return file;
    await _atomicBytes(
        File('${file.path}.len'), utf8.encode('${bytes.length}'));
    await _atomicBytes(file, bytes);
    return file;
  }

  /// 已存在同内容对象时的廉价判定（Phase 2）：索引 + 精确大小优先，
  /// 只有索引不可用时才回退整文件哈希校验。小对象仍强制完整校验，
  /// 避免把"同尺寸原地篡改"的对象当作已存在内容复用到新引用上。
  static Future<bool> _knownObjectValid(
      String accountId, File file, int expectedBytes) async {
    final hash = file.uri.pathSegments.last.split('.').first;
    if (RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      final entry = await MediaIndex.shared.lookupObject(accountId, hash);
      if (entry != null && entry.verified) {
        try {
          if (await file.exists() && await file.length() == expectedBytes) {
            if (expectedBytes >= _minCheapPathBytes) return true;
            if (await _valid(file)) return true;
          }
        } on FileSystemException {
          // 落到完整校验。
        }
      }
    }
    return _valid(file);
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

  /// 账号内对象（objects/ 下的数据文件 + 大小 + mtime）。
  static Future<List<_CacheObject>> _accountObjects(String accountRootPath) async {
    final dir = Directory('$accountRootPath/objects');
    if (!await dir.exists()) return const [];
    final objects = <_CacheObject>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !_isData(entity)) continue;
        try {
          final stat = await entity.stat();
          objects.add(_CacheObject(entity, stat.size, stat.modified));
        } on FileSystemException {
          continue;
        }
      }
    } on FileSystemException {
      return const [];
    }
    return objects;
  }

  /// 两级配额（Phase 2）：
  /// ① 账号软配额：超限只淘汰**本账号**最久未访问对象；
  /// ② 设备硬上限：仅当全设备对象总量超过它才跨账号兜底淘汰。
  ///
  /// LRU 顺序：已索引对象用索引的 `last_access_at`（准确、批量刷新）；
  /// 未索引对象退回文件 mtime。
  static Future<void> _enforceDiskQuota(String accountId, File keep) async {
    final watch = MediaCacheMetrics.enabled ? (Stopwatch()..start()) : null;
    try {
      final accountRoot = await _root(accountId);
      final accountObjects = await _accountObjects(accountRoot.path);
      var accountTotal = 0;
      for (final object in accountObjects) {
        accountTotal += object.size;
      }
      if (accountTotal > accountSoftQuotaBytes) {
        await MediaIndex.shared.flush();
        final access = await _indexedLastAccess(accountId);
        accountTotal = await _evictOldest(accountObjects, accountTotal,
            accountSoftQuotaBytes, keep.path, access);
      }
      // 设备级：用进程内估计避免每次写入都全盘遍历；估计为 null 或超限时
      // 才做一次真实统计。
      final estimate = _deviceBytesEstimate;
      if (estimate == null) {
        _deviceBytesEstimate = await totalCachedBytes();
      } else {
        _deviceBytesEstimate = estimate + await _lengthOf(keep);
      }
      if ((_deviceBytesEstimate ?? 0) <= deviceHardQuotaBytes) return;
      final all = await _files();
      final objects = <_CacheObject>[];
      var deviceTotal = 0;
      for (final file in all) {
        try {
          final stat = await file.stat();
          objects.add(_CacheObject(file, stat.size, stat.modified));
          deviceTotal += stat.size;
        } on FileSystemException {
          continue;
        }
      }
      _deviceBytesEstimate = deviceTotal;
      if (deviceTotal <= deviceHardQuotaBytes) return;
      // 设备兜底：先尝试回收无引用对象（GC 比淘汰更安全），再按 LRU 淘汰。
      await collectGarbage(accountId, triggeredByQuota: true);
      final access = await _indexedLastAccess(accountId);
      deviceTotal = await _evictOldest(objects, deviceTotal,
          deviceHardQuotaBytes, keep.path, access);
      _deviceBytesEstimate = deviceTotal;
    } on FileSystemException {
      /* Cache quota maintenance is best effort. */
    } finally {
      if (watch != null) {
        MediaCacheMetrics.evictionMicros += watch.elapsedMicroseconds;
      }
      MediaCacheMetrics.evictions++;
    }
  }

  /// 对象名 → 最后访问时间（取该对象所有引用行的最大值）。
  static Future<Map<String, DateTime>> _indexedLastAccess(
      String accountId) async {
    final access = <String, DateTime>{};
    try {
      for (final entry in await MediaIndex.shared.entriesForAccount(accountId)) {
        final at = DateTime.fromMillisecondsSinceEpoch(entry.lastAccessAt);
        final current = access[entry.objectName];
        if (current == null || at.isAfter(current)) {
          access[entry.objectName] = at;
        }
      }
    } on Exception {
      // 索引不可用：退回 mtime 排序。
    }
    return access;
  }

  /// 按 LRU（索引 last_access → mtime）最旧优先删除，直到回到
  /// [targetBytes]；返回剩余总字节。跳过：keep、pinned、在途写入。
  static Future<int> _evictOldest(List<_CacheObject> objects, int total,
      int targetBytes, String keepPath,
      [Map<String, DateTime>? indexedAccess]) async {
    if (total <= targetBytes) return total;
    DateTime accessOf(_CacheObject object) {
      final indexed =
          indexedAccess?[object.file.uri.pathSegments.last];
      if (indexed == null) return object.modified;
      return indexed.isAfter(object.modified) ? indexed : object.modified;
    }

    objects.sort((a, b) => accessOf(a).compareTo(accessOf(b)));
    final keepKey = _pathKey(keepPath);
    for (final object in objects) {
      if (total <= targetBytes) break;
      if (_pathKey(object.file.path) == keepKey) continue;
      if (isPinned(object.file.path)) continue;
      if (_isActiveWrite(object.file.path)) continue;
      try {
        await object.file.delete();
        await _deleteQuietly(File('${object.file.path}.len'));
      } on FileSystemException {
        continue;
      }
      _deviceBytesEstimate = (_deviceBytesEstimate ?? total) - object.size;
      MediaCacheMetrics.evictedObjects++;
      MediaCacheMetrics.evictedBytes += object.size;
      total -= object.size;
    }
    return total;
  }

  /// 只登记一次本地对象访问（用于未索引/会话外对象，如相册首帧）：
  /// 批量 LRU，不产生同步落库，也不做任何哈希。
  static void touchLocalObject(String path) {
    MediaIndex.shared.touchPath(path);
  }

  static Future<int> _lengthOf(File file) async {
    try {
      return await file.length();
    } on FileSystemException {
      return 0;
    }
  }

  // —— pin / lease：正在使用的对象不得被淘汰或 GC ——

  /// 路径比较用的规范化键。
  ///
  /// 关键：`Directory.list()` 返回的路径分隔符/大小写可能与**构造**出来的
  /// 路径字符串不同（Windows 上尤其明显），直接字符串比较会把"同一个文件"
  /// 判成两个，导致 pin/在途写保护失效。这里统一规范化后再比较。
  static String _pathKey(String path) {
    if (path.isEmpty) return '';
    final normalized = path.replaceAll(r'\', '/');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static bool _isActiveWrite(String path) {
    if (_atomicWrites.isEmpty) return false;
    final key = _pathKey(path);
    for (final active in _atomicWrites.keys) {
      if (_pathKey(active) == key) return true;
    }
    return false;
  }

  /// 声明"该对象正在被使用"（视频播放/解码/上传下载）。
  static MediaCachePin pinPath(String path) {
    if (path.isEmpty) return MediaCachePin._('');
    final key = _pathKey(path);
    _pinned[key] = (_pinned[key] ?? 0) + 1;
    MediaCacheMetrics.pinnedPaths = _pinned.length;
    return MediaCachePin._(path);
  }

  static void unpinPath(String path) {
    final key = _pathKey(path);
    final next = (_pinned[key] ?? 0) - 1;
    if (next <= 0) {
      _pinned.remove(key);
    } else {
      _pinned[key] = next;
    }
    MediaCacheMetrics.pinnedPaths = _pinned.length;
  }

  static bool isPinned(String path) => _pinned.containsKey(_pathKey(path));

  @visibleForTesting
  static void clearPinsForTest() {
    _pinned.clear();
    MediaCacheMetrics.pinnedPaths = 0;
  }

  /// 垃圾回收：从 `refs/*.ref` **重算**引用数（不依赖计数器），删除
  /// "无引用 + 未 pin + 无在途写 + 超过保护期"的对象。
  ///
  /// [triggeredByQuota] 为真时由配额兜底触发（不影响报告语义）。
  static Future<MediaGcReport> collectGarbage(String accountId,
      {bool dryRun = false,
      Duration gracePeriod = gcGracePeriod,
      DateTime Function()? clock,
      bool triggeredByQuota = false}) async {
    final watch = MediaCacheMetrics.enabled ? (Stopwatch()..start()) : null;
    MediaCacheMetrics.gcRuns++;
    var scanned = 0, kept = 0, collected = 0, skippedPinned = 0, skippedYoung = 0;
    var bytes = 0;
    final removed = <String>{};
    try {
      final root = await _root(accountId);
      final now = (clock ?? DateTime.now)();
      // ① 真相源：refs/ 目录重算引用数。
      final referenced = <String, int>{};
      final refsDir = Directory('${root.path}/refs');
      if (await refsDir.exists()) {
        try {
          await for (final entity in refsDir.list(followLinks: false)) {
            if (entity is! File || !entity.path.endsWith('.ref')) continue;
            try {
              final name = (await entity.readAsString()).trim();
              if (name.isEmpty) continue;
              referenced[name] = (referenced[name] ?? 0) + 1;
            } on FileSystemException {
              continue;
            }
          }
        } on FileSystemException {
          // 引用目录不可读：本次不回收任何对象（保守，避免误删）。
          return MediaGcReport(
              scanned: 0,
              kept: 0,
              collected: 0,
              skippedPinned: 0,
              skippedYoung: 0,
              collectedBytes: 0,
              dryRun: dryRun,
              triggeredByQuota: triggeredByQuota,
              aborted: true);
        }
      }
      // ② 对象扫描。
      final objects = await _accountObjects(root.path);
      for (final object in objects) {
        scanned++;
        final name = object.file.uri.pathSegments.last;
        if ((referenced[name] ?? 0) > 0) {
          kept++;
          continue;
        }
        if (isPinned(object.file.path) ||
            _isActiveWrite(object.file.path)) {
          skippedPinned++;
          continue;
        }
        if (now.difference(object.modified) < gracePeriod) {
          skippedYoung++;
          continue;
        }
        if (!dryRun) {
          try {
            await object.file.delete();
            await _deleteQuietly(File('${object.file.path}.len'));
          } on FileSystemException {
            kept++;
            continue;
          }
        }
        removed.add(name);
        collected++;
        bytes += object.size;
      }
      if (!dryRun && removed.isNotEmpty) {
        await MediaIndex.shared.forgetObjects(accountId, removed);
        final estimate = _deviceBytesEstimate;
        if (estimate != null) {
          _deviceBytesEstimate = (estimate - bytes).clamp(0, 1 << 62);
        }
      }
    } on FileSystemException {
      /* Best effort. */
    } finally {
      if (watch != null) MediaCacheMetrics.gcMicros += watch.elapsedMicroseconds;
    }
    MediaCacheMetrics.gcCollectedObjects += collected;
    MediaCacheMetrics.gcCollectedBytes += bytes;
    return MediaGcReport(
      scanned: scanned,
      kept: kept,
      collected: collected,
      skippedPinned: skippedPinned,
      skippedYoung: skippedYoung,
      collectedBytes: bytes,
      dryRun: dryRun,
      triggeredByQuota: triggeredByQuota,
    );
  }
}

/// 一次 GC 的结果（无 PII，只有计数与字节）。
@immutable
final class MediaGcReport {
  const MediaGcReport({
    required this.scanned,
    required this.kept,
    required this.collected,
    required this.skippedPinned,
    required this.skippedYoung,
    required this.collectedBytes,
    required this.dryRun,
    this.triggeredByQuota = false,
    this.aborted = false,
  });

  final int scanned;
  final int kept;
  final int collected;
  final int skippedPinned;
  final int skippedYoung;
  final int collectedBytes;
  final bool dryRun;
  final bool triggeredByQuota;
  final bool aborted;

  @override
  String toString() => 'MediaGcReport(scanned: $scanned, kept: $kept, '
      'collected: $collected, pinned: $skippedPinned, young: $skippedYoung, '
      'bytes: $collectedBytes, dryRun: $dryRun, aborted: $aborted)';
}

/// pin 凭证：幂等释放，避免重复 unpin 造成计数下溢。
final class MediaCachePin {
  MediaCachePin._(this._path);
  final String _path;
  bool _released = false;

  String get path => _path;

  void release() {
    if (_released || _path.isEmpty) return;
    _released = true;
    MediaCache.unpinPath(_path);
  }
}

final class _CacheObject {
  const _CacheObject(this.file, this.size, this.modified);
  final File file;
  final int size;
  final DateTime modified;
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
  // 命中登记的 pending LRU touch 落库（不阻塞调用方）。
  unawaited(MediaIndex.shared.flush());
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
                accountId: key.accountId,
                contentSha256: key.contentSha256,
                variant: key.variant,
                familyId: key.familyId);
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
          var result = bytes ?? await file.readAsBytes();
          if (key.contentSha256 != null) {
            try {
              verifyMediaContent(result, key.contentSha256);
            } on FormatException {
              // 廉价命中路径可能漏掉"同尺寸且未改变 mtime"的极端篡改；
              // 这里是最后一道内容校验：判定损坏 → 删除对象 + 失效索引 →
              // 重新解密并落盘（修复，而不是把异常抛给 UI）。
              await MediaCache._discardCorruptObject(key, file);
              PerformanceMetrics.instance
                  .increment(PerformanceCounter.mediaDownload);
              final fresh = await decrypt();
              verifyMediaContent(fresh, key.contentSha256);
              await MediaCache.store(key.roomId, key.eventId, fresh,
                  accountId: key.accountId,
                  contentSha256: key.contentSha256,
                  variant: key.variant,
                  familyId: key.familyId);
              result = fresh;
            }
          }
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
      this.contentSha256,
      this.variant = MediaVariantKind.unknown,
      this.familyId});
  final String accountId;
  final String? contentSha256;
  String get cacheId => identity;

  /// Full authenticated source identity, including encryption descriptor.
  final String? sourceIdentity;

  /// 变体标记与媒体族锚点：**仅本地索引 metadata**，不参与身份/键，
  /// 不改变对象去重语义（同字节仍合并为一个对象）。
  final MediaVariantKind variant;
  final String? familyId;
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
