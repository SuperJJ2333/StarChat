import 'dart:async';
import 'package:matrix/src/database/database_api.dart';
import 'package:matrix/src/database/sqflite_box.dart';
import 'package:sqflite_common/sqflite.dart';

/// Additive ordering metadata. Bodies and the legacy migration source remain
/// untouched. All event-order mutations join the SDK's original atomic batch.
class TimelineIdStore {
  TimelineIdStore(this.collection, this.reader);
  final BoxCollection collection;
  final TimelineMigrationReader? reader;
  Database get sql => collection.timelineDatabase;
  static const stateTable = 'matrix_timeline_fragment_state';
  static const idTable = 'matrix_timeline_fragment_ids';
  static const epochTable = 'matrix_timeline_complete_epochs';
  final _collectible = <String>{};
  final _collecting = <String, Future<void>>{};
  final Map<String, Future<void>> _preparing = {};
  final Set<_SqlSnapshot> _leases = {};
  bool _closed = false;
  ({StateError error, StackTrace stack})? _maintenanceFailure;
  void _reportMaintenanceFailure() {
    final failure = _maintenanceFailure;
    if (failure == null) return;
    _maintenanceFailure = null;
    Error.throwWithStackTrace(failure.error, failure.stack);
  }

  Future<void> _observeMaintenance(Future<void> task) async {
    try {
      await task;
    } on TimelineStorageClosed {
      return;
    } catch (error, stack) {
      _maintenanceFailure = (
        error: StateError(
            'Timeline metadata maintenance failed (${error.runtimeType})'),
        stack: stack
      );
    }
  }

  final _ready = <String>{};

  void _check() {
    if (_closed) throw TimelineStorageClosed();
  }

  Future<void> open() async {
    final batch = sql.batch();
    batch.execute('CREATE TABLE IF NOT EXISTS $stateTable ('
        'fragment_key TEXT PRIMARY KEY, current_epoch INTEGER NOT NULL, '
        'head_seq INTEGER NOT NULL, tail_seq INTEGER NOT NULL, item_count INTEGER NOT NULL, '
        'revision INTEGER NOT NULL, migration_state TEXT NOT NULL, '
        'migration_next INTEGER NOT NULL, source_identity TEXT, '
        'legacy_epoch_floor INTEGER NOT NULL DEFAULT 0)');
    batch.execute('CREATE TABLE IF NOT EXISTS $idTable ('
        'fragment_key TEXT NOT NULL, epoch INTEGER NOT NULL, seq INTEGER NOT NULL, '
        'event_id TEXT NOT NULL, valid_from INTEGER NOT NULL, valid_to INTEGER, '
        'PRIMARY KEY(fragment_key,epoch,seq))');
    batch.execute('CREATE TABLE IF NOT EXISTS $epochTable '
        '(fragment_key TEXT NOT NULL,epoch INTEGER NOT NULL,PRIMARY KEY(fragment_key,epoch))');
    batch.execute(
        'INSERT OR IGNORE INTO $epochTable SELECT fragment_key,current_epoch '
        "FROM $stateTable WHERE migration_state='ready'");
    batch.execute('CREATE INDEX IF NOT EXISTS matrix_timeline_retired '
        'ON $idTable(fragment_key,epoch,seq) WHERE valid_to IS NOT NULL');
    batch.execute('CREATE INDEX IF NOT EXISTS matrix_timeline_membership '
        'ON $idTable(fragment_key,epoch,event_id,valid_to,seq)');
    batch.execute('CREATE TABLE IF NOT EXISTS matrix_timeline_legacy_revision '
        '(fragment_key TEXT PRIMARY KEY, revision INTEGER NOT NULL)');
    for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
      final ref = operation == 'DELETE' ? 'OLD' : 'NEW';
      batch.execute(
          'CREATE TRIGGER IF NOT EXISTS matrix_timeline_legacy_${operation.toLowerCase()} '
          'AFTER $operation ON box_timeline_fragments BEGIN '
          'INSERT INTO matrix_timeline_legacy_revision(fragment_key,revision) VALUES ($ref.k,1) '
          'ON CONFLICT(fragment_key) DO UPDATE SET revision=revision+1; END');
    }
    await batch.commit(noResult: true);
    final columns = await sql.rawQuery('PRAGMA table_info($stateTable)');
    if (!columns.any((row) => row['name'] == 'legacy_epoch_floor')) {
      final migration = sql.batch();
      migration.execute('ALTER TABLE $stateTable ADD COLUMN '
          'legacy_epoch_floor INTEGER NOT NULL DEFAULT 0');
      await migration.commit(noResult: true);
    }
  }

  Future<T> _gate<T>(Future<T> Function() action) async {
    late T value;
    await collection.zoneTransaction(() async {
      _check();
      value = await action();
    });
    return value;
  }

  Future<Map<String, Object?>?> _state(String key) async {
    final rows = await sql
        .query(stateTable, where: 'fragment_key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.single;
  }

  Future<void> prepare(String key) {
    _check();
    _reportMaintenanceFailure();
    // A limited sync has staged an atomic replacement. The committed legacy
    // source is no longer the batch's ordering authority, even before commit.
    // Consult only the owning batch overlay, never cache readiness prematurely.
    if (collection.timelineOwnsTransaction &&
        (collection.timelineOverlay['timeline:$key'] as _BatchOrder?)?.reset ==
            true) {
      return Future.value();
    }
    if (_ready.contains(key)) return Future.value();
    if (collection.timelineOwnsTransaction && _preparing.containsKey(key)) {
      throw StateError(
          'Legacy timeline requires preflight outside transaction');
    }
    final pending = _preparing[key];
    if (pending != null) {
      // A concurrent limited sync can atomically supersede this migration.
      // Readers must use the committed replacement instead of waiting for the
      // obsolete worker to finish. That worker still drains under close().
      return _gate(() => _state(key)).then<void>((state) async {
        if (state?['migration_state'] == 'ready') {
          _ready.add(key);
          return;
        }
        await pending;
      });
    }
    return _preparing.putIfAbsent(
        key,
        () => _prepare(key).whenComplete(() {
              unawaited(_preparing.remove(key));
            }));
  }

  Future<String?> _sourceIdentity(String key) async {
    final rows = await sql.rawQuery(
        'SELECT COALESCE(r.revision,0) AS revision,t.rowid AS source_row '
        'FROM box_timeline_fragments t LEFT JOIN matrix_timeline_legacy_revision r ON r.fragment_key=t.k WHERE t.k=?',
        [key]);
    return rows.isEmpty
        ? null
        : '${rows.single['source_row']}:${rows.single['revision']}';
  }

  Future<void> _assertSource(String key, Map<String, Object?> state) async {
    if (state['source_identity'] != await _sourceIdentity(key)) {
      throw StateError('Legacy timeline source changed');
    }
  }

  Future<void> _prepare(String key) async {
    var needsMigration = false;
    await _gate(() async {
      final state = await _state(key);
      if (state?['migration_state'] == 'ready') {
        _ready.add(key);
        return;
      }
      final source = await _sourceIdentity(key);
      if (collection.timelineBatch != null) {
        if (source != null) {
          throw StateError(
              'Legacy timeline requires preflight outside transaction');
        }
        _initialize(collection.timelineBatch!, key);
        return;
      }
      if (source == null) {
        final batch = sql.batch();
        _initialize(batch, key);
        await batch.commit(noResult: true);
        _ready.add(key);
        return;
      }
      needsMigration = true;
      if (state == null) {
        await sql.insert(stateTable, {
          'fragment_key': key,
          'current_epoch': 1,
          'head_seq': 0,
          'tail_seq': -1,
          'item_count': 0,
          'revision': 0,
          'migration_state': 'copying',
          'migration_next': 0,
          'source_identity': source
        });
      } else if (state['source_identity'] != source) {
        // A prior failed migration is never authority. Restart in a new epoch
        // while retaining the prior partial rows for bounded background GC.
        final batch = sql.batch();
        batch.rawUpdate(
            'UPDATE $stateTable SET current_epoch=current_epoch+1,head_seq=0,tail_seq=-1,item_count=0,migration_next=0,source_identity=? WHERE fragment_key=?',
            [source, key]);
        await batch.commit(noResult: true);
      }
    });
    if (!needsMigration) return;
    // Each page releases the global collection gate before waiting for the
    // next worker ACK. A failed/reopened migration resumes its committed ordinal.
    var ordinal = 0;
    await for (final page in (reader?.call(key) ?? _boundedLegacy(key))) {
      _check();
      if (page.isEmpty || page.length > 256) {
        throw StateError('Invalid timeline migration page');
      }
      final begin = ordinal;
      ordinal += page.length;
      await _gate(() async {
        final state = (await _state(key))!;
        if (state['migration_state'] == 'ready') return;
        await _assertSource(key, state);
        final next = state['migration_next'] as int;
        if (ordinal <= next) return;
        final batch = sql.batch();
        for (var i = 0; i < page.length; i++) {
          if (begin + i < next) continue;
          batch.insert(idTable, {
            'fragment_key': key,
            'epoch': state['current_epoch'],
            'seq': begin + i,
            'event_id': page[i],
            'valid_from': 0
          });
        }
        batch.update(
            stateTable,
            {
              'migration_next': ordinal,
              'tail_seq': ordinal - 1,
              'item_count': ordinal
            },
            where: 'fragment_key = ? AND migration_state = ?',
            whereArgs: [key, 'copying']);
        await batch.commit(noResult: true);
      });
      await Future<void>.delayed(Duration.zero);
    }
    await _gate(() async {
      final state = (await _state(key))!;
      if (state['migration_state'] == 'ready') return;
      if (state['migration_next'] != ordinal) {
        throw StateError('Incomplete timeline migration');
      }
      final source = await _sourceIdentity(key);
      if (source == null || state['source_identity'] != source) {
        throw StateError('Legacy timeline source changed');
      }
      final batch = sql.batch();
      batch.update(stateTable, {'migration_state': 'ready'},
          where: 'fragment_key = ?', whereArgs: [key]);
      _completeEpoch(batch, key);
      await batch.commit(noResult: true);
      _ready.add(key);
    });
  }

  /// Compatibility for caller-supplied/in-memory native databases. Production
  /// injects a worker-owned SQLCipher reader; even this fallback never reads a
  /// full legacy row or decodes a room-sized array.
  Stream<List<String>> _boundedLegacy(String key) async* {
    final parser = TimelineStringArrayParser();
    var offset = 1;
    while (true) {
      _check();
      final rows = await sql.rawQuery(
          'SELECT substr(CAST(v AS BLOB), ?, 32768) AS chunk FROM box_timeline_fragments WHERE k = ?',
          [offset, key]);
      if (rows.isEmpty) break;
      final bytes = rows.single['chunk'] as List<int>;
      if (bytes.isEmpty) break;
      offset += bytes.length;
      for (final page in parser.add(bytes)) {
        yield page;
      }
    }
    for (final page in parser.finish()) {
      yield page;
    }
  }

  /// Deferred search backfill includes unresolved legacy IDs displaced by a
  /// limited sync. It does not publish or mutate the active timeline epoch.
  Stream<List<String>> retainedLegacyIds(String key) async* {
    final source = await _gate(() => _sourceIdentity(key));
    if (source == null) return;
    await for (final page in reader?.call(key) ?? _boundedLegacy(key)) {
      _check();
      if (page.isEmpty || page.length > 256) {
        throw StateError('Invalid retained legacy page');
      }
      if (await _gate(() => _sourceIdentity(key)) != source) {
        throw StateError('Legacy timeline source changed');
      }
      yield page;
    }
    if (await _gate(() => _sourceIdentity(key)) != source) {
      throw StateError('Legacy timeline source changed');
    }
  }

  void _initialize(Batch batch, String key) {
    batch.rawInsert(
        'INSERT OR IGNORE INTO $stateTable '
        '(fragment_key,current_epoch,head_seq,tail_seq,item_count,revision,migration_state,migration_next) '
        "VALUES (?,1,0,-1,0,0,'ready',0)",
        [key]);
    _completeEpoch(batch, key);
  }

  void _completeEpoch(Batch batch, String key) {
    batch.rawInsert(
        'INSERT OR IGNORE INTO $epochTable '
        "SELECT fragment_key,current_epoch FROM $stateTable WHERE fragment_key=? AND migration_state='ready'",
        [key]);
  }

  Future<_BatchOrder> _overlay(String key) async {
    final cacheKey = 'timeline:$key';
    final existing = collection.timelineOverlay[cacheKey];
    if (existing != null) return existing as _BatchOrder;
    final state = await _state(key);
    final overlay = _BatchOrder(
        state?['current_epoch'] as int? ?? 1,
        state?['head_seq'] as int? ?? 0,
        state?['tail_seq'] as int? ?? -1,
        state?['item_count'] as int? ?? 0);
    collection.timelineOverlay[cacheKey] = overlay;
    return overlay;
  }

  Future<({int seq, int count})?> _membership(
      String key, String id, _BatchOrder overlay) async {
    if (overlay.changed.containsKey(id)) return overlay.changed[id];
    if (overlay.reset) return null;
    final rows = await sql.rawQuery(
        'SELECT MIN(seq) AS seq,COUNT(*) AS n FROM $idTable '
        'WHERE fragment_key=? AND epoch=? AND event_id=? AND valid_to IS NULL',
        [key, overlay.epoch, id]);
    final n = rows.single['n'] as int;
    return n == 0 ? null : (seq: rows.single['seq'] as int, count: n);
  }

  Future<void> _stageRemoval(String key, String id, _BatchOrder overlay) async {
    final previous = await _membership(key, id, overlay);
    overlay.count -= previous?.count ?? 0;
    overlay.changed[id] = null;
  }

  Future<void> add(String key, String id,
      {bool tail = false, bool move = false}) async {
    await prepare(key);
    final batch = collection.timelineBatch;
    if (batch == null) {
      await collection.transaction(() => add(key, id, tail: tail, move: move));
      return;
    }
    _initialize(batch, key);
    final overlay = await _overlay(key);
    if (move) {
      await _stageRemoval(key, id, overlay);
      _remove(batch, key, id);
    }
    if (await _membership(key, id, overlay) == null) {
      final seq = tail ? ++overlay.tail : --overlay.head;
      overlay.changed[id] = (seq: seq, count: 1);
      overlay.count++;
    }
    // SQL sees earlier commands in THIS batch. No whole-fragment or unbounded
    // pending-ID cache is necessary for same-batch membership/deduplication.
    batch.rawInsert(
        'INSERT INTO $idTable(fragment_key,epoch,seq,event_id,valid_from) '
        'SELECT fragment_key,current_epoch,${tail ? 'tail_seq+1' : 'head_seq-1'},?,revision+1 '
        'FROM $stateTable s WHERE fragment_key=? AND NOT EXISTS '
        '(SELECT 1 FROM $idTable i WHERE i.fragment_key=s.fragment_key AND i.epoch=s.current_epoch AND i.event_id=? AND i.valid_to IS NULL)',
        [id, key, id]);
    batch.rawUpdate(
        'UPDATE $stateTable SET item_count=item_count+changes(), '
        '${tail ? 'tail_seq=tail_seq+changes()' : 'head_seq=head_seq-changes()'}, revision=revision+1 WHERE fragment_key=?',
        [key]);
  }

  void _remove(Batch batch, String key, String id) {
    batch.rawUpdate(
        'UPDATE $idTable SET valid_to=(SELECT revision+1 FROM $stateTable WHERE fragment_key=?) '
        'WHERE fragment_key=? AND epoch=(SELECT current_epoch FROM $stateTable WHERE fragment_key=?) AND event_id=? AND valid_to IS NULL',
        [key, key, key, id]);
    batch.rawUpdate(
        'UPDATE $stateTable SET item_count=item_count-changes(),revision=revision+1 WHERE fragment_key=?',
        [key]);
  }

  Future<void> remove(String key, String id) async {
    await prepare(key);
    final batch = collection.timelineBatch;
    if (batch == null) {
      await collection.transaction(() => remove(key, id));
      return;
    }
    await _stageRemoval(key, id, await _overlay(key));
    _remove(batch, key, id);
  }

  Future<void> reset(String key) async {
    final batch = collection.timelineBatch;
    if (batch == null) {
      await collection.transaction(() => reset(key));
      return;
    }
    _initialize(batch, key);
    final overlay = await _overlay(key);
    overlay.epoch++;
    overlay.head = 0;
    overlay.tail = -1;
    overlay.count = 0;
    overlay.reset = true;
    overlay.changed.clear();
    batch.rawUpdate(
        "UPDATE $stateTable SET current_epoch=current_epoch+1,head_seq=0,tail_seq=-1,item_count=0,revision=revision+1,migration_state='ready' WHERE fragment_key=?",
        [key]);
    _completeEpoch(batch, key);
  }

  Future<int> count(String key) async {
    await prepare(key);
    return _gate(() async => collection.timelineBatch != null
        ? (await _overlay(key)).count
        : (await _state(key))!['item_count'] as int);
  }

  Future<Map<String, int>> positions(String key, Iterable<String> ids) async {
    final requested = ids.toSet().toList();
    if (requested.length > 256) throw RangeError('Maximum256 positions');
    if (requested.isEmpty) return {};
    await prepare(key);
    return _gate(() async {
      final overlay =
          collection.timelineBatch == null ? null : await _overlay(key);
      final state = await _state(key);
      final rows = overlay?.reset == true || state == null
          ? <Map<String, Object?>>[]
          : await sql.rawQuery(
              'SELECT event_id,MIN(seq) AS position FROM $idTable WHERE fragment_key=? AND epoch=? AND valid_to IS NULL AND event_id IN (${List.filled(requested.length, '?').join(',')}) GROUP BY event_id',
              [key, state['current_epoch'], ...requested]);
      final result = {
        for (final row in rows)
          row['event_id'] as String: row['position'] as int
      };
      if (overlay != null) {
        for (final id in requested) {
          if (!overlay.changed.containsKey(id)) continue;
          final member = overlay.changed[id];
          if (member == null) {
            result.remove(id);
          } else {
            result[id] = member.seq;
          }
        }
      }
      return result;
    });
  }

  Future<TimelineIdSnapshot> snapshot(String key,
      {String? afterEventId,
      TimelineIdDirection direction = TimelineIdDirection.older}) async {
    await prepare(key);
    return _gate(() async {
      final state = (await _state(key))!;
      var cursor = direction == TimelineIdDirection.older
          ? (state['head_seq'] as int) - 1
          : (state['tail_seq'] as int) + 1;
      if (afterEventId != null) {
        final position = await positions(key, [afterEventId]);
        if (!position.containsKey(afterEventId)) {
          throw const TimelineAnchorUnavailable();
        }
        cursor = position[afterEventId]!;
      }
      final handle = _SqlSnapshot(
          this,
          key,
          state['current_epoch'] as int,
          state['revision'] as int,
          state['tail_seq'] as int,
          state['item_count'] as int,
          cursor,
          state['head_seq'] as int,
          direction);
      _leases.add(handle);
      return handle;
    });
  }

  Future<List<String>> page(String key, {int start = 0, int? limit}) async {
    if (start < 0) throw RangeError.value(start);
    await prepare(key);
    if (collection.timelineBatch != null) {
      return _batchPage(key, start: start, limit: limit);
    }
    final snapshot = await this.snapshot(key);
    final result = <String>[];
    var skipped = 0;
    try {
      while (true) {
        final remaining =
            limit == null ? 256 : start - skipped + limit - result.length;
        if (remaining <= 0) break;
        final page = await snapshot.next(limit: remaining.clamp(1, 256));
        for (final id in page.ids) {
          if (skipped < start) {
            skipped++;
          } else {
            result.add(id);
          }
        }
        snapshot.accept(page);
        if (!page.hasMore) break;
      }
      return result;
    } finally {
      snapshot.dispose();
    }
  }

  /// Read this transaction's changed IDs without flushing the atomic batch.
  /// Other zones cannot enter this path: timelineBatch is owner-zone scoped.
  Future<List<String>> _batchPage(String key,
      {required int start, int? limit}) async {
    if (limit != null && limit <= 0) return [];
    final overlay = await _overlay(key);
    final changed = overlay.changed.entries
        .where((entry) => entry.value != null)
        .toList()
      ..sort((a, b) => a.value!.seq.compareTo(b.value!.seq));
    final state = await _state(key);
    var exhausted = overlay.reset || state == null;
    var after = (state?['head_seq'] as int? ?? 0) - 1;
    final tail = state?['tail_seq'] as int? ?? -1;
    var rows = <Map<String, Object?>>[];
    var rowIndex = 0;
    Future<({String id, int seq})?> nextCommitted() async {
      while (true) {
        while (rowIndex < rows.length) {
          final row = rows[rowIndex++];
          final id = row['event_id'] as String;
          if (row['valid_to'] == null && !overlay.changed.containsKey(id)) {
            return (id: id, seq: row['seq'] as int);
          }
        }
        if (exhausted) return null;
        rows = await sql.rawQuery(
            'SELECT seq,event_id,valid_to FROM $idTable '
            'WHERE fragment_key=? AND epoch=? AND seq>? AND seq<=? '
            'ORDER BY seq LIMIT 256',
            [key, overlay.epoch, after, tail]);
        rowIndex = 0;
        if (rows.isEmpty) return null;
        after = rows.last['seq'] as int;
        exhausted = rows.length < 256 || after >= tail;
      }
    }

    final result = <String>[];
    var changedIndex = 0, skipped = 0;
    var committed = await nextCommitted();
    while (changedIndex < changed.length || committed != null) {
      late String id;
      if (changedIndex < changed.length &&
          (committed == null ||
              changed[changedIndex].value!.seq < committed.seq)) {
        id = changed[changedIndex++].key;
      } else {
        id = committed!.id;
        committed = await nextCommitted();
      }
      if (skipped < start) {
        skipped++;
      } else {
        result.add(id);
        if (limit != null && result.length >= limit) break;
      }
    }
    return result;
  }

  Future<List<String>> preview(String key, int limit) async {
    final state = await _gate(() => _state(key));
    if (state?['migration_state'] == 'ready') return page(key, limit: limit);
    // SQL executes in the native driver worker; only a bounded ID result crosses.
    return _gate(() async {
      final rows = await sql.rawQuery(
          'SELECT j.value AS id FROM box_timeline_fragments t,json_each(t.v) j WHERE t.k=? ORDER BY CAST(j.key AS INTEGER) LIMIT ?',
          [key, limit]);
      return rows.map((r) => r['id'] as String).toList();
    });
  }

  /// Explicit legacy-format export only. Deliberately O(total history), never
  /// used by page, preview, pin, count or search consumers.
  Future<Map<String, List>> exportLegacy() async {
    final result = <String, List>{};
    final keys = await _gate(() async => <String>{
          ...(await sql.query(stateTable, columns: ['fragment_key']))
              .map((r) => r['fragment_key'] as String),
          ...(await sql.query('box_timeline_fragments', columns: ['k']))
              .map((r) => r['k'] as String),
        });
    for (final key in keys) {
      result[key] = await page(key);
    }
    return result;
  }

  /// Called only after independent retained-search authority is ready. Each
  /// transaction removes <=256 metadata rows and releases the gate afterwards.
  Future<void> collectGarbage(String key) {
    _check();
    _collectible.add(key);
    return _collecting.putIfAbsent(
        key,
        () => _collect(key).whenComplete(() {
              unawaited(_collecting.remove(key));
            }));
  }

  Future<void> _collect(String key) async {
    while (!_closed) {
      final more = await _gate(() async {
        if (_leases.any((lease) => lease.key == key)) return false;
        final state = await _state(key);
        if (state == null || state['migration_state'] != 'ready') return false;
        final epoch = state['current_epoch'];
        var rows = await sql.rawQuery(
            'SELECT epoch,seq FROM $idTable WHERE fragment_key=? AND epoch<? '
            'ORDER BY epoch,seq LIMIT 256',
            [key, epoch]);
        if (rows.isEmpty) {
          rows = await sql.rawQuery(
              'SELECT epoch,seq FROM $idTable WHERE fragment_key=? '
              'AND epoch=? AND valid_to IS NOT NULL ORDER BY seq LIMIT 256',
              [key, epoch]);
        }
        final batch = sql.batch();
        if (rows.isNotEmpty) {
          for (final row in rows) {
            batch.delete(idTable,
                where: 'fragment_key=? AND epoch=? AND seq=?',
                whereArgs: [key, row['epoch'], row['seq']]);
          }
        } else {
          rows = await sql.rawQuery(
              'SELECT epoch FROM $epochTable WHERE fragment_key=? AND epoch<? ORDER BY epoch LIMIT 256',
              [key, epoch]);
          for (final row in rows) {
            batch.delete(epochTable,
                where: 'fragment_key=? AND epoch=?',
                whereArgs: [key, row['epoch']]);
          }
        }
        if (rows.isEmpty) return false;
        await batch.commit(noResult: true);
        return true;
      });
      if (!more) return;
      await Future<void>.delayed(Duration.zero);
    }
  }

  void scheduleGarbage(String key) {
    if (_closed) return;
    unawaited(_observeMaintenance(collectGarbage(key)));
  }

  void _released(String key) {
    if (_closed ||
        !_collectible.contains(key) ||
        _leases.any((lease) => lease.key == key)) {
      return;
    }
    scheduleGarbage(key);
  }

  Future<void> clear() async {
    _ready.clear();
    _collectible.clear();
    for (final lease in _leases.toList()) {
      lease.dispose();
    }
    final batch = collection.timelineBatch;
    if (batch == null) {
      await collection.transaction(clear);
      return;
    }
    batch.delete(idTable);
    batch.delete(epochTable);
    batch.delete(stateTable);
  }

  Future<void> close() async {
    _closed = true;
    for (final lease in _leases.toList()) {
      lease.dispose();
    }
    await Future.wait(
        _preparing.values.map((f) => f.catchError((Object _) {})));
    await Future.wait(_collecting.values.toList().map(_observeMaintenance));
    _reportMaintenanceFailure();
  }
}

/// Only IDs modified by the active original SDK batch are retained. Discarded
/// by BoxCollection on both commit and rollback; never proportional to history.
class _BatchOrder {
  _BatchOrder(this.epoch, this.head, this.tail, this.count);
  int epoch, head, tail, count;
  bool reset = false;
  final changed = <String, ({int seq, int count})?>{};
}

class _SqlSnapshot implements TimelineIdSnapshot {
  _SqlSnapshot(this.store, this.key, this.epoch, this.revision, this.tail,
      this.length, this.cursor, this.head, this.direction);
  final TimelineIdStore store;
  final String key;
  final int epoch, revision, tail, head;
  final TimelineIdDirection direction;
  @override
  final int length;
  int cursor;
  bool _disposed = false;
  TimelineIdPage? _pending;
  @override
  Future<TimelineIdPage> next({int limit = 30}) async {
    if (limit < 1 || limit > 256) throw RangeError.range(limit, 1, 256);
    store._check();
    if (_disposed) throw TimelineSnapshotDisposed();
    if (_pending != null) return _pending!;
    return store._gate(() async {
      if (_disposed) throw TimelineSnapshotDisposed();
      final newer = direction == TimelineIdDirection.newer;
      final comparison = newer ? '<' : '>';
      final order = newer ? 'DESC' : 'ASC';
      final rows = await store.sql.rawQuery(
          'SELECT seq,event_id,valid_from,valid_to FROM ${TimelineIdStore.idTable} '
          'WHERE fragment_key=? AND epoch=? AND seq$comparison? AND seq<=? AND seq>=? ORDER BY seq $order LIMIT ?',
          [key, epoch, cursor, tail, head, limit]);
      final end =
          rows.isEmpty ? (newer ? head : tail) : rows.last['seq'] as int;
      final visible = rows.where((r) =>
          (r['valid_from'] as int) <= revision &&
          (r['valid_to'] == null || (r['valid_to'] as int) > revision));
      // The primary-key range bounds RAW work before revision filtering.
      // Conservative tail bounds can yield one final empty page; accepting an
      // empty filtered page still advances the immutable sequence cursor.
      return _pending = TimelineIdPage(
          List.unmodifiable(visible.map((r) => r['event_id'] as String)),
          hasMore: rows.length == limit && (newer ? end > head : end < tail),
          cursor: end,
          rawCount: rows.length);
    });
  }

  @override
  Future<TimelineIdSnapshot> checkpoint() async {
    store._check();
    if (_disposed) throw TimelineSnapshotDisposed();
    final lease = _SqlSnapshot(
        store, key, epoch, revision, tail, length, cursor, head, direction);
    store._leases.add(lease);
    return lease;
  }

  @override
  Future<TimelineIdSnapshot> fork(
      {required String afterEventId,
      TimelineIdDirection direction = TimelineIdDirection.older}) async {
    store._check();
    if (_disposed) throw TimelineSnapshotDisposed();
    return store._gate(() async {
      if (_disposed) throw TimelineSnapshotDisposed();
      final rows = await store.sql.rawQuery(
          'SELECT seq FROM ${TimelineIdStore.idTable} '
          'WHERE fragment_key=? AND epoch=? AND event_id=? AND seq>=? AND seq<=? '
          'AND valid_from<=? AND (valid_to IS NULL OR valid_to>?) ORDER BY seq LIMIT 1',
          [key, epoch, afterEventId, head, tail, revision, revision]);
      if (rows.isEmpty) throw const TimelineAnchorUnavailable();
      final lease = _SqlSnapshot(store, key, epoch, revision, tail, length,
          rows.single['seq'] as int, head, direction);
      store._leases.add(lease);
      return lease;
    });
  }

  @override
  void accept(TimelineIdPage page) {
    if (_disposed || !identical(page, _pending)) {
      throw StateError('Invalid timeline page');
    }
    cursor = page.cursor;
    _pending = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _pending = null;
    store._leases.remove(this);
    store._released(key);
  }
}
