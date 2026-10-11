import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Capacity metadata only. This never authenticates media or supplies a path
/// outside `v2/<account digest>/objects/<content digest>[.mp4|.mov]`.
final class MediaDiskObject {
  const MediaDiskObject(this.namespace, this.name, this.size, this.modified);
  final String namespace;
  final String name;
  final int size;
  final DateTime modified;
  String get key => '$namespace/$name';
}

/// Incremental, rebuildable disk accounting. SQLite stores one row per physical
/// object, independently of the logical-reference index. Files remain truth.
///
/// A durable dirty marker surrounds filesystem mutations: process death between
/// the file rename and index commit forces a rebuild on the next open. Normal
/// writes update one row; cold migration/corruption and periodic calibration are
/// the only directory walks. Calibration walks outside the mutation queue and
/// merges by revision so a concurrent clear/write cannot be resurrected.
final class MediaDiskQuotaIndex {
  MediaDiskQuotaIndex(Directory root, {DatabaseFactory? factory})
      : root = Directory(p.normalize(p.absolute(root.path))),
        _factory = factory ?? databaseFactoryFfi;

  final Directory root;
  final DatabaseFactory _factory;
  final _objects = <String, MediaDiskObject>{};
  final _accountBytes = <String, int>{};
  final _changed = <String, int>{};
  final _cleared = <String, int>{};
  Database? _db;
  bool _durable = true;
  bool _complete = false;
  Future<void>? _opening;
  Future<void>? _calibration;
  Future<void> _tail = Future.value();
  int _revision = 0;
  int _total = 0;
  DateTime _calibratedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAttemptAt = DateTime.fromMillisecondsSinceEpoch(0);
  static final _namespace = RegExp(r'^[a-f0-9]{64}$');
  static final _object = RegExp(r'^[a-f0-9]{64}(\.mp4|\.mov)?$');

  String get databasePath => p.join(root.path, 'quota-v1.sqlite');
  File get _dirty => File(p.join(root.path, 'quota-v1.dirty'));
  int get totalBytes => _total;
  bool get canEvict => _complete;
  int accountBytes(String namespace) => _accountBytes[namespace] ?? 0;
  List<MediaDiskObject> get objects => List.of(_objects.values);
  String pathFor(MediaDiskObject object) =>
      p.join(root.path, 'v2', object.namespace, 'objects', object.name);

  Future<bool> hasManagedParents(MediaDiskObject object) async {
    for (final path in [
      root.path,
      p.join(root.path, 'v2'),
      p.join(root.path, 'v2', object.namespace),
      p.join(root.path, 'v2', object.namespace, 'objects')
    ]) {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return false;
      }
    }
    return true;
  }

  Future<void> ready() => _opening ??= _open();

  Future<void> _open() async {
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('Cache root must not be a link');
    }
    await root.create(recursive: true);
    var rebuild = await _dirty.exists();
    try {
      if (rebuild) await _factory.deleteDatabase(databasePath);
      try {
        _db = await _openDatabase();
        final check = await _db!.rawQuery('PRAGMA quick_check');
        if (check.single.values.single != 'ok') throw const FormatException();
        final meta = await _db!.query('calibration');
        rebuild = rebuild || meta.isEmpty;
        if (meta.isNotEmpty) {
          _calibratedAt =
              DateTime.fromMillisecondsSinceEpoch(meta.single['at'] as int);
        }
        for (final row in await _db!.query('objects')) {
          final entry = MediaDiskObject(
              row['account'] as String,
              row['name'] as String,
              row['size'] as int,
              DateTime.fromMillisecondsSinceEpoch(row['modified'] as int));
          if (!_namespace.hasMatch(entry.namespace) ||
              !_object.hasMatch(entry.name) ||
              entry.size < 0) {
            throw const FormatException('Invalid quota metadata');
          }
          _remember(entry);
        }
      } catch (_) {
        await _db?.close();
        _db = null;
        // Only this fixed, disposable index is removed. Never cache objects.
        await _factory.deleteDatabase(databasePath);
        _db = await _openDatabase();
        rebuild = true;
      }
    } catch (_) {
      // SQLite may not be initialized yet. Keep a process-local accurate index;
      // the marker prevents stale persisted metadata from being trusted later.
      _durable = false;
      rebuild = true;
    }
    try {
      if (rebuild) {
        _objects.clear();
        _accountBytes.clear();
        _total = 0;
        _lastAttemptAt = DateTime.now();
        for (final object in await _scan()) {
          _remember(object);
        }
        _complete = true;
        await _persistSnapshot();
      } else {
        _complete = true;
      }
    } on FileSystemException {
      // An incomplete walk cannot justify eviction or a zero-byte snapshot.
      // Keep offline files and retry calibration later.
      _complete = false;
    } finally {
      await _db?.close();
      _db = null;
    }
  }

  Future<Database> _openDatabase() => _factory.openDatabase(databasePath,
      options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute(
                'CREATE TABLE objects (account TEXT NOT NULL, name TEXT NOT NULL, size INTEGER NOT NULL, modified INTEGER NOT NULL, PRIMARY KEY(account,name))');
            await db.execute('CREATE TABLE calibration (at INTEGER NOT NULL)');
          }));

  /// The callback is local metadata/file work only: never hash, download, decode
  /// or wait for a producer here. Initial/background scans are outside this lock.
  Future<T> mutate<T>(Future<T> Function() action) async {
    await ready();
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      await _dirty.writeAsString('1', flush: true);
      if (_durable) {
        try {
          _db = await _openDatabase();
        } catch (_) {
          _durable = false;
        }
      }
      final result = await action();
      if (_durable && _complete && await _dirty.exists()) await _dirty.delete();
      return result;
    } catch (_) {
      // A later successful mutation must not erase evidence of a partial file
      // write that never reached the index. Rebuild before trusting it again.
      _durable = false;
      _complete = false;
      _lastAttemptAt = DateTime.now();
      rethrow;
    } finally {
      await _db?.close();
      _db = null;
      done.complete();
    }
  }

  void _remember(MediaDiskObject object) {
    final previous = _objects[object.key]?.size ?? 0;
    _objects[object.key] = object;
    final delta = object.size - previous;
    _total += delta;
    _accountBytes[object.namespace] = accountBytes(object.namespace) + delta;
  }

  Future<void> upsert(MediaDiskObject object) async {
    if (!_namespace.hasMatch(object.namespace) ||
        !_object.hasMatch(object.name) ||
        object.size < 0) {
      throw const FormatException('Invalid cache object');
    }
    _remember(object);
    _changed[object.key] = ++_revision;
    await _persist(() async => _db!.insert('objects', _row(object),
        conflictAlgorithm: ConflictAlgorithm.replace));
  }

  Future<void> remove(MediaDiskObject object) async {
    final previous = _objects.remove(object.key);
    if (previous != null) {
      _total -= previous.size;
      _accountBytes[previous.namespace] =
          accountBytes(previous.namespace) - previous.size;
    }
    _changed[object.key] = ++_revision;
    await _persist(() async => _db!.delete('objects',
        where: 'account = ? AND name = ?',
        whereArgs: [object.namespace, object.name]));
  }

  Future<void> clearAccount(String namespace) async {
    _cleared[namespace] = ++_revision;
    for (final object in objects.where((o) => o.namespace == namespace)) {
      await remove(object);
    }
  }

  Future<void> _persist(Future<void> Function() operation) async {
    if (!_durable || _db == null) return;
    try {
      await operation();
    } catch (_) {
      _durable = false;
      await _dirty.writeAsString('1', flush: true);
    }
  }

  Map<String, Object> _row(MediaDiskObject object) => {
        'account': object.namespace,
        'name': object.name,
        'size': object.size,
        'modified': object.modified.millisecondsSinceEpoch,
      };

  Future<void> _persistSnapshot() async {
    _calibratedAt = DateTime.now();
    await _dirty.writeAsString('1', flush: true);
    await _persist(() => _db!.transaction((txn) async {
          await txn.delete('objects');
          var batch = txn.batch();
          var count = 0;
          for (final object in _objects.values) {
            batch.insert('objects', _row(object));
            if (++count % 128 == 0) {
              await batch.commit(noResult: true);
              batch = txn.batch();
            }
          }
          await batch.commit(noResult: true);
          await txn.delete('calibration');
          await txn.insert(
              'calibration', {'at': _calibratedAt.millisecondsSinceEpoch});
        }));
    if (_durable && await _dirty.exists()) await _dirty.delete();
  }

  /// Asynchronous directory iteration, restricted at every level; links and
  /// unrelated source/pending-media files are never traversed or counted.
  Future<List<MediaDiskObject>> _scan() async {
    final result = <MediaDiskObject>[];
    final v2 = Directory(p.join(root.path, 'v2'));
    if (await FileSystemEntity.type(v2.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return result;
    }
    await for (final account in v2.list(followLinks: false)) {
      if (account is! Directory ||
          !_namespace.hasMatch(p.basename(account.path))) {
        continue;
      }
      final directory = Directory(p.join(account.path, 'objects'));
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      await for (final file in directory.list(followLinks: false)) {
        if (file is! File || !_object.hasMatch(p.basename(file.path))) continue;
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        result.add(MediaDiskObject(p.basename(account.path),
            p.basename(file.path), stat.size, stat.modified));
      }
    }
    return result;
  }

  void scheduleCalibration() {
    if (DateTime.now().difference(_lastAttemptAt) <
        const Duration(seconds: 30)) {
      return;
    }
    if (_complete &&
        DateTime.now().difference(_calibratedAt) < const Duration(hours: 6)) {
      return;
    }
    unawaited(reconcile().catchError((Object _) {}));
  }

  Future<void> reconcile() => _calibration ??= _reconcile().whenComplete(() {
        _calibration = null;
      });

  Future<void> _reconcile() async {
    await ready();
    _lastAttemptAt = DateTime.now();
    final revision = _revision;
    late Map<String, MediaDiskObject> scanned;
    try {
      scanned = {for (final object in await _scan()) object.key: object};
    } catch (_) {
      // A previous complete snapshot must not remain eligible after a failed
      // fresh walk. Preserve both files and accounting; only a complete retry
      // can restore eviction, including after process restart.
      _complete = false;
      try {
        await _dirty.writeAsString('1', flush: true);
      } on FileSystemException {
        // Preserve the original scan error and keep in-process eviction off.
      }
      rethrow;
    }
    await mutate(() async {
      for (final object in objects) {
        if ((_changed[object.key] ?? 0) <= revision &&
            !scanned.containsKey(object.key)) {
          await remove(object);
        }
      }
      for (final object in scanned.values) {
        if ((_changed[object.key] ?? 0) > revision ||
            (_cleared[object.namespace] ?? 0) > revision) {
          continue;
        }
        final old = _objects[object.key];
        if (old?.size != object.size ||
            old?.modified.millisecondsSinceEpoch !=
                object.modified.millisecondsSinceEpoch) {
          await upsert(object);
        }
      }
      _calibratedAt = DateTime.now();
      _complete = true;
      await _persist(() => _db!.transaction((txn) async {
            await txn.delete('calibration');
            await txn.insert(
                'calibration', {'at': _calibratedAt.millisecondsSinceEpoch});
          }));
      _changed.clear();
      _cleared.clear();
    });
  }

  Future<void> close() async {
    await _calibration;
    await _tail;
    await _db?.close();
  }
}
