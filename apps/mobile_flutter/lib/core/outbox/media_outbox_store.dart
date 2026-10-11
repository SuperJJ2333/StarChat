import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../matrix_local_binding.dart';

/// Persistent identity, independent of a route and of device-id rotation.
final class MediaOutboxOwner {
  const MediaOutboxOwner(
      {required this.accountId,
      required this.homeserver,
      required this.generation});
  factory MediaOutboxOwner.fromBinding(MatrixLocalBinding binding) =>
      MediaOutboxOwner(
          accountId: binding.matrixUserId,
          homeserver: binding.homeserver,
          generation: binding.databaseGeneration);
  final String accountId, homeserver, generation;
  String get scope {
    if ([accountId, homeserver, generation].any((v) => v.isEmpty)) {
      throw const MediaOutboxException('owner-unavailable');
    }
    return sha256
        .convert(utf8.encode(jsonEncode([accountId, homeserver, generation])))
        .toString();
  }
}

enum MediaOutboxStage {
  preparing,
  queued,
  sending,
  ackUnknown,
  failed,
  sent,
  canceled
}

final class MediaOutboxException implements Exception {
  const MediaOutboxException(this.reason);
  final String reason;
  String get userMessage {
    final memoryLimit =
        RegExp(r'^memory-limit:([0-9]{1,12})$').firstMatch(reason);
    if (memoryLimit != null) {
      return '附件超过当前内存预算（此操作最多 ${memoryLimit[1]} 字节），请缩小或压缩后重试';
    }
    return switch (reason) {
      'low-space' => '存储空间不足，请释放空间后重新选择附件',
      'pending-capacity' || 'queue-full' => '待发附件暂存已满，请发送或取消现有附件后重试',
      'source-missing' ||
      'source-incomplete' ||
      'source-changed' =>
        '待发附件不可用，请重新选择；原消息未确认送达',
      'permission-denied' => '当前会话不可发送，请检查会话权限',
      'owner-unavailable' => '账号已变化，请返回原账号查看待发附件',
      'admission-rejected' => '附件已保留，请稍后重试发送',
      'ack-unknown' => '尚未确认送达，重试将沿用原消息编号',
      _ => '附件未能安全保存，请稍后重试',
    };
  }

  @override
  String toString() => 'MediaOutboxException($reason)';
}

/// Only local routing/file metadata. No event body or encryption material.
final class MediaOutboxTask {
  MediaOutboxTask.fromRow(Map<String, Object?> row)
      : txid = row['txid']! as String,
        roomId = row['room_id']! as String,
        ownerScope = row['owner_scope']! as String,
        mimeType = row['mime_type']! as String,
        filename = row['filename']! as String,
        durationMs = row['duration_ms'] as int?,
        prepared = row['prepared'] == 1,
        asFile = row['as_file'] == 1,
        width = row['width'] as int?,
        height = row['height'] as int?,
        length = row['length']! as int,
        digest = row['digest'] as String?,
        stage = MediaOutboxStage.values.byName(row['stage']! as String),
        attempts = row['attempts']! as int,
        failure = row['failure'] as String?,
        eventId = row['event_id'] as String?,
        nextRetryAt = row['next_retry_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['next_retry_at']! as int);
  final String txid, roomId, ownerScope, mimeType, filename;
  final int? durationMs;
  final bool prepared, asFile;
  final int? width, height;
  final int length, attempts;
  final String? digest, failure, eventId;
  final DateTime? nextRetryAt;
  final MediaOutboxStage stage;
  bool get terminal =>
      stage == MediaOutboxStage.sent || stage == MediaOutboxStage.canceled;
}

/// Native fixed-directory policy. There is deliberately no cache/temp fallback.
final class PendingMediaDirectory {
  static const _channel = MethodChannel('chatflow/media_storage');
  static Future<Map<Object?, Object?>> _inspect() async {
    final result = await _channel
        .invokeMapMethod<Object?, Object?>('pendingMediaDirectory');
    if (result == null ||
        result['protected'] != true ||
        result['backupExcluded'] != true ||
        result['path'] is! String ||
        (result['path']! as String).isEmpty ||
        result['availableBytes'] is! int ||
        (result['availableBytes']! as int) < 0) {
      throw const MediaOutboxException('storage-protection-unavailable');
    }
    return result;
  }

  static Future<Directory> directory() async =>
      Directory((await _inspect())['path']! as String);
  static Future<int> availableBytes() async =>
      (await _inspect())['availableBytes']! as int;

  static Future<void> seal(String scope, String? sourceId) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
        'sealPendingFiles',
        {'scope': scope, if (sourceId != null) 'sourceId': sourceId});
    if (result?['protected'] != true || result?['backupExcluded'] != true) {
      throw const MediaOutboxException('storage-protection-unavailable');
    }
  }
}

/// Independent, non-evictable account domain. Existing Matrix/text DBs are not
/// opened or migrated here. Preparing intent survives an interrupted file copy.
final class SqliteMediaOutboxStore {
  SqliteMediaOutboxStore({
    required this.owner,
    Future<Directory> Function()? directory,
    Future<int> Function()? availableBytes,
    Future<void> Function(String scope, String? sourceId)? seal,
    DatabaseFactory? factory,
    this.maxRetainedBytes = 512 * 1024 * 1024,
    this.checkpoint,
  })  : _directory = directory ?? PendingMediaDirectory.directory,
        _availableBytes =
            availableBytes ?? PendingMediaDirectory.availableBytes,
        _seal = seal ?? PendingMediaDirectory.seal,
        _factory = factory ?? databaseFactoryFfi;
  final MediaOutboxOwner owner;
  final Future<Directory> Function() _directory;
  final Future<int> Function() _availableBytes;
  final Future<void> Function(String scope, String? sourceId) _seal;
  final DatabaseFactory _factory;
  final int maxRetainedBytes;

  /// Deterministic process-boundary seam, never installed by production.
  final Future<void> Function(String boundary)? checkpoint;
  Future<Database>? _opening;
  Directory? _root;
  Future<void> _writes = Future<void>.value();
  final _writingSources = <String>{};
  final _canceledSources = <String>{};
  static const chunkBytes = 64 * 1024;
  static const reserveBytes = 16 * 1024 * 1024;
  static const maxPending = 128;

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<Database> _db() =>
      _opening ??= _open().onError((Object error, StackTrace stack) {
        _opening = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<Database> _open() async {
    final root = Directory(p.join((await _directory()).path, owner.scope));
    await _requireType(root.path, FileSystemEntityType.directory,
        allowMissing: true);
    await root.create(recursive: true);
    final sources = Directory(p.join(root.path, 'sources'));
    await _requireType(sources.path, FileSystemEntityType.directory,
        allowMissing: true);
    await sources.create();
    _root = root;
    for (final suffix in ['', '-journal', '-wal', '-shm']) {
      await _requireType(
          p.join(root.path, 'manifest-v1.db$suffix'), FileSystemEntityType.file,
          allowMissing: true);
    }
    final db = await _factory.openDatabase(p.join(root.path, 'manifest-v1.db'),
        options: OpenDatabaseOptions(
            version: 2,
            singleInstance: false,
            onUpgrade: (db, old, _) async {
              if (old < 2) {
                await db.execute(
                    'ALTER TABLE media_tasks ADD COLUMN prepared INTEGER NOT NULL DEFAULT 0');
                await db.execute(
                    'ALTER TABLE media_tasks ADD COLUMN as_file INTEGER NOT NULL DEFAULT 0');
                await db.execute(
                    'ALTER TABLE media_tasks ADD COLUMN width INTEGER');
                await db.execute(
                    'ALTER TABLE media_tasks ADD COLUMN height INTEGER');
              }
            },
            onCreate: (db, _) async {
              await db.execute('CREATE TABLE media_tasks ('
                  'txid TEXT PRIMARY KEY, owner_scope TEXT NOT NULL, room_id TEXT NOT NULL, '
                  'mime_type TEXT NOT NULL, filename TEXT NOT NULL, duration_ms INTEGER, '
                  'prepared INTEGER NOT NULL DEFAULT 0, as_file INTEGER NOT NULL DEFAULT 0, width INTEGER, height INTEGER, '
                  'length INTEGER NOT NULL, digest TEXT, stage TEXT NOT NULL, '
                  'attempts INTEGER NOT NULL DEFAULT 0, failure TEXT, event_id TEXT, '
                  'next_retry_at INTEGER, created_at INTEGER NOT NULL)');
            }));
    try {
      await db.execute('CREATE INDEX IF NOT EXISTS media_retained '
          'ON media_tasks(owner_scope) WHERE length > 0');
      await _seal(owner.scope, null);
      return db;
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  File _source(String txid) => File(p.join(
      _root!.path, 'sources', '${sha256.convert(utf8.encode(txid))}.bin'));

  static Future<void> _requireType(String path, FileSystemEntityType expected,
      {bool allowMissing = false}) async {
    final actual = await FileSystemEntity.type(path, followLinks: false);
    if (actual != expected &&
        !(allowMissing && actual == FileSystemEntityType.notFound)) {
      throw const MediaOutboxException('storage-protection-unavailable');
    }
  }

  Future<MediaOutboxTask?> byTxid(String txid) async {
    final rows = await (await _db()).query('media_tasks',
        where: 'txid = ? AND owner_scope = ?',
        whereArgs: [txid, owner.scope],
        limit: 1);
    return rows.isEmpty ? null : MediaOutboxTask.fromRow(rows.single);
  }

  Future<List<MediaOutboxTask>> pending() async => [
        for (final row in await (await _db()).query('media_tasks',
            where: 'owner_scope = ? AND stage NOT IN (?, ?)',
            whereArgs: [owner.scope, 'sent', 'canceled'],
            orderBy: 'created_at, txid'))
          MediaOutboxTask.fromRow(row),
      ];

  Future<MediaOutboxTask> persistFile({
    required String txid,
    required String roomId,
    required File source,
    required String mimeType,
    required String filename,
    int? durationMs,
    bool prepared = false,
    bool asFile = false,
    int? width,
    int? height,
    bool Function()? isCurrentOwner,
  }) =>
      _persist(
          txid: txid,
          roomId: roomId,
          source: source,
          mimeType: mimeType,
          filename: filename,
          durationMs: durationMs,
          prepared: prepared,
          asFile: asFile,
          width: width,
          height: height,
          isCurrentOwner: isCurrentOwner);

  Future<MediaOutboxTask> persistBytes({
    required String txid,
    required String roomId,
    required Uint8List bytes,
    required String mimeType,
    required String filename,
    int? durationMs,
    bool prepared = false,
    bool asFile = false,
    int? width,
    int? height,
    bool Function()? isCurrentOwner,
  }) =>
      _persist(
          txid: txid,
          roomId: roomId,
          bytes: bytes,
          mimeType: mimeType,
          filename: filename,
          durationMs: durationMs,
          prepared: prepared,
          asFile: asFile,
          width: width,
          height: height,
          isCurrentOwner: isCurrentOwner);

  Future<MediaOutboxTask> persistResolvedFile({
    required String txid,
    required String roomId,
    required Future<File> Function() resolve,
    required String mimeType,
    required String filename,
    bool Function()? isCurrentOwner,
  }) =>
      _persist(
          txid: txid,
          roomId: roomId,
          loadFile: resolve,
          mimeType: mimeType,
          filename: filename,
          isCurrentOwner: isCurrentOwner);

  /// Record intent before a platform resolver, so interrupted preparation has
  /// an actionable durable outcome even when its callback cannot be restored.
  Future<MediaOutboxTask> persistPreparedBytes(
          {required String txid,
          required String roomId,
          required Future<Uint8List> Function() load,
          required String mimeType,
          required String filename,
          int? durationMs,
          bool prepared = false,
          bool asFile = false,
          int? width,
          int? height,
          bool Function()? isCurrentOwner}) =>
      _persist(
          txid: txid,
          roomId: roomId,
          loadBytes: load,
          mimeType: mimeType,
          filename: filename,
          durationMs: durationMs,
          prepared: prepared,
          asFile: asFile,
          width: width,
          height: height,
          isCurrentOwner: isCurrentOwner);

  Future<MediaOutboxTask> _persist(
          {required String txid,
          required String roomId,
          File? source,
          Future<File> Function()? loadFile,
          Uint8List? bytes,
          Future<Uint8List> Function()? loadBytes,
          required String mimeType,
          required String filename,
          int? durationMs,
          bool prepared = false,
          bool asFile = false,
          int? width,
          int? height,
          bool Function()? isCurrentOwner}) =>
      _serial(() async {
        void checkOwner() {
          if (_canceledSources.contains(txid)) {
            throw const MediaOutboxException('canceled');
          }
          if (isCurrentOwner?.call() == false) {
            throw const MediaOutboxException('owner-unavailable');
          }
        }

        checkOwner();
        // Re-read the native protection/space policy on every admission,
        // including retries of an existing intent. No cache fallback.
        final availableBeforePreparation = await _availableBytes();
        checkOwner();
        if (txid.isEmpty ||
            txid.length > 512 ||
            roomId.isEmpty ||
            roomId.length > 1024 ||
            mimeType.length > 256 ||
            filename.length > 1024 ||
            (durationMs != null && durationMs < 0) ||
            (width != null && (width <= 0 || width > 100000)) ||
            (height != null && (height <= 0 || height > 100000))) {
          throw const MediaOutboxException('invalid-metadata');
        }
        final existing = await byTxid(txid);
        checkOwner();
        if (existing != null) {
          if (existing.roomId != roomId ||
              existing.mimeType != mimeType ||
              existing.filename != filename ||
              existing.durationMs != durationMs ||
              existing.prepared != prepared ||
              existing.asFile != asFile ||
              existing.width != width ||
              existing.height != height) {
            throw const MediaOutboxException('transaction-conflict');
          }
          return existing;
        }
        if ((await pending()).length >= maxPending) {
          throw const MediaOutboxException('queue-full');
        }
        final db = await _db();
        checkOwner();
        await db.insert('media_tasks', {
          'txid': txid,
          'owner_scope': owner.scope,
          'room_id': roomId,
          'mime_type': mimeType,
          'filename': filename,
          'duration_ms': durationMs,
          'prepared': prepared ? 1 : 0,
          'as_file': asFile ? 1 : 0,
          'width': width,
          'height': height,
          'length': 0,
          'stage': 'preparing',
          'created_at': DateTime.now().millisecondsSinceEpoch
        });
        await checkpoint?.call('intent');
        final target = _source(txid);
        final temporary = File('${target.path}.part');
        _writingSources.add(txid);
        Object? preparationFailure;
        try {
          if (availableBeforePreparation < reserveBytes) {
            throw const MediaOutboxException('low-space');
          }
          Uint8List? content;
          try {
            source ??= await loadFile?.call();
            checkOwner();
            content = bytes ?? await loadBytes?.call();
          } on Exception catch (error) {
            preparationFailure = error;
            rethrow;
          }
          checkOwner();
          final stat = await source?.stat();
          checkOwner();
          if (source != null && stat?.type != FileSystemEntityType.file) {
            throw const MediaOutboxException('source-missing');
          }
          final expectedLength = content?.length ?? stat!.size;
          if (await _availableBytes() < expectedLength + reserveBytes) {
            throw const MediaOutboxException('low-space');
          }
          checkOwner();
          // Reserve disk atomically across replacement store instances. An
          // interrupted .part remains charged at its full admitted length.
          await db.transaction((txn) async {
            final rows = await txn.rawQuery(
                'SELECT COALESCE(SUM(length), 0) AS total '
                'FROM media_tasks WHERE owner_scope = ? AND length > 0',
                [owner.scope]);
            final retained = rows.single['total']! as int;
            if (expectedLength > maxRetainedBytes - retained) {
              throw const MediaOutboxException('pending-capacity');
            }
            final changed = await txn.update(
                'media_tasks', {'length': expectedLength},
                where: 'txid = ? AND owner_scope = ? AND stage = ?',
                whereArgs: [txid, owner.scope, 'preparing']);
            if (changed != 1) throw const MediaOutboxException('canceled');
          });
          checkOwner();
          // Reject links before any writer/rename follows them. Native seal
          // independently checks the fixed namespace after creating the file.
          await _requireType(target.path, FileSystemEntityType.file,
              allowMissing: true);
          await _requireType(temporary.path, FileSystemEntityType.file,
              allowMissing: true);
          final input = await source?.open();
          RandomAccessFile? output;
          final digestSink = _DigestSink();
          final hash = sha256.startChunkedConversion(digestSink);
          var length = 0;
          try {
            output = await temporary.open(mode: FileMode.write);
            while (true) {
              checkOwner();
              final chunk = content == null
                  ? await input!.read(chunkBytes)
                  : Uint8List.sublistView(content, length,
                      (length + chunkBytes).clamp(0, content.length));
              if (chunk.isEmpty) break;
              length += chunk.length;
              if (length > expectedLength) {
                throw const MediaOutboxException('source-changed');
              }
              hash.add(chunk);
              await output.writeFrom(chunk);
              await checkpoint?.call('copy');
            }
            if (length != expectedLength) {
              throw const MediaOutboxException('source-changed');
            }
            await output.flush();
          } finally {
            hash.close();
            await input?.close();
            await output?.close();
          }
          checkOwner();
          await temporary.rename(target.path);
          await _seal(
              owner.scope, sha256.convert(utf8.encode(txid)).toString());
          await checkpoint?.call('source');
          checkOwner();
          await db.update(
              'media_tasks',
              {
                'length': length,
                'digest': digestSink.value.toString(),
                'stage': 'queued'
              },
              where: 'txid = ? AND stage = ?',
              whereArgs: [txid, 'preparing']);
          await checkpoint?.call('queued');
          return (await byTxid(txid))!;
        } on Exception catch (error) {
          final reason = error is MediaOutboxException
              ? error.reason
              : preparationFailure == null
                  ? 'storage-write-failed'
                  : 'preparation-rejected';
          await setStage(txid, MediaOutboxStage.failed,
              from: {MediaOutboxStage.preparing, MediaOutboxStage.queued},
              failure: reason);
          if (preparationFailure != null) rethrow;
          throw MediaOutboxException(reason);
        } finally {
          _writingSources.remove(txid);
          await releaseTerminalSource(txid);
        }
      });

  Future<File> verifiedSource(MediaOutboxTask task) async {
    await _db();
    if (task.ownerScope != owner.scope) {
      throw const MediaOutboxException('owner-unavailable');
    }
    if (task.digest == null) {
      throw const MediaOutboxException('source-incomplete');
    }
    final source = _source(task.txid);
    await _requireType(source.path, FileSystemEntityType.file,
        allowMissing: true);
    if (!await source.exists()) {
      throw const MediaOutboxException('source-missing');
    }
    await _availableBytes(); // Revalidate native protection for recovery admission.
    await _seal(owner.scope, sha256.convert(utf8.encode(task.txid)).toString());
    if (await source.length() != task.length ||
        (await sha256.bind(source.openRead()).first).toString() !=
            task.digest) {
      throw const MediaOutboxException('source-changed');
    }
    return source;
  }

  Future<bool> setStage(String txid, MediaOutboxStage stage,
      {Set<MediaOutboxStage>? from,
      String? failure,
      String? eventId,
      DateTime? nextRetryAt,
      bool incrementAttempt = false}) async {
    final where = StringBuffer('txid = ? AND owner_scope = ?');
    final args = <Object?>[txid, owner.scope];
    if (from != null) {
      if (from.isEmpty) return false;
      where.write(' AND stage IN (${List.filled(from.length, '?').join(',')})');
      args.addAll(from.map((s) => s.name));
    }
    final values = <String, Object?>{
      'stage': stage.name,
      'failure': failure,
      'event_id': eventId,
      'next_retry_at': nextRetryAt?.millisecondsSinceEpoch
    };
    final updated = await (await _db()).rawUpdate(
            'UPDATE media_tasks SET '
            '${values.keys.map((key) => '$key = ?').join(', ')}'
            '${incrementAttempt ? ', attempts = attempts + 1' : ''} WHERE $where',
            [...values.values, ...args]) >
        0;
    if (updated && stage == MediaOutboxStage.canceled) {
      _canceledSources.add(txid);
    }
    return updated;
  }

  /// Caller must first settle its real transport; suspension is not cancellation.
  Future<void> releaseTerminalSource(String txid) async {
    if (_writingSources.contains(txid)) return;
    final task = await byTxid(txid);
    if (task == null || !task.terminal) return;
    for (final file in [_source(txid), File('${_source(txid).path}.part')]) {
      if (await file.exists()) await file.delete();
    }
    await (await _db()).update('media_tasks', {'length': 0},
        where: 'txid = ? AND owner_scope = ? AND stage IN (?, ?)',
        whereArgs: [txid, owner.scope, 'sent', 'canceled']);
  }

  Future<void> cleanupTerminalSources(
      {required bool Function(String txid) canRelease}) async {
    final rows = await (await _db()).query('media_tasks',
        columns: ['txid'],
        where: 'owner_scope = ? AND length > 0 AND stage IN (?, ?)',
        whereArgs: [owner.scope, 'sent', 'canceled'],
        limit: maxPending);
    for (final row in rows) {
      final txid = row['txid']! as String;
      if (canRelease(txid)) {
        try {
          await releaseTerminalSource(txid);
        } on FileSystemException {
          /* Remains charged; retry at next recovery. */
        }
      }
    }
  }

  Future<void> close() async {
    await _writes;
    final opening = _opening;
    _opening = null;
    if (opening != null) await (await opening).close();
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
