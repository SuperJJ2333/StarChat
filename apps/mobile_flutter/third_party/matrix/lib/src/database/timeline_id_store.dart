import 'dart:async';
import 'package:matrix/src/database/database_api.dart';
import 'package:matrix/src/database/sqflite_box.dart';
import 'package:sqflite_common/sqflite.dart';

/// Additive ordering metadata. Bodies and the legacy migration source remain
/// untouched. All event-order mutations join the SDK's original atomic batch.
class TimelineIdStore {
  TimelineIdStore(this.collection, this.reader,
      {this.waitForMaintenance,
      this.legacyPageReader,
      this.acquireMaintenanceLease});
  final BoxCollection collection;
  final TimelineMigrationReader? reader;
  final Future<void> Function()? waitForMaintenance;
  final Future<void Function()?> Function(Future<void>)?
      acquireMaintenanceLease;
  final TimelineLegacyPageReader? legacyPageReader;
  int _maintenanceChunks = 0,
      _maintenanceMaxMicros = 0,
      _maintenanceOverBudget = 0,
      _maintenanceMinimumRows = 256,
      _maintenanceNextLimit = 256;

  /// Fixed-size diagnostic counters; contains no event IDs or message contents.
  Map<String, int> get maintenanceMetrics => {
        'chunks': _maintenanceChunks,
        'maxMicros': _maintenanceMaxMicros,
        'overBudget': _maintenanceOverBudget,
        'minimumRows': _maintenanceMinimumRows,
        'nextLimit': _maintenanceNextLimit
      };
  static const legacyBoundary = 1 << 40;
  Database get sql => collection.timelineDatabase;
  static const stateTable = 'matrix_timeline_fragment_state';
  static const idTable = 'matrix_timeline_fragment_ids';
  static const epochTable = 'matrix_timeline_complete_epochs';
  static const baseTable = 'matrix_timeline_legacy_bases';
  static const membershipTable = 'matrix_timeline_legacy_membership';
  static const tombstoneTable = 'matrix_timeline_legacy_tombstones';
  final _collectible = <String>{};
  final _collecting = <String, Future<void>>{};
  final Map<String, Future<void>> _preparing = {};
  Future<void> _maintenanceTail = Future.value();
  final _closedSignal = Completer<void>();
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
    batch.execute('CREATE TABLE IF NOT EXISTS $baseTable ('
        'fragment_key TEXT NOT NULL,epoch INTEGER NOT NULL,item_count INTEGER NOT NULL,'
        'source_identity TEXT NOT NULL,PRIMARY KEY(fragment_key,epoch))');
    batch.execute('CREATE TABLE IF NOT EXISTS $tombstoneTable ('
        'fragment_key TEXT NOT NULL,epoch INTEGER NOT NULL,event_id TEXT NOT NULL,'
        'valid_from INTEGER NOT NULL,PRIMARY KEY(fragment_key,epoch,event_id))');
    batch.execute('CREATE TABLE IF NOT EXISTS $membershipTable ('
        'fragment_key TEXT NOT NULL,epoch INTEGER NOT NULL,event_id TEXT NOT NULL,seq INTEGER,'
        'PRIMARY KEY(fragment_key,epoch,event_id))');
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

  /// Explicit maintenance barrier. Foreground operations use [prepare] instead.
  Future<void> prepareComplete(String key) {
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
    return _preparing.putIfAbsent(key, () {
      final task = _maintenanceTail.then((_) => _prepare(key));
      _maintenanceTail = task.catchError((Object _) {});
      return task.whenComplete(() {
        unawaited(_preparing.remove(key));
      });
    });
  }

  /// Establish old-source + revisioned delta authority without awaiting copy.
  Future<void> prepare(String key, {bool scheduleMaintenance = true}) async {
    _check();
    if (collection.timelineOwnsTransaction &&
        (collection.timelineOverlay['timeline:$key'] as _BatchOrder?)?.reset ==
            true) {
      return;
    }
    await _gate(() async {
      var state = await _state(key);
      if (state?['migration_state'] == 'ready') {
        _ready.add(key);
        return;
      }
      final source = await _sourceIdentity(key);
      if (source == null) {
        final batch = collection.timelineBatch ?? sql.batch();
        _initialize(batch, key);
        if (collection.timelineBatch == null) {
          await batch.commit(noResult: true);
          _ready.add(key);
        }
        return;
      }
      if (state != null && state['source_identity'] != source) {
        if (collection.timelineBatch != null || state['revision'] != 0) {
          throw StateError('Legacy timeline source changed');
        }
        // An externally replaced, never-published partial copy has no delta
        // writes to preserve. Restart in a fresh generation, retaining leases.
        await sql.rawUpdate(
            'UPDATE $stateTable SET current_epoch=current_epoch+1,'
            'head_seq=0,tail_seq=-1,item_count=0,migration_next=0,source_identity=? '
            'WHERE fragment_key=?',
            [source, key]);
        state = await _state(key);
      }
      final epoch = state?['current_epoch'] as int? ?? 1;
      final bases = await sql.query(baseTable,
          where: 'fragment_key=? AND epoch=?', whereArgs: [key, epoch]);
      if (bases.isNotEmpty) return;
      // Reserve disjoint ordering without parsing the full retained source.
      const count = legacyBoundary;
      final batch = collection.timelineBatch ?? sql.batch();
      batch.rawInsert(
          'INSERT OR IGNORE INTO $stateTable '
          '(fragment_key,current_epoch,head_seq,tail_seq,item_count,revision,migration_state,migration_next,source_identity) '
          "VALUES (?,1,0,?, ?,0,'copying',0,?)",
          [key, count - 1, 0, source]);
      batch.insert(baseTable, {
        'fragment_key': key,
        'epoch': epoch,
        'item_count': -1,
        'source_identity': source
      });
      // Upgrade an interrupted index from the previous binary. Partial rows
      // have never been authoritative; the fixed base reserves their range.
      batch.update(stateTable, {'tail_seq': count - 1},
          where: 'fragment_key=?', whereArgs: [key]);
      if (collection.timelineBatch == null) {
        await batch.commit(noResult: true);
      } else {
        collection.timelineOverlay['timeline:$key'] =
            _BatchOrder(epoch, 0, count - 1, 0)..baseCount = count;
      }
    });
    if (scheduleMaintenance &&
        !collection.timelineOwnsTransaction &&
        !_ready.contains(key)) {
      // A failed copy is retryable maintenance; the immutable base/delta remain
      // readable. Explicit completion callers still receive the original error.
      unawaited(prepareComplete(key).catchError((Object _) {}));
    }
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
    // Establish the immutable base before publishing any canonical rows.
    await prepare(key);
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
    final migrationEpoch = (await _gate(() => _state(key)))!['current_epoch'];
    var ordinal = 0, batchLimit = 256, pageOffset = 0, quietBatches = 0;
    var buffered = <String>[];
    final pages = StreamIterator(reader?.call(key) ?? _boundedLegacy(key));
    try {
      while (true) {
        _check();
        if (waitForMaintenance != null) {
          await Future.any([waitForMaintenance!(), _closedSignal.future]);
        }
        _check();
        final releaseLease =
            await acquireMaintenanceLease?.call(_closedSignal.future);
        try {
          _check();
          if (pageOffset >= buffered.length) {
            if (!await pages.moveNext()) break;
            _check();
            buffered = pages.current;
            pageOffset = 0;
            if (buffered.isEmpty || buffered.length > 256) {
              throw StateError('Invalid timeline migration page');
            }
          }
          final end = (pageOffset + batchLimit).clamp(0, buffered.length);
          final page = buffered.sublist(pageOffset, end);
          pageOffset = end;
          var superseded = false;
          final begin = ordinal;
          ordinal += page.length;
          await _gate(() async {
            final elapsed = Stopwatch()..start();
            final state = (await _state(key))!;
            if (state['migration_state'] == 'ready' ||
                state['current_epoch'] != migrationEpoch) {
              superseded = true;
              return;
            }
            await _assertSource(key, state);
            final next = state['migration_next'] as int;
            if (ordinal <= next) return;
            final batch = sql.batch();
            for (var i = 0; i < page.length; i++) {
              if (begin + i < next) continue;
              batch.rawInsert(
                  'INSERT OR IGNORE INTO $idTable '
                  '(fragment_key,epoch,seq,event_id,valid_from,valid_to) VALUES (?,?,?,?,0,'
                  '(SELECT valid_from FROM $tombstoneTable WHERE fragment_key=? AND epoch=? AND event_id=?))',
                  [
                    key,
                    migrationEpoch,
                    begin + i,
                    page[i],
                    key,
                    migrationEpoch,
                    page[i]
                  ]);
            }
            batch.update(
                stateTable,
                {
                  'migration_next': ordinal,
                },
                where: 'fragment_key = ? AND migration_state = ?',
                whereArgs: [key, 'copying']);
            batch.rawUpdate(
                'UPDATE $stateTable SET item_count=item_count+'
                '(SELECT COUNT(*) FROM $idTable WHERE fragment_key=? AND epoch=? '
                'AND seq>=? AND seq<? AND valid_to IS NULL) WHERE fragment_key=?',
                [key, migrationEpoch, next, ordinal, key]);
            await batch.commit(noResult: true);
            elapsed.stop();
            _maintenanceChunks++;
            if (elapsed.elapsedMicroseconds > _maintenanceMaxMicros) {
              _maintenanceMaxMicros = elapsed.elapsedMicroseconds;
            }
            if (page.length < _maintenanceMinimumRows) {
              _maintenanceMinimumRows = page.length;
            }
            if (elapsed.elapsedMicroseconds > 4000) _maintenanceOverBudget++;
            if (elapsed.elapsedMicroseconds > 4000 && batchLimit > 1) {
              batchLimit = (batchLimit * 4000 ~/ elapsed.elapsedMicroseconds)
                  .clamp(1, batchLimit - 1);
              quietBatches = 0;
            } else if (elapsed.elapsedMicroseconds < 2000 &&
                page.length == batchLimit) {
              quietBatches++;
              if (quietBatches >= 8) {
                batchLimit =
                    (batchLimit + (batchLimit ~/ 8).clamp(1, 32)).clamp(1, 256);
                quietBatches = 0;
              }
            } else {
              quietBatches = 0;
            }
            _maintenanceNextLimit = batchLimit;
          });
          if (superseded) return;
        } finally {
          releaseLease?.call();
        }
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      await pages.cancel();
    }
    await _gate(() async {
      final state = (await _state(key))!;
      if (state['migration_state'] == 'ready' ||
          state['current_epoch'] != migrationEpoch) {
        return;
      }
      if (state['migration_next'] != ordinal) {
        throw StateError('Incomplete timeline migration');
      }
      final base = (await sql.query(baseTable,
              where: 'fragment_key=? AND epoch=?',
              whereArgs: [key, migrationEpoch]))
          .single;
      if (base['item_count'] != -1 && base['item_count'] != ordinal) {
        throw StateError('Incomplete timeline migration');
      }
      final source = await _sourceIdentity(key);
      if (source == null || state['source_identity'] != source) {
        throw StateError('Legacy timeline source changed');
      }
      final batch = sql.batch();
      batch.rawUpdate(
          'UPDATE $stateTable SET migration_state=\'ready\','
          'tail_seq=CASE WHEN tail_seq<? THEN ? ELSE tail_seq END WHERE fragment_key=?',
          [legacyBoundary, ordinal - 1, key]);
      batch.update(baseTable, {'item_count': ordinal},
          where: 'fragment_key=? AND epoch=?',
          whereArgs: [key, migrationEpoch]);
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
      final rows = await _gate(() => sql.rawQuery(
          'SELECT substr(CAST(v AS BLOB), ?, 32768) AS chunk FROM box_timeline_fragments WHERE k = ?',
          [offset, key]));
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
    if (state?['migration_state'] == 'copying') {
      final bases = await sql.query(baseTable,
          where: 'fragment_key=? AND epoch=?', whereArgs: [key, overlay.epoch]);
      overlay.baseCount = bases.isEmpty ? 0 : legacyBoundary;
    }
    collection.timelineOverlay[cacheKey] = overlay;
    return overlay;
  }

  Future<({int seq, int count})?> _membership(
      String key, String id, _BatchOrder overlay,
      {bool requireBase = true}) async {
    if (overlay.changed.containsKey(id)) return overlay.changed[id];
    if (overlay.reset) return null;
    final rows = await sql.rawQuery(
        'SELECT MIN(seq) AS seq,COUNT(*) AS n FROM $idTable '
        'WHERE fragment_key=? AND epoch=? AND event_id=? AND valid_to IS NULL '
        '${overlay.baseCount > 0 ? 'AND (seq<0 OR seq>=?)' : ''}',
        [key, overlay.epoch, id, if (overlay.baseCount > 0) overlay.baseCount]);
    final n = rows.single['n'] as int;
    if (n > 0) return (seq: rows.single['seq'] as int, count: n);
    if (overlay.baseCount == 0 || !requireBase) return null;
    var known = _membershipHints[(key, id)];
    if (known == null || known.epoch != overlay.epoch) {
      final persisted = await sql.query(membershipTable,
          columns: ['seq'],
          where: 'fragment_key=? AND epoch=? AND event_id=?',
          whereArgs: [key, overlay.epoch, id]);
      if (persisted.isNotEmpty) {
        known = (epoch: overlay.epoch, seq: persisted.single['seq'] as int?);
      }
    }
    if (known == null || known.epoch != overlay.epoch) {
      // Generic SDK transactions cannot predict callback IDs beforehand. Keep
      // their callback/batch ownership intact and perform an exact read-only
      // lookup; never infer absence from a missing event body or replay action.
      final source = await _sourceIdentity(key);
      _check();
      if (source == null) throw StateError('Legacy source missing');
      final positions =
          (await _legacyPage(key, source, findEventIds: [id])).positions;
      known = (epoch: overlay.epoch, seq: positions[id]);
      _membershipHints[(key, id)] = known;
      while (_membershipHints.length > 512) {
        _membershipHints.remove(_membershipHints.keys.first);
      }
      collection.timelineBatch!.rawInsert(
          'INSERT OR REPLACE INTO $membershipTable(fragment_key,epoch,event_id,seq) VALUES (?,?,?,?)',
          [key, overlay.epoch, id, known.seq]);
    }
    final deleted = await sql.query(tombstoneTable,
        columns: ['event_id'],
        where: 'fragment_key=? AND epoch=? AND event_id=?',
        whereArgs: [key, overlay.epoch, id]);
    if (deleted.isNotEmpty || known.seq == null) return null;
    return (seq: known.seq!, count: 1);
  }

  Future<int> _stageRemoval(String key, String id, _BatchOrder overlay) async {
    final previous = await _membership(key, id, overlay, requireBase: false);
    overlay.count -= previous?.count ?? 0;
    overlay.changed[id] = null;
    return previous?.count ?? 0;
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
      final removed = await _stageRemoval(key, id, overlay);
      _remove(batch, key, id, removed);
    }
    if (await _membership(key, id, overlay) == null) {
      final seq = tail ? ++overlay.tail : --overlay.head;
      overlay.changed[id] = (seq: seq, count: 1);
      overlay.count++;
    } else {
      return;
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

  void _remove(Batch batch, String key, String id, int removed) {
    batch.rawInsert(
        'INSERT OR IGNORE INTO $tombstoneTable '
        '(fragment_key,epoch,event_id,valid_from) '
        'SELECT fragment_key,current_epoch,?,revision+1 FROM $stateTable WHERE fragment_key=?',
        [id, key]);
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
    final removed = await _stageRemoval(key, id, await _overlay(key));
    _remove(batch, key, id, removed);
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
    overlay.baseCount = 0;
    batch.rawUpdate(
        "UPDATE $stateTable SET current_epoch=current_epoch+1,head_seq=0,tail_seq=-1,item_count=0,revision=revision+1,migration_state='ready' WHERE fragment_key=?",
        [key]);
    _completeEpoch(batch, key);
  }

  Future<int> count(String key) async {
    await prepare(key, scheduleMaintenance: false);
    await prepareComplete(key);
    return _gate(() async => collection.timelineBatch != null
        ? (await _overlay(key)).count
        : (await _state(key))!['item_count'] as int);
  }

  Future<Map<String, int>> positions(String key, Iterable<String> ids) async {
    final requested = ids.toSet().toList();
    if (requested.length > 256) throw RangeError('Maximum256 positions');
    if (requested.isEmpty) return {};
    await prepare(key);
    final state = await _gate(() => _state(key));
    final epoch = state?['current_epoch'] as int? ?? 1;
    var legacy = <String, int>{};
    final persisted = state?['migration_state'] == 'copying'
        ? await _gate(() => sql.rawQuery(
            'SELECT event_id,seq FROM $membershipTable WHERE fragment_key=? AND epoch=? '
            'AND event_id IN (${List.filled(requested.length, '?').join(',')})',
            [key, epoch, ...requested]))
        : <Map<String, Object?>>[];
    final authoritative = {
      for (final row in persisted) row['event_id'] as String: row['seq'] as int?
    };
    if (state?['migration_state'] == 'copying' &&
        !requested.every((id) =>
            authoritative.containsKey(id) ||
            _membershipHints[(key, id)]?.epoch == epoch)) {
      if (collection.timelineOwnsTransaction) {
        throw StateError(
            'Legacy positions require preflight outside transaction');
      }
      legacy = (await _legacyPage(key, state!['source_identity'] as String,
              findEventIds: requested))
          .positions;
      await _gate(() async {
        if ((await _state(key))?['current_epoch'] != epoch) {
          throw const TimelineAnchorUnavailable();
        }
        final batch = sql.batch();
        for (final id in requested) {
          batch.rawInsert(
              'INSERT OR REPLACE INTO $membershipTable(fragment_key,epoch,event_id,seq) VALUES (?,?,?,?)',
              [key, epoch, id, legacy[id]]);
        }
        await batch.commit(noResult: true);
      });
      for (final id in requested) {
        _membershipHints[(key, id)] = (epoch: epoch, seq: legacy[id]);
      }
      while (_membershipHints.length > 512) {
        _membershipHints.remove(_membershipHints.keys.first);
      }
    }
    if (state?['migration_state'] == 'copying' && legacy.isEmpty) {
      legacy = {
        for (final id in requested)
          if ((authoritative[id] ?? _membershipHints[(key, id)]?.seq) != null)
            id: (authoritative[id] ?? _membershipHints[(key, id)]!.seq!)
      };
    }
    return _gate(() async {
      final current = await _state(key);
      if (current?['current_epoch'] != epoch) {
        throw const TimelineAnchorUnavailable();
      }
      final overlay =
          collection.timelineBatch == null ? null : await _overlay(key);
      final result = <String, int>{...legacy};
      final rows = await sql.rawQuery(
          'SELECT event_id,MIN(seq) AS position FROM $idTable '
          'WHERE fragment_key=? AND epoch=? AND valid_to IS NULL '
          '${state?['migration_state'] == 'copying' ? 'AND (seq<0 OR seq>=?)' : ''} '
          'AND event_id IN (${List.filled(requested.length, '?').join(',')}) GROUP BY event_id',
          [
            key,
            epoch,
            if (state?['migration_state'] == 'copying') legacyBoundary,
            ...requested
          ]);
      final deleted = await sql.rawQuery(
          'SELECT event_id FROM $tombstoneTable '
          'WHERE fragment_key=? AND epoch=? AND event_id IN (${List.filled(requested.length, '?').join(',')})',
          [key, epoch, ...requested]);
      for (final row in deleted) {
        result.remove(row['event_id']);
      }
      for (final row in rows) {
        result[row['event_id'] as String] = row['position'] as int;
      }
      if (overlay != null) {
        if (overlay.reset) result.clear();
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

  Future<void> _foregroundPageTail = Future.value();
  Future<void> _optionalPreviewTail = Future.value();
  static final Object _optionalPreviewZone = Object();
  Future<void> _foregroundMembershipTail = Future.value();

  final _membershipHints = <(String, String), ({int epoch, int? seq})>{};

  Future<TimelineLegacyPage> _legacyPage(String key, String source,
      {int start = 0,
      int limit = 256,
      List<String>? findEventIds,
      bool reverse = false}) async {
    if (legacyPageReader != null) {
      final optionalPreview = Zone.current[_optionalPreviewZone] == true;
      final tail = findEventIds != null
          ? _foregroundMembershipTail
          : optionalPreview
              ? _optionalPreviewTail
              : _foregroundPageTail;
      final task = tail.then((_) async {
        _check();
        final result = await legacyPageReader!(key, source,
            start: start,
            limit: limit,
            findEventIds: findEventIds,
            reverse: reverse,
            isCancelled: () => _closed);
        _check();
        if (findEventIds == null && result.ids.isNotEmpty) {
          await _gate(() async {
            final state = await _state(key);
            if (state?['migration_state'] != 'copying' ||
                state?['source_identity'] != source) {
              return;
            }
            final batch = sql.batch();
            for (var i = 0; i < result.ids.length; i++) {
              final seq = result.start + (reverse ? -i : i);
              batch.rawInsert(
                  'INSERT INTO $membershipTable(fragment_key,epoch,event_id,seq) VALUES (?,?,?,?) '
                  'ON CONFLICT(fragment_key,epoch,event_id) DO UPDATE SET seq=CASE WHEN seq IS NULL THEN excluded.seq ELSE MIN(seq,excluded.seq) END',
                  [key, state!['current_epoch'], result.ids[i], seq]);
            }
            await batch.commit(noResult: true);
          });
        }
        return result;
      });
      final completion =
          task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
      if (findEventIds == null) {
        if (optionalPreview) {
          _optionalPreviewTail = completion;
        } else {
          _foregroundPageTail = completion;
        }
      } else {
        _foregroundMembershipTail = completion;
      }
      return task;
    }
    // Compatibility for caller-supplied in-memory databases. Production uses
    // independent, native BLOB access and never decodes old JSON on UI.
    final requested = findEventIds?.toSet(), found = <String, int>{};
    final ids = <String>[];
    var ordinal = 0, more = false;
    await for (final page in _boundedLegacy(key)) {
      if (await _gate(() => _sourceIdentity(key)) != source) {
        throw StateError('Legacy source changed');
      }
      for (final id in page) {
        if (requested != null) {
          if (requested.contains(id)) found.putIfAbsent(id, () => ordinal);
        } else if (reverse ? ordinal <= start : ordinal >= start) {
          if (reverse) {
            ids.add(id);
            if (ids.length > limit) ids.removeAt(0);
          } else if (ids.length < limit) {
            ids.add(id);
          } else {
            more = true;
            break;
          }
        }
        ordinal++;
      }
      if (requested != null && found.length == requested.length ||
          requested == null &&
              (!reverse && more || reverse && ordinal > start)) {
        break;
      }
    }
    return TimelineLegacyPage(reverse ? ids.reversed.toList() : ids,
        start: reverse ? (ordinal - 1).clamp(0, start) : start,
        hasMore: reverse ? start - ids.length >= 0 : more,
        positions: found);
  }

  Future<TimelineIdSnapshot> snapshot(String key,
      {String? afterEventId,
      bool scheduleMaintenance = true,
      TimelineIdDirection direction = TimelineIdDirection.older}) async {
    await prepare(key, scheduleMaintenance: scheduleMaintenance);
    final anchor =
        afterEventId == null ? null : await positions(key, [afterEventId]);
    return _gate(() async {
      final state = (await _state(key))!;
      var cursor = direction == TimelineIdDirection.older
          ? (state['head_seq'] as int) - 1
          : (state['tail_seq'] as int) + 1;
      if (afterEventId != null) {
        final position = anchor!;
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
          state['migration_state'] == 'copying'
              ? -1
              : state['item_count'] as int,
          cursor,
          state['head_seq'] as int,
          direction,
          legacyCount:
              state['migration_state'] == 'copying' ? legacyBoundary : null,
          sourceIdentity: state['source_identity'] as String?);
      _leases.add(handle);
      return handle;
    });
  }

  Future<List<String>> page(String key,
      {int start = 0, int? limit, bool scheduleMaintenance = true}) async {
    if (start < 0) throw RangeError.value(start);
    await prepare(key, scheduleMaintenance: scheduleMaintenance);
    if (collection.timelineBatch != null) {
      return _batchPage(key, start: start, limit: limit);
    }
    final snapshot =
        await this.snapshot(key, scheduleMaintenance: scheduleMaintenance);
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
        rows = await _snapshotRows(
            key,
            overlay.epoch,
            after,
            tail,
            state?['head_seq'] as int? ?? 0,
            256,
            TimelineIdDirection.older,
            overlay.baseCount > 0 ? overlay.baseCount : null);
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
    // One optional repair worker may run alongside the active bounded page.
    // Keep preview serialization separate so a slow old room cannot queue the
    // selected room's cached head behind its optional repair.
    return runZoned(() => page(key, limit: limit, scheduleMaintenance: false),
        zoneValues: {_optionalPreviewZone: true});
  }

  /// Delta head, immutable base and delta tail occupy disjoint sequence ranges.
  /// Read at most one page from each range, excluding partial canonical copies.
  Future<List<Map<String, Object?>>> _snapshotRows(
      String key,
      int epoch,
      int cursor,
      int tail,
      int head,
      int limit,
      TimelineIdDirection direction,
      int? legacyCount) async {
    final newer = direction == TimelineIdDirection.newer;
    final comparison = newer ? '<' : '>';
    final order = newer ? 'DESC' : 'ASC';
    if (legacyCount == null) {
      return sql.rawQuery(
          'SELECT seq,event_id,valid_from,valid_to FROM $idTable '
          'WHERE fragment_key=? AND epoch=? AND seq$comparison? AND seq<=? AND seq>=? ORDER BY seq $order LIMIT ?',
          [key, epoch, cursor, tail, head, limit]);
    }
    final result = <Map<String, Object?>>[];
    for (final part in newer ? [2, 1, 0] : [0, 1, 2]) {
      final remaining = limit - result.length;
      if (remaining == 0) break;
      List<Map<String, Object?>> rows;
      if (part == 1) {
        if (newer ? cursor <= 0 : cursor >= legacyBoundary - 1) continue;
        final bases = await _gate(() => sql.query(baseTable,
            where: 'fragment_key=? AND epoch=?', whereArgs: [key, epoch]));
        final source = bases.single['source_identity'] as String;
        final page = await _legacyPage(key, source,
            start:
                newer ? cursor - 1 : (cursor + 1).clamp(0, legacyBoundary - 1),
            limit: remaining,
            reverse: newer);
        final deleted = page.ids.isEmpty
            ? <Map<String, Object?>>[]
            : await _gate(() => sql.rawQuery(
                'SELECT event_id,valid_from FROM $tombstoneTable WHERE fragment_key=? AND epoch=? '
                'AND event_id IN (${List.filled(page.ids.length, '?').join(',')})',
                [key, epoch, ...page.ids]));
        final tombstones = {
          for (final row in deleted) row['event_id']: row['valid_from']
        };
        rows = [
          for (var i = 0; i < page.ids.length; i++)
            {
              'seq': page.start + (newer ? -i : i),
              'event_id': page.ids[i],
              'valid_from': 0,
              'valid_to': tombstones[page.ids[i]],
            }
        ];
        if (!newer && !page.hasMore && rows.length < remaining) {
          // A revision-invisible boundary advances across the reserved gap.
          // It is ordering metadata, never a fabricated event or empty history.
          rows.add({
            'seq': legacyBoundary - 1,
            'event_id': '',
            'valid_from': 1 << 60,
            'valid_to': null
          });
        }
      } else {
        rows = await _gate(() => sql.rawQuery(
                'SELECT seq,event_id,valid_from,valid_to FROM $idTable '
                'WHERE fragment_key=? AND epoch=? AND seq$comparison? AND seq<=? AND seq>=? '
                'AND ${part == 0 ? 'seq<0' : 'seq>=?'} ORDER BY seq $order LIMIT ?',
                [
                  key,
                  epoch,
                  cursor,
                  tail,
                  head,
                  if (part == 2) legacyBoundary,
                  remaining
                ]));
      }
      result.addAll(rows);
    }
    return result;
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
    var batchLimit = 256;
    while (!_closed) {
      final releaseLease =
          await acquireMaintenanceLease?.call(_closedSignal.future);
      try {
        _check();
        final more = await _gate(() async {
          if (_leases.any((lease) => lease.key == key)) return false;
          final elapsed = Stopwatch()..start();
          final state = await _state(key);
          if (state == null || state['migration_state'] != 'ready') {
            return false;
          }
          final epoch = state['current_epoch'];
          var rows = await sql.rawQuery(
              'SELECT epoch,seq FROM $idTable WHERE fragment_key=? AND epoch<? '
              'ORDER BY epoch,seq LIMIT $batchLimit',
              [key, epoch]);
          if (rows.isEmpty) {
            rows = await sql.rawQuery(
                'SELECT epoch,seq FROM $idTable WHERE fragment_key=? '
                'AND epoch=? AND valid_to IS NOT NULL ORDER BY seq LIMIT $batchLimit',
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
                'SELECT epoch FROM $epochTable WHERE fragment_key=? AND epoch<? ORDER BY epoch LIMIT $batchLimit',
                [key, epoch]);
            for (final row in rows) {
              batch.delete(epochTable,
                  where: 'fragment_key=? AND epoch=?',
                  whereArgs: [key, row['epoch']]);
            }
          }
          if (rows.isEmpty) {
            for (final table in [membershipTable, tombstoneTable, baseTable]) {
              final metadata = await sql.rawQuery(
                  'SELECT rowid FROM $table WHERE fragment_key=? AND epoch<=? LIMIT $batchLimit',
                  [key, epoch]);
              if (metadata.isEmpty) continue;
              for (final row in metadata) {
                batch
                    .delete(table, where: 'rowid=?', whereArgs: [row['rowid']]);
              }
              await batch.commit(noResult: true);
              if (elapsed.elapsedMicroseconds > 4000 && batchLimit > 1) {
                batchLimit = (batchLimit * 4000 ~/ elapsed.elapsedMicroseconds)
                    .clamp(1, batchLimit - 1);
              }
              return true;
            }
            return false;
          }
          await batch.commit(noResult: true);
          if (elapsed.elapsedMicroseconds > 4000 && batchLimit > 1) {
            batchLimit = (batchLimit * 4000 ~/ elapsed.elapsedMicroseconds)
                .clamp(1, batchLimit - 1);
          }
          return true;
        });
        if (!more) return;
      } finally {
        releaseLease?.call();
      }
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
    _membershipHints.clear();
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
    batch.delete(membershipTable);
    batch.delete(baseTable);
    batch.delete(tombstoneTable);
  }

  Future<void> close() async {
    _closed = true;
    if (!_closedSignal.isCompleted) _closedSignal.complete();
    for (final lease in _leases.toList()) {
      lease.dispose();
    }
    await Future.wait(
        [_foregroundPageTail, _foregroundMembershipTail, _optionalPreviewTail]);
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
  int baseCount = 0;
  final changed = <String, ({int seq, int count})?>{};
}

class _SqlSnapshot implements TimelineIdSnapshot {
  _SqlSnapshot(this.store, this.key, this.epoch, this.revision, this.tail,
      this.length, this.cursor, this.head, this.direction,
      {this.legacyCount, this.sourceIdentity});
  final TimelineIdStore store;
  final String key;
  final int epoch, revision, tail, head;
  final TimelineIdDirection direction;
  final int? legacyCount;
  final String? sourceIdentity;
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
    return (() async {
      if (_disposed) throw TimelineSnapshotDisposed();
      final newer = direction == TimelineIdDirection.newer;
      if (legacyCount != null &&
          sourceIdentity != await store._sourceIdentity(key)) {
        throw StateError('Legacy timeline source changed');
      }
      final rows = await store._snapshotRows(
          key, epoch, cursor, tail, head, limit, direction, legacyCount);
      store._check();
      if (_disposed) throw TimelineSnapshotDisposed();
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
    })();
  }

  @override
  Future<TimelineIdSnapshot> checkpoint() async {
    store._check();
    if (_disposed) throw TimelineSnapshotDisposed();
    final lease = _SqlSnapshot(
        store, key, epoch, revision, tail, length, cursor, head, direction,
        legacyCount: legacyCount, sourceIdentity: sourceIdentity);
    store._leases.add(lease);
    return lease;
  }

  @override
  Future<TimelineIdSnapshot> fork(
      {required String afterEventId,
      TimelineIdDirection direction = TimelineIdDirection.older}) async {
    store._check();
    if (_disposed) throw TimelineSnapshotDisposed();
    return (() async {
      if (_disposed) throw TimelineSnapshotDisposed();
      var rows = await store.sql.rawQuery(
          'SELECT seq FROM ${TimelineIdStore.idTable} '
          'WHERE fragment_key=? AND epoch=? AND event_id=? AND seq>=? AND seq<=? '
          'AND valid_from<=? AND (valid_to IS NULL OR valid_to>?) ORDER BY seq LIMIT 1',
          [key, epoch, afterEventId, head, tail, revision, revision]);
      if (legacyCount != null &&
          (rows.isEmpty ||
              (rows.single['seq'] as int) >= 0 &&
                  (rows.single['seq'] as int) < legacyCount!)) {
        if (sourceIdentity != await store._sourceIdentity(key)) {
          throw StateError('Legacy timeline source changed');
        }
        final cached = await store._gate(() => store.sql.query(
            TimelineIdStore.membershipTable,
            columns: ['seq'],
            where: 'fragment_key=? AND epoch=? AND event_id=?',
            whereArgs: [key, epoch, afterEventId]));
        final found = cached.isNotEmpty
            ? cached.single['seq'] as int?
            : (await store._legacyPage(key, sourceIdentity!,
                    findEventIds: [afterEventId]))
                .positions[afterEventId];
        final deleted = await store._gate(() => store.sql.query(
            TimelineIdStore.tombstoneTable,
            where:
                'fragment_key=? AND epoch=? AND event_id=? AND valid_from<=?',
            whereArgs: [key, epoch, afterEventId, revision]));
        rows = found == null || deleted.isNotEmpty
            ? []
            : [
                {'seq': found}
              ];
      }
      store._check();
      if (_disposed) throw TimelineSnapshotDisposed();
      if (rows.isEmpty) throw const TimelineAnchorUnavailable();
      final lease = _SqlSnapshot(store, key, epoch, revision, tail, length,
          rows.single['seq'] as int, head, direction,
          legacyCount: legacyCount, sourceIdentity: sourceIdentity);
      store._leases.add(lease);
      return lease;
    })();
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
