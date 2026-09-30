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
  final _pendingBoxValues = <String, Map<String, Object?>>{};
  final _pendingClearedBoxes = <String>{};
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
          _pendingBoxValues.clear();
          _pendingClearedBoxes.clear();
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
  static const eventCacheMaxEntries = 512;
  static const eventCacheMaxBytes = 4 * 1024 * 1024;
  static const eventCacheMaxEntryBytes = 256 * 1024;
  bool get _boundedEvents => name == 'box_events';
  final _cacheWeights = <String, int>{};
  int _cacheBytes = 0;
  int get cachedEntryCount => _cache.length;

  /// Serialized UTF-8 payload/key bytes plus a fixed per-entry allowance.
  /// This is an admission weight, not a measurement of Dart heap or RSS.
  int get cachedEstimatedBytes => _boundedEvents
      ? _cacheBytes
      : _cache.entries.fold(
          0,
          (total, entry) =>
              total +
              utf8.encode(entry.key).length +
              utf8.encode(_toString(entry.value) ?? '').length +
              64);

  Map<String, Object?>? get _pending => boxCollection._activeBatch == null
      ? null
      : boxCollection._pendingBoxValues[name];
  bool get _pendingClear =>
      boxCollection._activeBatch != null &&
      boxCollection._pendingClearedBoxes.contains(name);

  V? _cached(String key) {
    if (!_boundedEvents) return _cache[key];
    final value = _cache.remove(key);
    _cache[key] = value;
    return value;
  }

  void _remember(String key, V? value, {String? serialized}) {
    if (!_boundedEvents) {
      _cache[key] = value;
      return;
    }
    _cache.remove(key);
    _cacheBytes -= _cacheWeights.remove(key) ?? 0;
    final weight = utf8.encode(key).length +
        utf8.encode(serialized ?? _toString(value) ?? '').length +
        64;
    if (weight > eventCacheMaxEntryBytes) return;
    _cache[key] = value;
    _cacheWeights[key] = weight;
    _cacheBytes += weight;
    while (_cache.length > eventCacheMaxEntries ||
        _cacheBytes > eventCacheMaxBytes) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest);
      _cacheBytes -= _cacheWeights.remove(oldest)!;
    }
  }

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
    _cacheWeights.clear();
    _cacheBytes = 0;
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
    if (!_boundedEvents && _keysCached) return _cachedKeys!.toList();

    final executor = txn ?? boxCollection._db;

    final timeline = name == BoxCollection._timelineFragmentsBoxName;
    final result = (timeline && boxCollection._timelineCleared) ||
            (_boundedEvents && _pendingClear)
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

    if (_boundedEvents) {
      final combined = keys.toSet();
      for (final entry in (_pending ?? const <String, Object?>{}).entries) {
        if (entry.value == null) {
          combined.remove(entry.key);
        } else {
          combined.add(entry.key);
        }
      }
      return combined.toList();
    }

    _cachedKeys = keys.toSet();
    return keys;
  }

  Future<Map<String, V>> getAllValues([Transaction? txn]) async {
    final executor = txn ?? boxCollection._db;

    final timeline = name == BoxCollection._timelineFragmentsBoxName;
    final result = (timeline && boxCollection._timelineCleared) ||
            (_boundedEvents && _pendingClear)
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
    if (_boundedEvents) {
      for (final entry in (_pending ?? const <String, Object?>{}).entries) {
        if (entry.value == null) {
          values.remove(entry.key);
        } else {
          values[entry.key] = entry.value as V;
        }
      }
    }
    return values;
  }

  Future<V?> get(String key, [Transaction? txn]) async {
    if (_boundedEvents) {
      final pending = _pending;
      if (pending?.containsKey(key) ?? false) return pending![key] as V?;
      if (_pendingClear) return null;
    }
    if (_cache.containsKey(key)) return _cached(key);
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
    _remember(key, value,
        serialized: result.isEmpty ? null : result.single['v'] as String?);
    return value;
  }

  Future<List<V?>> getAll(List<String> keys, [Transaction? txn]) async {
    if (keys.isEmpty) return [];
    if (_boundedEvents) {
      final pending = _pending;
      if (keys.every((key) =>
          (pending?.containsKey(key) ?? false) ||
          _pendingClear ||
          _cache.containsKey(key))) {
        return keys.map((key) {
          if (pending?.containsKey(key) ?? false) return pending![key] as V?;
          if (_pendingClear) return null;
          return _cached(key);
        }).toList();
      }
    }
    if (!_boundedEvents && !keys.any((key) => !_cache.containsKey(key))) {
      return keys.map((key) => _cache[key]).toList();
    }

    // The SQL operation might fail with more than 1000 keys. We define some
    // buffer here and half the amount of keys recursively for this situation.
    const getAllMax = 800;
    if (keys.length > getAllMax) {
      final half = keys.length ~/ 2;
      return [
        ...(await getAll(keys.sublist(0, half), txn)),
        ...(await getAll(keys.sublist(half), txn)),
      ];
    }

    final executor = txn ?? boxCollection._db;

    final list = <V?>[];

    final timeline = name == BoxCollection._timelineFragmentsBoxName;
    final result = (timeline && boxCollection._timelineCleared) ||
            (_boundedEvents && _pendingClear)
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
    if (_boundedEvents) {
      final pending = _pending;
      for (final key in keys) {
        if (pending?.containsKey(key) ?? false) {
          resultMap[key] = pending![key] as V?;
        }
      }
    }

    // We want to make sure that they values are returnd in the exact same
    // order than the given keys. That's why we do this instead of just return
    // `resultMap.values`.
    list.addAll(keys.map((key) => resultMap[key]));

    if (_boundedEvents) {
      for (final key in keys) {
        _remember(key, resultMap[key]);
      }
    } else {
      _cache.addAll(resultMap);
    }

    return list;
  }

  /// Read one search page without adding its event rows to the persistent Box
  /// cache. The collection gate keeps SQL and staged batch values consistent.
  Future<List<V?>> getAllTransient(List<String> keys) async {
    if (keys.isEmpty) return const [];
    late List<V?> aligned;
    await boxCollection.zoneTransaction(() async {
      final values = <String, V?>{};
      if (!boxCollection._pendingClearedBoxes.contains(name)) {
        const batchSize = 800;
        for (var offset = 0; offset < keys.length; offset += batchSize) {
          final slice = keys.skip(offset).take(batchSize).toList();
          final result = await boxCollection._db.query(name,
              where: 'k IN (${slice.map((_) => '?').join(',')})',
              whereArgs: slice);
          for (final row in result) {
            values[row['k'] as String] = _fromString(row['v']);
          }
        }
      }
      final pending = boxCollection._pendingBoxValues[name];
      for (final key in keys) {
        if (pending?.containsKey(key) ?? false) {
          values[key] = pending![key] as V?;
        }
      }
      aligned = keys.map((key) => values[key]).toList();
    });
    return aligned;
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
      boxCollection._pendingBoxValues.putIfAbsent(name, () => {})[key] = val;
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

    _remember(key, val, serialized: params['v']);
    if (txn != null) {
      boxCollection._pendingBoxValues.putIfAbsent(name, () => {})[key] = val;
    }
    _cachedKeys?.add(key);
    return;
  }

  Future<void> delete(String key, [Batch? txn]) async {
    txn ??= boxCollection._activeBatch;
    if (txn != null &&
        identical(txn, boxCollection._activeBatch) &&
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
    _remember(key, null);
    if (txn != null && identical(txn, boxCollection._activeBatch)) {
      boxCollection._pendingBoxValues.putIfAbsent(name, () => {})[key] = null;
    }
    _cachedKeys?.remove(key);
    return;
  }

  Future<void> deleteAll(List<String> keys, [Batch? txn]) async {
    txn ??= boxCollection._activeBatch;
    if (txn != null &&
        identical(txn, boxCollection._activeBatch) &&
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
      _remember(key, null);
      if (txn != null && identical(txn, boxCollection._activeBatch)) {
        boxCollection._pendingBoxValues.putIfAbsent(name, () => {})[key] = null;
      }
      _cachedKeys?.removeAll(keys);
    }
    return;
  }

  Future<void> clear([Batch? txn]) async {
    txn ??= boxCollection._activeBatch;
    if (txn != null &&
        identical(txn, boxCollection._activeBatch) &&
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

    _invalidateCache();
    if (txn != null && identical(txn, boxCollection._activeBatch)) {
      boxCollection._pendingClearedBoxes.add(name);
      boxCollection._pendingBoxValues.remove(name);
    }
    _cachedKeys = null;
    return;
  }
}
