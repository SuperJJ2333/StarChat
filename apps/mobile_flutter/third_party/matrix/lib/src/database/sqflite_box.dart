import 'dart:async';
import 'dart:convert';

import 'package:sqflite_common/sqflite.dart';

import 'package:matrix/src/database/zone_transaction_mixin.dart';

/// Key-Value store abstraction over Sqflite so that the sdk database can use
/// a single interface for all platforms. API is inspired by Hive.
class BoxCollection with ZoneTransactionMixin {
  static const _timelineFragmentsBoxName = 'box_timeline_fragments';

  final Database _db;
  final Set<String> boxNames;
  final String name;

  BoxCollection(this._db, this.boxNames, this.name);

  static Future<BoxCollection> open(
    String name,
    Set<String> boxNames, {
    Object? sqfliteDatabase,
    DatabaseFactory? sqfliteFactory,
    dynamic idbFactory,
    int version = 1,
  }) async {
    if (sqfliteDatabase is! Database) {
      throw ('You must provide a Database `sqfliteDatabase` for use on native.');
    }
    final batch = sqfliteDatabase.batch();
    for (final name in boxNames) {
      batch.execute(
        'CREATE TABLE IF NOT EXISTS $name (k TEXT PRIMARY KEY NOT NULL, v TEXT)',
      );
      batch.execute('CREATE INDEX IF NOT EXISTS k_index ON $name (k)');
    }
    await batch.commit(noResult: true);
    return BoxCollection(sqfliteDatabase, boxNames, name);
  }

  Box<V> openBox<V>(String name) {
    if (!boxNames.contains(name)) {
      throw ('Box with name $name is not in the known box names of this collection.');
    }
    final box = Box<V>(name, this);
    _cacheInvalidators.add(box._invalidateCache);
    return box;
  }

  Batch? _activeBatch;
  bool _batchPoisoned = false;
  final _cacheInvalidators = <void Function()>[];
  final _pendingTimelinePuts = <String, void Function()>{};
  final _pendingTimelineValues = <String, Object?>{};
  final _pendingTimelineDeletes = <String>{};
  bool _timelineCleared = false;

  Future<void> transaction(
    Future<void> Function() action, {
    List<String>? boxNames,
    bool readOnly = false,
  }) =>
      zoneTransaction(() async {
        if (_activeBatch != null) {
          try {
            await action();
          } catch (_) {
            _batchPoisoned = true;
            rethrow;
          }
          return;
        }
        final batch = _db.batch();
        _activeBatch = batch;
        try {
          await action();
          if (_batchPoisoned) {
            throw StateError('Nested database action failed');
          }
          for (final put in _pendingTimelinePuts.values) {
            put();
          }
          await batch.commit(noResult: true);
        } catch (_) {
          for (final invalidate in _cacheInvalidators) {
            invalidate();
          }
          rethrow;
        } finally {
          _activeBatch = null;
          _batchPoisoned = false;
          _pendingTimelinePuts.clear();
          _pendingTimelineValues.clear();
          _pendingTimelineDeletes.clear();
          _timelineCleared = false;
        }
      });

  Future<void> clear() => transaction(
        () async {
          for (final name in boxNames) {
            await _db.delete(name);
          }
        },
      );

  Future<void> close() => zoneTransaction(() => _db.close());

  @Deprecated('use collection.deleteDatabase now')
  static Future<void> delete(String path, [dynamic factory]) =>
      (factory ?? databaseFactory).deleteDatabase(path);

  Future<void> deleteDatabase(String path, [dynamic factory]) async {
    await close();
    await (factory ?? databaseFactory).deleteDatabase(path);
  }
}

class Box<V> {
  final String name;
  final BoxCollection boxCollection;
  final Map<String, V?> _cache = {};

  /// _cachedKeys is only used to make sure that if you fetch all keys from a
  /// box, you do not need to have an expensive read operation twice. There is
  /// no other usage for this at the moment. So the cache is never partial.
  /// Once the keys are cached, they need to be updated when changed in put and
  /// delete* so that the cache does not become outdated.
  Set<String>? _cachedKeys;
  bool get _keysCached => _cachedKeys != null;

  static const Set<Type> allowedValueTypes = {
    List<dynamic>,
    Map<dynamic, dynamic>,
    String,
    int,
    double,
    bool,
  };

  Box(this.name, this.boxCollection) {
    if (!allowedValueTypes.any((type) => V == type)) {
      throw Exception(
        'Illegal value type for Box: "${V.toString()}". Must be one of $allowedValueTypes',
      );
    }
  }

  void _invalidateCache() {
    _cache.clear();
    _cachedKeys = null;
  }

  String? _toString(V? value) {
    if (value == null) return null;
    switch (V) {
      case const (List<dynamic>):
      case const (Map<dynamic, dynamic>):
        return jsonEncode(value);
      case const (String):
      case const (int):
      case const (double):
      case const (bool):
      default:
        return value.toString();
    }
  }

  V? _fromString(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw Exception(
          'Wrong database type! Expected String but got one of type ${value.runtimeType}');
    }
    switch (V) {
      case const (int):
        return int.parse(value) as V;
      case const (double):
        return double.parse(value) as V;
      case const (bool):
        return (value == 'true') as V;
      case const (List<dynamic>):
        return List.unmodifiable(jsonDecode(value)) as V;
      case const (Map<dynamic, dynamic>):
        return Map.unmodifiable(jsonDecode(value)) as V;
      case const (String):
      default:
        return value as V;
    }
  }

  Future<List<String>> getAllKeys([Transaction? txn]) async {
    if (_keysCached) return _cachedKeys!.toList();

    final executor = txn ?? boxCollection._db;

    final timeline = name == BoxCollection._timelineFragmentsBoxName;
    final result = timeline && boxCollection._timelineCleared
        ? const <Map<String, Object?>>[]
        : await executor.query(name, columns: ['k']);
    final keys = result.map((row) => row['k'] as String).toList();
    if (timeline) {
      keys.removeWhere(boxCollection._pendingTimelineDeletes.contains);
      final knownKeys = keys.toSet();
      for (final key in boxCollection._pendingTimelinePuts.keys) {
        if (knownKeys.add(key)) keys.add(key);
      }
    }

    _cachedKeys = keys.toSet();
    return keys;
  }

  Future<Map<String, V>> getAllValues([Transaction? txn]) async {
    final executor = txn ?? boxCollection._db;

    final timeline = name == BoxCollection._timelineFragmentsBoxName;
    final result = timeline && boxCollection._timelineCleared
        ? const <Map<String, Object?>>[]
        : await executor.query(name);
    final values = Map<String, V>.fromEntries(
      result.map(
        (row) => MapEntry(
          row['k'] as String,
          _fromString(row['v']) as V,
        ),
      ),
    );
    if (timeline) {
      for (final key in boxCollection._pendingTimelineDeletes) {
        values.remove(key);
      }
      for (final key in boxCollection._pendingTimelinePuts.keys) {
        values[key] = boxCollection._pendingTimelineValues[key] as V;
      }
    }
    return values;
  }

  Future<V?> get(String key, [Transaction? txn]) async {
    if (_cache.containsKey(key)) return _cache[key];
    if (name == BoxCollection._timelineFragmentsBoxName &&
        (boxCollection._timelineCleared ||
            boxCollection._pendingTimelineDeletes.contains(key))) {
      return null;
    }

    final executor = txn ?? boxCollection._db;

    final result = await executor.query(
      name,
      columns: ['v'],
      where: 'k = ?',
      whereArgs: [key],
    );

    final value = result.isEmpty ? null : _fromString(result.single['v']);
    _cache[key] = value;
    return value;
  }

  Future<List<V?>> getAll(List<String> keys, [Transaction? txn]) async {
    if (!keys.any((key) => !_cache.containsKey(key))) {
      return keys.map((key) => _cache[key]).toList();
    }

    // The SQL operation might fail with more than 1000 keys. We define some
    // buffer here and half the amount of keys recursively for this situation.
    const getAllMax = 800;
    if (keys.length > getAllMax) {
      final half = keys.length ~/ 2;
      return [
        ...(await getAll(keys.sublist(0, half))),
        ...(await getAll(keys.sublist(half))),
      ];
    }

    final executor = txn ?? boxCollection._db;

    final list = <V?>[];

    final timeline = name == BoxCollection._timelineFragmentsBoxName;
    final result = timeline && boxCollection._timelineCleared
        ? const <Map<String, Object?>>[]
        : await executor.query(
            name,
            where: 'k IN (${keys.map((_) => '?').join(',')})',
            whereArgs: keys,
          );
    final resultMap = Map<String, V?>.fromEntries(
      result.map((row) => MapEntry(row['k'] as String, _fromString(row['v']))),
    );
    if (timeline) {
      for (final key in boxCollection._pendingTimelineDeletes) {
        resultMap.remove(key);
      }
      for (final key in keys) {
        if (boxCollection._pendingTimelinePuts.containsKey(key)) {
          resultMap[key] = boxCollection._pendingTimelineValues[key] as V;
        }
      }
    }

    // We want to make sure that they values are returnd in the exact same
    // order than the given keys. That's why we do this instead of just return
    // `resultMap.values`.
    list.addAll(keys.map((key) => resultMap[key]));

    _cache.addAll(resultMap);

    return list;
  }

  Future<void> put(String key, V val) async {
    final txn = boxCollection._activeBatch;

    if (txn != null && name == BoxCollection._timelineFragmentsBoxName) {
      // Keep the final list in memory during the transaction. Encoding and
      // SQLite replacement happen once per fragment just before commit.
      boxCollection._pendingTimelinePuts[key] = () => txn.insert(
            name,
            {'k': key, 'v': _toString(val)},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
      boxCollection._pendingTimelineValues[key] = val;
      boxCollection._pendingTimelineDeletes.remove(key);
      _cache[key] = val;
      _cachedKeys?.add(key);
      return;
    }

    final params = {
      'k': key,
      'v': _toString(val),
    };
    if (txn == null) {
      await boxCollection._db.insert(
        name,
        params,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      txn.insert(
        name,
        params,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    _cache[key] = val;
    _cachedKeys?.add(key);
    return;
  }

  Future<void> delete(String key, [Batch? txn]) async {
    txn ??= boxCollection._activeBatch;
    if (identical(txn, boxCollection._activeBatch) &&
        name == BoxCollection._timelineFragmentsBoxName) {
      boxCollection._pendingTimelinePuts.remove(key);
      boxCollection._pendingTimelineValues.remove(key);
      boxCollection._pendingTimelineDeletes.add(key);
    }

    if (txn == null) {
      await boxCollection._db.delete(name, where: 'k = ?', whereArgs: [key]);
    } else {
      txn.delete(name, where: 'k = ?', whereArgs: [key]);
    }

    // Set to null instead remove() so that inside of transactions null is
    // returned.
    _cache[key] = null;
    _cachedKeys?.remove(key);
    return;
  }

  Future<void> deleteAll(List<String> keys, [Batch? txn]) async {
    txn ??= boxCollection._activeBatch;
    if (identical(txn, boxCollection._activeBatch) &&
        name == BoxCollection._timelineFragmentsBoxName) {
      for (final key in keys) {
        boxCollection._pendingTimelinePuts.remove(key);
        boxCollection._pendingTimelineValues.remove(key);
        boxCollection._pendingTimelineDeletes.add(key);
      }
    }

    final placeholder = keys.map((_) => '?').join(',');
    if (txn == null) {
      await boxCollection._db.delete(
        name,
        where: 'k IN ($placeholder)',
        whereArgs: keys,
      );
    } else {
      txn.delete(
        name,
        where: 'k IN ($placeholder)',
        whereArgs: keys,
      );
    }

    for (final key in keys) {
      _cache[key] = null;
      _cachedKeys?.removeAll(keys);
    }
    return;
  }

  Future<void> clear([Batch? txn]) async {
    txn ??= boxCollection._activeBatch;
    if (identical(txn, boxCollection._activeBatch) &&
        name == BoxCollection._timelineFragmentsBoxName) {
      boxCollection._pendingTimelinePuts.clear();
      boxCollection._pendingTimelineValues.clear();
      boxCollection._pendingTimelineDeletes.clear();
      boxCollection._timelineCleared = true;
    }

    if (txn == null) {
      await boxCollection._db.delete(name);
    } else {
      txn.delete(name);
    }

    _cache.clear();
    _cachedKeys = null;
    return;
  }
}
