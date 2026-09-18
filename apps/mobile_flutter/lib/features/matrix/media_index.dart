import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'media_cache_metrics.dart';

/// 媒体变体（同一原始媒体不同字节 → 不同 object_hash，属正常现象）。
enum MediaVariantKind {
  unknown('unknown'),
  original('original'),
  thumbnail('thumbnail'),
  preview('preview'),
  body('body'),
  poster('poster'),
  video('video'),
  file('file');

  const MediaVariantKind(this.label);

  final String label;

  static MediaVariantKind fromLabel(String? value) => values.firstWhere(
        (item) => item.label == value,
        orElse: () => MediaVariantKind.unknown,
      );
}

/// 索引条目：**逻辑引用 → 对象 → 本地路径**的加速映射。
///
/// 不含明文媒体内容、不含 userId/roomId/eventId 明文、不含 token/密钥。
/// [accountNamespace] 与 [referenceKey] 均为 sha256 摘要。
@immutable
final class MediaIndexEntry {
  const MediaIndexEntry({
    required this.accountNamespace,
    required this.referenceKey,
    required this.objectHash,
    required this.objectName,
    required this.sizeBytes,
    required this.createdAt,
    required this.lastAccessAt,
    required this.verifiedAt,
    this.variant = MediaVariantKind.unknown,
    this.familyId,
    this.mimeType,
    this.width,
    this.height,
    this.durationMs,
  });

  final String accountNamespace;
  final String referenceKey;
  final String objectHash;
  final String objectName;
  final int sizeBytes;
  final int createdAt;
  final int lastAccessAt;

  /// > 0 表示该条目在写入或完整校验时被确认过内容与摘要一致；
  /// 只有这种情况才允许走"廉价校验"命中路径。
  final int verifiedAt;
  final MediaVariantKind variant;
  final String? familyId;
  final String? mimeType;
  final int? width;
  final int? height;
  final int? durationMs;

  bool get verified => verifiedAt > 0;

  MediaIndexEntry copyWith({int? lastAccessAt, int? verifiedAt}) =>
      MediaIndexEntry(
        accountNamespace: accountNamespace,
        referenceKey: referenceKey,
        objectHash: objectHash,
        objectName: objectName,
        sizeBytes: sizeBytes,
        createdAt: createdAt,
        lastAccessAt: lastAccessAt ?? this.lastAccessAt,
        verifiedAt: verifiedAt ?? this.verifiedAt,
        variant: variant,
        familyId: familyId,
        mimeType: mimeType,
        width: width,
        height: height,
        durationMs: durationMs,
      );

  @override
  String toString() => 'MediaIndexEntry(object: ${objectHash.substring(0, 8)}…, '
      'size: $sizeBytes, variant: ${variant.label}, verified: $verified)';
}

/// 本地媒体索引（Phase 2，SQLite）。
///
/// 定位：**加速层，不是真相源**。真相源仍是 `objects/<hash>` + `refs/<logical-ref>`；
/// 删掉整张索引表也不会丢媒体，只会退回"每次命中完整校验"。
///
/// 设计要点：
/// - 账号隔离：所有行带 `account_namespace = sha256(accountId)`；
/// - 懒加载：首次用到时才打开数据库，启动不扫描、不搬家；
/// - 失败降级：[degraded] 为真时所有查询返回 null、写入静默丢弃，
///   调用方自动走 legacy 路径（索引坏掉不影响聊天可用）；
/// - 批量 touch：命中只登记内存 pending，合并成一次事务（60s 内同对象至多一次）。
final class MediaIndex {
  MediaIndex({
    String? databasePath,
    DatabaseFactory? factory,
    Future<String> Function()? supportDirectory,
    this.touchDebounce = const Duration(seconds: 60),
    this.maxPendingTouches = 32,
    this.hotCapacity = 512,
    DateTime Function()? clock,
  })  : _path = databasePath,
        _factory = factory ?? databaseFactoryFfi,
        _directory = supportDirectory ?? _defaultDirectory,
        _now = clock ?? DateTime.now;

  /// 进程级单例。生产依赖矩阵 SDK 在初始化本地库时对 `sqlite3` 的全局
  /// `open` 覆盖（`SQfLiteEncryptionHelper.ffiInit`）；索引若在覆盖之前
  /// 打开失败会**降级为 legacy 行为**并在 [retryAfterDegrade] 后自动重试。
  static MediaIndex? _shared;

  static MediaIndex get shared => _shared ??= MediaIndex();

  @visibleForTesting
  static void overrideShared(MediaIndex? index) {
    _shared = index;
  }

  static Future<String> _defaultDirectory() async =>
      (await getApplicationSupportDirectory()).path;

  final String? _path;
  final DatabaseFactory _factory;
  final Future<String> Function() _directory;
  final DateTime Function() _now;

  /// 同一对象 last_access 的最小刷新间隔。
  final Duration touchDebounce;

  /// pending touch 达到该数量即立刻合并落库。
  final int maxPendingTouches;

  /// 进程内热条目上限（避免热路径查询数据库）。
  final int hotCapacity;

  static const schemaVersion = 1;
  static const _table = 'media_index';

  /// 降级后的重试间隔：初始化时序问题（如 sqlite3 动态库尚未覆盖）不应
  /// 让索引在整个进程生命周期内永久失效。
  static const retryAfterDegrade = Duration(seconds: 30);

  Database? _database;
  Future<Database>? _opening;
  bool _degraded = false;
  String? _degradedReason;
  DateTime? _degradedAt;

  /// 索引不可用（打开/查询失败）→ 调用方必须回退 legacy 行为。
  bool get degraded => _degraded;

  @visibleForTesting
  String? get degradedReason => _degradedReason;

  final _hot = <String, MediaIndexEntry>{};
  final _pendingTouches = <String, _PendingTouch>{};

  /// 本进程内已知被索引的引用/对象：只有**未索引**对象才需要 mtime 兜底
  /// （已索引对象的 LRU 走索引列，绝不能改写 mtime——mtime 同时是
  /// "内容最后修改时间"的廉价完整性锚点）。
  final _indexedReferences = <String>{};
  final _indexedObjects = <String>{};
  DateTime? _lastFlushAt;

  int get pendingTouchCount => _pendingTouches.length;

  String referenceKeyFor(String roomId, String eventId) =>
      sha256.convert(utf8.encode(jsonEncode([roomId, eventId]))).toString();

  String namespaceFor(String accountId) =>
      sha256.convert(utf8.encode(accountId)).toString();

  static String _hotKey(String namespace, String referenceKey) =>
      '$namespace|$referenceKey';

  Future<String> databasePath() async => _path ??
      p.join(await _directory(), 'chatflow_media_index_v1.db');

  Future<Database?> _open() async {
    if (_degraded) {
      final since = _degradedAt;
      if (since != null && _now().difference(since) < retryAfterDegrade) {
        return null;
      }
      // 到点重试（初始化时序问题自愈）。
      _degraded = false;
      _degradedReason = null;
      _degradedAt = null;
    }
    final existing = _database;
    if (existing != null) return existing;
    try {
      return await (_opening ??= _openDatabase()).catchError((Object error) {
        _markDegraded(error);
        throw error;
      });
    } catch (_) {
      return null;
    }
  }

  Future<Database> _openDatabase() async {
    final database = await _factory.openDatabase(
      await databasePath(),
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (db, _) async {
          await db.execute('''
CREATE TABLE $_table (
  account_namespace TEXT NOT NULL,
  reference_key TEXT NOT NULL,
  object_hash TEXT NOT NULL,
  object_name TEXT NOT NULL,
  variant TEXT NOT NULL DEFAULT 'unknown',
  family_id TEXT,
  size_bytes INTEGER NOT NULL,
  mime_type TEXT,
  width INTEGER,
  height INTEGER,
  duration_ms INTEGER,
  created_at INTEGER NOT NULL,
  last_access_at INTEGER NOT NULL,
  verified_at INTEGER NOT NULL,
  schema_version INTEGER NOT NULL DEFAULT $schemaVersion,
  PRIMARY KEY (account_namespace, reference_key)
)''');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS media_index_object ON $_table (account_namespace, object_hash)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS media_index_access ON $_table (account_namespace, last_access_at)');
        },
        onUpgrade: (db, from, to) async {
          // 索引可丢弃重建：版本不匹配时清空重来（对象与 refs 不受影响）。
          await db.delete(_table);
        },
      ),
    );
    _database = database;
    return database;
  }

  void _markDegraded(Object error) {
    _degraded = true;
    _degradedReason = error.toString();
    _degradedAt = _now();
    _opening = null;
    _database = null;
    debugPrint('[chatflow/mediaindex] degraded: ${error.runtimeType}');
  }

  /// 测试/维护：把索引标记为可用并清空进程内状态。
  @visibleForTesting
  void resetForTest() {
    _database = null;
    _opening = null;
    _degraded = false;
    _degradedReason = null;
    _degradedAt = null;
    _hot.clear();
    _pendingTouches.clear();
    _indexedReferences.clear();
    _indexedObjects.clear();
    _lastFlushAt = null;
  }

  MediaIndexEntry? _hotLookup(String namespace, String referenceKey) {
    final key = _hotKey(namespace, referenceKey);
    final entry = _hot.remove(key);
    if (entry == null) return null;
    _hot[key] = entry; // LRU 刷新
    return entry;
  }

  void _hotStore(MediaIndexEntry entry) {
    final key = _hotKey(entry.accountNamespace, entry.referenceKey);
    _hot.remove(key);
    _hot[key] = entry;
    _indexedReferences.add(key);
    _indexedObjects.add('${entry.accountNamespace}|${entry.objectHash}');
    while (_hot.length > hotCapacity) {
      _hot.remove(_hot.keys.first);
    }
  }

  /// 查询：进程内热条目 → SQLite。
  Future<MediaIndexEntry?> lookup(
      String accountId, String roomId, String eventId) async {
    final watch = MediaCacheMetrics.enabled ? (Stopwatch()..start()) : null;
    try {
      final namespace = namespaceFor(accountId);
      final referenceKey = referenceKeyFor(roomId, eventId);
      final hot = _hotLookup(namespace, referenceKey);
      if (hot != null && hot.verified) {
        MediaCacheMetrics.indexHits++;
        return hot;
      }
      final db = await _open();
      if (db == null) {
        MediaCacheMetrics.indexMisses++;
        return null;
      }
      await _flushIfDebounced();
      final rows = await db.query(_table,
          where: 'account_namespace=? AND reference_key=?',
          whereArgs: [namespace, referenceKey],
          limit: 1);
      if (rows.isEmpty) {
        MediaCacheMetrics.indexMisses++;
        return null;
      }
      final entry = _fromRow(rows.single);
      if (!entry.verified) {
        // 未校验条目不可用于廉价命中；交给 legacy 完整校验后重新写入。
        MediaCacheMetrics.indexMisses++;
        return null;
      }
      _hotStore(entry);
      MediaCacheMetrics.indexHits++;
      return entry;
    } on Exception catch (error) {
      _markDegraded(error);
      return null;
    } finally {
      if (watch != null) MediaCacheMetrics.recordIndexLookup(watch);
    }
  }

  /// 按对象摘要查询（`contentSha256` 寻址路径使用）。
  Future<MediaIndexEntry?> lookupObject(
      String accountId, String objectHash) async {
    final watch = MediaCacheMetrics.enabled ? (Stopwatch()..start()) : null;
    try {
      final namespace = namespaceFor(accountId);
      for (final entry in _hot.values) {
        if (entry.accountNamespace == namespace &&
            entry.objectHash == objectHash &&
            entry.verified) {
          MediaCacheMetrics.indexHits++;
          return entry;
        }
      }
      final db = await _open();
      if (db == null) {
        MediaCacheMetrics.indexMisses++;
        return null;
      }
      await _flushIfDebounced();
      final rows = await db.query(_table,
          where: 'account_namespace=? AND object_hash=? AND verified_at>0',
          whereArgs: [namespace, objectHash],
          limit: 1);
      if (rows.isEmpty) {
        MediaCacheMetrics.indexMisses++;
        return null;
      }
      final entry = _fromRow(rows.single);
      _hotStore(entry);
      MediaCacheMetrics.indexHits++;
      return entry;
    } on Exception catch (error) {
      _markDegraded(error);
      return null;
    } finally {
      if (watch != null) MediaCacheMetrics.recordIndexLookup(watch);
    }
  }

  /// 写入（对象成功落盘后调用）：`verifiedAt > 0` 表示内容与摘要已确认一致。
  Future<void> put(MediaIndexEntry entry) async {
    _hotStore(entry);
    final db = await _open();
    if (db == null) return;
    try {
      await db.insert(_table, _toRow(entry),
          conflictAlgorithm: ConflictAlgorithm.replace);
      MediaCacheMetrics.indexWrites++;
      MediaCacheMetrics.recordWrite(0);
    } on Exception catch (error) {
      _markDegraded(error);
    }
  }

  /// 命中登记（内存 pending，合并落库）——命中路径不得产生同步磁盘写。
  ///
  /// [objectPath] 只对**未索引**对象用于 mtime 兜底（LRU 排序）；已索引对象
  /// 的 mtime 必须保持不变（它是内容完整性锚点），LRU 走索引列。
  void touch(String accountId, String roomId, String eventId,
      {String? objectPath}) {
    final namespace = namespaceFor(accountId);
    final referenceKey = referenceKeyFor(roomId, eventId);
    final entry = _hotLookup(namespace, referenceKey);
    if (entry != null) {
      _hotStore(entry.copyWith(lastAccessAt: _now().millisecondsSinceEpoch));
    }
    final key = _hotKey(namespace, referenceKey);
    _pendingTouches[key] = _PendingTouch(
      namespace: namespace,
      referenceKey: referenceKey,
      at: _now().millisecondsSinceEpoch,
      objectPath: _indexedReferences.contains(key) ? null : objectPath,
    );
    if (_pendingTouches.length >= maxPendingTouches) {
      unawaited(flush());
    }
  }

  /// 命中登记（按对象摘要，`contentSha256` 寻址路径使用）。
  void touchObject(String accountId, String objectHash, {String? objectPath}) {
    final namespace = namespaceFor(accountId);
    for (final entry in _hot.values.toList()) {
      if (entry.accountNamespace == namespace &&
          entry.objectHash == objectHash) {
        _hotStore(
            entry.copyWith(lastAccessAt: _now().millisecondsSinceEpoch));
        break;
      }
    }
    _pendingTouches['$namespace|object:$objectHash'] = _PendingTouch(
      namespace: namespace,
      objectHash: objectHash,
      at: _now().millisecondsSinceEpoch,
      objectPath: _indexedObjects.contains('$namespace|$objectHash')
          ? null
          : objectPath,
    );
    if (_pendingTouches.length >= maxPendingTouches) {
      unawaited(flush());
    }
  }

  /// 只更新 LRU（未索引对象/会话外对象，如相册首帧）：登记 mtime 待刷新。
  /// 不查库、不写库、不算哈希。
  void touchPath(String path) {
    if (path.isEmpty) return;
    _pendingTouches['mtime:$path'] = _PendingTouch(
      namespace: '',
      at: _now().millisecondsSinceEpoch,
      objectPath: path,
    );
    if (_pendingTouches.length >= maxPendingTouches) unawaited(flush());
  }

  Future<void> _flushIfDebounced() async {
    final last = _lastFlushAt;
    if (_pendingTouches.isEmpty || last == null) {
      _lastFlushAt ??= _now();
      if (last == null) return;
    }
    if (_now().difference(last) >= touchDebounce) await flush();
  }

  /// 合并落库：一条事务批量更新 last_access_at；未索引对象逐个更新 mtime。
  Future<void> flush() async {
    if (_pendingTouches.isEmpty) return;
    final pending = List<_PendingTouch>.of(_pendingTouches.values);
    _pendingTouches.clear();
    _lastFlushAt = _now();
    MediaCacheMetrics.touchFlushes++;
    MediaCacheMetrics.touchedObjects += pending.length;
    final db = await _open();
    if (db != null) {
      try {
        await db.transaction((tx) async {
          for (final item in pending) {
            if (item.objectHash != null) {
              await tx.update(
                _table,
                {'last_access_at': item.at},
                where: 'account_namespace=? AND object_hash=?',
                whereArgs: [item.namespace, item.objectHash],
              );
            } else if (item.referenceKey != null) {
              await tx.update(
                _table,
                {'last_access_at': item.at},
                where: 'account_namespace=? AND reference_key=?',
                whereArgs: [item.namespace, item.referenceKey],
              );
            }
          }
        });
      } on Exception catch (error) {
        _markDegraded(error);
      }
    }
    // 未索引对象：mtime 是 LRU 的唯一依据（去重后逐个更新）。
    for (final path in {
      for (final item in pending)
        if (item.objectPath != null) item.objectPath!
    }) {
      try {
        await File(path).setLastModified(_now());
      } on Exception {
        // mtime 更新失败不影响命中（下次命中会再登记）。
      }
    }
  }

  /// 删除引用对应的索引行（撤回/删除引用时调用；对象不删）。
  Future<void> invalidate(String accountId, String roomId, String eventId) async {
    final namespace = namespaceFor(accountId);
    final referenceKey = referenceKeyFor(roomId, eventId);
    _hot.remove(_hotKey(namespace, referenceKey));
    _pendingTouches.remove(_hotKey(namespace, referenceKey));
    final db = await _open();
    if (db == null) return;
    try {
      await db.delete(_table,
          where: 'account_namespace=? AND reference_key=?',
          whereArgs: [namespace, referenceKey]);
    } on Exception catch (error) {
      _markDegraded(error);
    }
  }

  /// 删除若干对象对应的索引行（GC/淘汰后调用）。
  Future<void> forgetObjects(String accountId, Set<String> objectNames) async {
    if (objectNames.isEmpty) return;
    final namespace = namespaceFor(accountId);
    _hot.removeWhere((_, entry) =>
        entry.accountNamespace == namespace &&
        objectNames.contains(entry.objectName));
    final db = await _open();
    if (db == null) return;
    try {
      await db.transaction((tx) async {
        for (final name in objectNames) {
          await tx.delete(_table,
              where: 'account_namespace=? AND object_name=?',
              whereArgs: [namespace, name]);
        }
      });
    } on Exception catch (error) {
      _markDegraded(error);
    }
  }

  /// 账号级清理（账号登出/清空聊天数据时调用）。
  Future<void> clearAccount(String accountId) async {
    final namespace = namespaceFor(accountId);
    _hot.removeWhere((_, entry) => entry.accountNamespace == namespace);
    _pendingTouches.removeWhere((_, item) => item.namespace == namespace);
    final db = await _open();
    if (db == null) return;
    try {
      await db.delete(_table,
          where: 'account_namespace=?', whereArgs: [namespace]);
    } on Exception catch (error) {
      _markDegraded(error);
    }
  }

  /// 账号内所有"每个引用一行"的条目（配额/GC/维护使用）。
  Future<List<MediaIndexEntry>> entriesForAccount(String accountId) async {
    final db = await _open();
    if (db == null) return const [];
    try {
      final rows = await db.query(_table,
          where: 'account_namespace=?', whereArgs: [namespaceFor(accountId)]);
      return [for (final row in rows) _fromRow(row)];
    } on Exception catch (error) {
      _markDegraded(error);
      return const [];
    }
  }

  Future<void> close() async {
    await flush();
    final db = _database;
    _database = null;
    _opening = null;
    if (db != null) {
      try {
        await db.close();
      } on Exception {
        // 关闭失败不影响后续（下次懒打开会重建句柄）。
      }
    }
  }

  static MediaIndexEntry _fromRow(Map<String, Object?> row) => MediaIndexEntry(
        accountNamespace: row['account_namespace']! as String,
        referenceKey: row['reference_key']! as String,
        objectHash: row['object_hash']! as String,
        objectName: row['object_name']! as String,
        sizeBytes: (row['size_bytes'] as int?) ?? 0,
        createdAt: (row['created_at'] as int?) ?? 0,
        lastAccessAt: (row['last_access_at'] as int?) ?? 0,
        verifiedAt: (row['verified_at'] as int?) ?? 0,
        variant: MediaVariantKind.fromLabel(row['variant'] as String?),
        familyId: row['family_id'] as String?,
        mimeType: row['mime_type'] as String?,
        width: row['width'] as int?,
        height: row['height'] as int?,
        durationMs: row['duration_ms'] as int?,
      );

  static Map<String, Object?> _toRow(MediaIndexEntry entry) => {
        'account_namespace': entry.accountNamespace,
        'reference_key': entry.referenceKey,
        'object_hash': entry.objectHash,
        'object_name': entry.objectName,
        'variant': entry.variant.label,
        'family_id': entry.familyId,
        'size_bytes': entry.sizeBytes,
        'mime_type': entry.mimeType,
        'width': entry.width,
        'height': entry.height,
        'duration_ms': entry.durationMs,
        'created_at': entry.createdAt,
        'last_access_at': entry.lastAccessAt,
        'verified_at': entry.verifiedAt,
        'schema_version': schemaVersion,
      };
}

final class _PendingTouch {
  const _PendingTouch({
    required this.namespace,
    required this.at,
    this.referenceKey,
    this.objectHash,
    this.objectPath,
  });

  final String namespace;
  final int at;
  final String? referenceKey;
  final String? objectHash;
  final String? objectPath;
}
