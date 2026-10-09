import 'dart:async';
import 'dart:convert';
import 'package:matrix/src/database/database_api.dart';
import 'package:matrix/src/database/sqflite_box.dart';

/// Search ordering is independent of continuous chat fragments. Known timestamps
/// sort newest first; unknown timestamps form a stable final segment. Every
/// metadata change versions the row so captured readers cannot lose an anchor.
class RetainedSearchStore {
  RetainedSearchStore(this.collection, this.reader);
  final BoxCollection collection;
  final TimelineSearchMigrationReader? reader;
  bool get ownsTransaction => collection.timelineBatch != null;
  static const states = 'matrix_retained_search_state';
  static const rows = 'matrix_retained_search_rows';
  static const tuple = '(bucket,sort_ts,event_id,row_id)';
  final _preparing = <String, Future<void>>{};
  final _ready = <String>{};
  final _leases = <_SearchSnapshot>{};
  final _collecting = <String, Future<void>>{};
  final _roomGeneration = <String, int>{};
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

  int _generation = 0;
  void _check() {
    if (_closed) throw TimelineStorageClosed();
  }

  Future<T> _gate<T>(Future<T> Function() action) async {
    late T result;
    await collection.zoneTransaction(() async {
      _check();
      result = await action();
    });
    return result;
  }

  Future<void> open() async {
    final batch = collection.timelineDatabase.batch();
    batch.execute('CREATE TABLE IF NOT EXISTS $states '
        '(room_id TEXT PRIMARY KEY,revision INTEGER NOT NULL,item_count INTEGER NOT NULL,'
        'ready INTEGER NOT NULL,after_id TEXT,legacy_revision INTEGER)');
    batch.execute('CREATE TABLE IF NOT EXISTS $rows '
        '(row_id INTEGER PRIMARY KEY AUTOINCREMENT,room_id TEXT NOT NULL,event_id TEXT NOT NULL,'
        'bucket INTEGER NOT NULL,sort_ts INTEGER NOT NULL,valid_from INTEGER NOT NULL,'
        'valid_to INTEGER,deleted INTEGER NOT NULL)');
    batch.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS matrix_retained_search_active '
        'ON $rows(room_id,event_id) WHERE valid_to IS NULL');
    batch.execute('CREATE INDEX IF NOT EXISTS matrix_retained_search_order '
        'ON $rows(room_id,bucket,sort_ts,event_id,row_id)');
    batch.execute('CREATE INDEX IF NOT EXISTS matrix_retained_search_retired '
        'ON $rows(room_id,row_id) WHERE valid_to IS NOT NULL');
    batch
        .execute('CREATE INDEX IF NOT EXISTS matrix_retained_search_membership '
            'ON $rows(room_id,event_id,valid_from,valid_to)');
    batch.execute('CREATE INDEX IF NOT EXISTS matrix_retained_search_reconcile '
        'ON $rows(room_id,valid_from,row_id) '
        'WHERE valid_to IS NULL AND deleted=0');
    await batch.commit(noResult: true);
    final columns = await collection.timelineDatabase
        .rawQuery('PRAGMA table_info($states)');
    if (!columns.any((row) => row['name'] == 'legacy_revision')) {
      final migration = collection.timelineDatabase.batch();
      migration
          .execute('ALTER TABLE $states ADD COLUMN legacy_revision INTEGER');
      await migration.commit(noResult: true);
    }
  }

  Future<void> upsert(String room, TimelineSearchEntry entry,
      {bool deleted = false, bool migration = false}) async {
    _check();
    deleted = deleted || !entry.isSent;
    final batch = collection.timelineBatch;
    if (batch == null) {
      await collection.transaction(
          () => upsert(room, entry, deleted: deleted, migration: migration));
      return;
    }
    batch.rawInsert(
        'INSERT OR IGNORE INTO $states(room_id,revision,item_count,ready) VALUES (?,0,0,0)',
        [room]);
    final bucket = entry.originServerTs == null ? 1 : 0;
    final stamp = -(entry.originServerTs ?? 0), dead = deleted ? 1 : 0;
    // A stale backfill may only fill absent metadata or promote an unknown
    // timestamp. An explicit deletion tombstone always wins over backfill.
    final canReplace = migration
        ? 'deleted=0 AND (?=1 OR (bucket=1 AND ?=0))'
        : '(bucket!=? OR sort_ts!=? OR deleted!=?)';
    final replacementArgs =
        migration ? <Object?>[dead, bucket] : <Object?>[bucket, stamp, dead];
    batch.rawUpdate(
        'UPDATE $states SET revision=revision+1,item_count=item_count-'
        '(SELECT COUNT(*) FROM $rows WHERE room_id=? AND event_id=? AND valid_to IS NULL '
        'AND deleted=0 AND $canReplace) WHERE room_id=?',
        [room, entry.eventId, ...replacementArgs, room]);
    batch.rawUpdate(
        'UPDATE $rows SET valid_to=(SELECT revision FROM $states WHERE room_id=?) '
        'WHERE room_id=? AND event_id=? AND valid_to IS NULL AND $canReplace',
        [room, room, entry.eventId, ...replacementArgs]);
    batch.rawInsert(
        'INSERT INTO $rows(room_id,event_id,bucket,sort_ts,valid_from,deleted) '
        'SELECT room_id,?,?,?,revision,? FROM $states WHERE room_id=? AND NOT EXISTS '
        '(SELECT 1 FROM $rows WHERE room_id=? AND event_id=? AND valid_to IS NULL)',
        [entry.eventId, bucket, stamp, dead, room, room, entry.eventId]);
    batch.rawUpdate(
        'UPDATE $states SET item_count=item_count+changes()*? WHERE room_id=?',
        [deleted ? 0 : 1, room]);
  }

  Future<void> remove(String room, String id) =>
      upsert(room, TimelineSearchEntry(id, null), deleted: true);
  Future<void> prepare(
      String room, Future<TimelineIdSnapshot> Function() current,
      {Stream<List<String>> Function()? legacy}) {
    _check();
    _reportMaintenanceFailure();
    if (_ready.contains(room)) return Future.value();
    if (collection.timelineBatch != null) {
      throw StateError(
          'Retained search requires preflight outside transaction');
    }
    return _preparing.putIfAbsent(
        room,
        () => _prepare(room, current, legacy).whenComplete(() {
              unawaited(_preparing.remove(room));
            }));
  }

  Future<void> _prepare(
      String room,
      Future<TimelineIdSnapshot> Function() current,
      Stream<List<String>> Function()? legacy) async {
    final generation = _generation, roomGeneration = _roomGeneration[room] ?? 0;
    void check() {
      _check();
      if (generation != _generation ||
          roomGeneration != (_roomGeneration[room] ?? 0)) {
        throw StateError('Search preparation invalidated');
      }
    }

    final initial = await _gate(() async => collection.timelineDatabase
        .query(states, where: 'room_id=?', whereArgs: [room]));
    if (initial.isNotEmpty && initial.single['ready'] == 1) {
      _ready.add(room);
      return;
    }
    final legacyRevision =
        initial.isEmpty ? null : initial.single['legacy_revision'] as int?;
    if (legacyRevision != null) {
      // The rollback SDK owned writes while these rows were stale. Retire only
      // that captured generation, in bounded pages, keeping explicit deletion
      // tombstones and newer native writes. Rebuild from durable legacy/bodies.
      while (true) {
        check();
        final stale = await _gate(() => collection.timelineDatabase.rawQuery(
            'SELECT row_id FROM $rows WHERE room_id=? AND valid_to IS NULL '
            'AND deleted=0 AND valid_from<=? '
            'ORDER BY valid_from,row_id LIMIT 256',
            [room, legacyRevision]));
        if (stale.isEmpty) break;
        await collection.transaction(() async {
          check();
          final batch = collection.timelineBatch!;
          batch.rawUpdate(
              'UPDATE $states SET revision=revision+1 WHERE room_id=?', [room]);
          for (final row in stale) {
            batch.rawUpdate(
                'UPDATE $rows SET valid_to=(SELECT revision FROM $states WHERE room_id=?) '
                'WHERE row_id=? AND valid_to IS NULL AND deleted=0 AND valid_from<=?',
                [room, row['row_id'], legacyRevision]);
            batch.rawUpdate(
                'UPDATE $states SET item_count=item_count-changes() '
                'WHERE room_id=?',
                [room]);
          }
        });
        await Future<void>.delayed(Duration.zero);
      }
    }
    // Missing payloads remain represented and retryable. Body backfill below
    // covers all other retained epochs and independently recovered events.
    final seed = await current();
    seed.dispose();
    // Limited sync can replace an unmigrated fragment before first search.
    // Keep its missing-payload IDs retryable without making sync wait for the
    // whole legacy copy. Body backfill below enriches these placeholders.
    if (legacy != null) {
      await for (final page in legacy()) {
        check();
        await collection.transaction(() async {
          check();
          for (final id in page) {
            await upsert(room, TimelineSearchEntry(id, null), migration: true);
          }
        });
        await Future<void>.delayed(Duration.zero);
      }
    }
    // Archived epochs can contain temporarily unavailable payloads. Preserve
    // their IDs before allowing timeline metadata GC; deletion tombstones win.
    for (final fragment in ['$room|']) {
      int? epoch, seq;
      while (true) {
        check();
        final page = await _gate(() => collection.timelineDatabase.rawQuery(
                'SELECT epoch,seq,event_id FROM matrix_timeline_fragment_ids WHERE fragment_key=? '
                'AND epoch >= (SELECT legacy_epoch_floor FROM matrix_timeline_fragment_state WHERE fragment_key=?) '
                '${epoch == null ? '' : 'AND (epoch,seq)>(?,?) '}ORDER BY epoch,seq LIMIT 256',
                [
                  fragment,
                  fragment,
                  if (epoch != null) ...[epoch, seq]
                ]));
        if (page.isEmpty) break;
        epoch = page.last['epoch'] as int;
        seq = page.last['seq'] as int;
        final epochs = page.map((row) => row['epoch'] as int).toSet().toList();
        final complete = await _gate(() => collection.timelineDatabase.rawQuery(
            'SELECT epoch FROM matrix_timeline_complete_epochs WHERE fragment_key=? '
            'AND epoch >= (SELECT legacy_epoch_floor FROM matrix_timeline_fragment_state WHERE fragment_key=?) '
            'AND epoch IN (${List.filled(epochs.length, '?').join(',')})',
            [fragment, fragment, ...epochs]));
        final eligible = complete.map((row) => row['epoch']).toSet();
        await collection.transaction(() async {
          check();
          for (final row in page) {
            if (eligible.contains(row['epoch'])) {
              await upsert(
                  room, TimelineSearchEntry(row['event_id'] as String, null),
                  migration: true);
            }
          }
        });
        await Future<void>.delayed(Duration.zero);
      }
    }
    final after =
        initial.isEmpty ? null : initial.single['after_id'] as String?;
    await for (final page
        in reader?.call(room, after) ?? _fallback(room, after)) {
      check();
      if (page.isEmpty || page.length > 256) {
        throw StateError('Invalid retained search page');
      }
      await collection.transaction(() async {
        check();
        for (final entry in page) {
          await upsert(room, entry, migration: true);
        }
        collection.timelineBatch!.rawUpdate(
            'UPDATE $states SET after_id=? WHERE room_id=?',
            [page.last.eventId, room]);
      });
      await Future<void>.delayed(Duration.zero);
    }
    await collection.transaction(() async {
      check();
      final batch = collection.timelineBatch!;
      batch.rawInsert(
          'INSERT OR IGNORE INTO $states(room_id,revision,item_count,ready) VALUES (?,0,0,0)',
          [room]);
      batch.rawUpdate(
          'UPDATE $states SET ready=1,legacy_revision=NULL WHERE room_id=?',
          [room]);
    });
    _ready.add(room);
  }

  /// Caller-supplied in-memory native fixtures retain bounded compatibility.
  /// Production injects a worker so event JSON is never transferred to UI.
  Stream<List<TimelineSearchEntry>> _fallback(
      String room, String? after) async* {
    final prefix = '$room|', end = '$room}';
    var cursor = after == null ? prefix : '$prefix$after';
    final last = await _gate(() => collection.timelineDatabase.rawQuery(
        'SELECT k FROM box_events WHERE k>=? AND k<? ORDER BY k DESC LIMIT 1',
        [prefix, end]));
    if (last.isEmpty) return;
    final fence = last.single['k'] as String;
    while (true) {
      final page = await _gate(() => collection.timelineDatabase.rawQuery(
          'SELECT k,v FROM box_events WHERE k>? AND k<=? ORDER BY k LIMIT 256',
          [cursor, fence]));
      if (page.isEmpty) return;
      cursor = page.last['k'] as String;
      yield page.map((r) {
        final body = jsonDecode(r['v'] as String) as Map;
        final status = body['status'] ??
            (body['unsigned']
                as Map?)?['com.famedly.famedlysdk.message_sending_status'];
        return TimelineSearchEntry(
            (r['k'] as String).substring(prefix.length),
            body['origin_server_ts'] is int
                ? body['origin_server_ts'] as int
                : null,
            isSent: status is! int || status >= 0);
      }).toList();
    }
  }

  Future<TimelineIdSnapshot> snapshot(String room) => _gate(() async {
        final state = (await collection.timelineDatabase
                .query(states, where: 'room_id=?', whereArgs: [room]))
            .single;
        Future<List<Object?>?> edge(String order) async {
          final found = await collection.timelineDatabase.rawQuery(
              'SELECT bucket,sort_ts,event_id,row_id FROM $rows '
              'WHERE room_id=? ORDER BY bucket $order,sort_ts $order,event_id $order,row_id $order LIMIT 1',
              [room]);
          return found.isEmpty ? null : _position(found.single);
        }

        final handle = _SearchSnapshot(
            this,
            room,
            state['revision'] as int,
            state['item_count'] as int,
            await edge('ASC'),
            await edge('DESC'),
            null,
            0,
            TimelineIdDirection.older);
        _leases.add(handle);
        return handle;
      });
  void scheduleGarbage(String room) {
    if (_closed || !_ready.contains(room)) return;
    final task = _collecting.putIfAbsent(
        room,
        () => _collect(room).whenComplete(() {
              unawaited(_collecting.remove(room));
            }));
    unawaited(_observeMaintenance(task));
  }

  Future<void> _collect(String room) async {
    while (!_closed) {
      final more = await _gate(() async {
        if (_leases.any((lease) => lease.room == room)) return false;
        final retired = await collection.timelineDatabase.rawQuery(
            'SELECT row_id FROM $rows '
            'WHERE room_id=? AND valid_to IS NOT NULL ORDER BY row_id LIMIT 256',
            [room]);
        if (retired.isEmpty) return false;
        final batch = collection.timelineDatabase.batch();
        for (final row in retired) {
          batch.delete(rows, where: 'row_id=?', whereArgs: [row['row_id']]);
        }
        await batch.commit(noResult: true);
        return true;
      });
      if (!more) return;
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> clear({String? room}) async {
    if (room == null) {
      _generation++;
      _ready.clear();
    } else {
      _roomGeneration[room] = (_roomGeneration[room] ?? 0) + 1;
      _ready.remove(room);
    }
    for (final lease in _leases.toList()) {
      if (room == null || lease.room == room) lease.dispose();
    }
    final batch = collection.timelineBatch;
    if (batch == null) {
      await collection.transaction(() => clear(room: room));
      return;
    }
    batch.delete(rows,
        where: room == null ? null : 'room_id=?',
        whereArgs: room == null ? null : [room]);
    batch.delete(states,
        where: room == null ? null : 'room_id=?',
        whereArgs: room == null ? null : [room]);
    if (room != null) {
      batch.insert(states,
          {'room_id': room, 'revision': 0, 'item_count': 0, 'ready': 1});
    }
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

List<Object?> _position(Map<String, Object?> row) =>
    [row['bucket'], row['sort_ts'], row['event_id'], row['row_id']];

class _SearchSnapshot implements TimelineIdSnapshot {
  _SearchSnapshot(this.store, this.room, this.revision, this.length, this.first,
      this.last, this.after, this.cursor, this.direction);
  final RetainedSearchStore store;
  final String room;
  final int revision;
  @override
  final int length;
  final List<Object?>? first, last;
  final TimelineIdDirection direction;
  List<Object?>? after, _pendingAfter;
  int cursor;
  TimelineIdPage? _pending;
  bool _disposed = false;
  void _check() {
    store._check();
    if (_disposed) throw TimelineSnapshotDisposed();
  }

  @override
  Future<TimelineIdPage> next({int limit = 30}) async {
    _check();
    if (limit < 1 || limit > 256) throw RangeError.range(limit, 1, 256);
    if (_pending != null) return _pending!;
    return store._gate(() async {
      _check();
      if (first == null) {
        return _pending =
            TimelineIdPage(const [], hasMore: false, cursor: cursor);
      }
      final newer = direction == TimelineIdDirection.newer,
          order = newer ? 'DESC' : 'ASC';
      final page = await store.collection.timelineDatabase.rawQuery(
          'SELECT * FROM ${RetainedSearchStore.rows} '
          'WHERE room_id=? AND ${RetainedSearchStore.tuple}>=(?,?,?,?) AND ${RetainedSearchStore.tuple}<=(?,?,?,?) '
          '${after == null ? '' : 'AND ${RetainedSearchStore.tuple}${newer ? '<' : '>'}(?,?,?,?) '} '
          'ORDER BY bucket $order,sort_ts $order,event_id $order,row_id $order LIMIT ?',
          [room, ...first!, ...last!, if (after != null) ...after!, limit]);
      _pendingAfter =
          page.isEmpty ? (newer ? first : last) : _position(page.last);
      final bound = newer ? first! : last!;
      final atEnd = _pendingAfter!.last == bound.last;
      final visible = page.where((r) =>
          (r['valid_from'] as int) <= revision &&
          (r['valid_to'] == null || (r['valid_to'] as int) > revision) &&
          r['deleted'] == 0);
      return _pending = TimelineIdPage(
          List.unmodifiable(visible.map((r) => r['event_id'] as String)),
          hasMore: page.length == limit && !atEnd,
          cursor: cursor + page.length,
          rawCount: page.length);
    });
  }

  @override
  void accept(TimelineIdPage page) {
    _check();
    if (!identical(page, _pending)) throw StateError('Invalid search page');
    after = _pendingAfter;
    cursor = page.cursor;
    _pending = null;
    _pendingAfter = null;
  }

  @override
  Future<TimelineIdSnapshot> checkpoint() async {
    _check();
    final handle = _SearchSnapshot(
        store, room, revision, length, first, last, after, cursor, direction);
    store._leases.add(handle);
    return handle;
  }

  @override
  Future<TimelineIdSnapshot> fork(
          {required String afterEventId,
          TimelineIdDirection direction = TimelineIdDirection.older}) =>
      store._gate(() async {
        _check();
        final found = await store.collection.timelineDatabase.rawQuery(
            'SELECT * FROM ${RetainedSearchStore.rows} '
            'WHERE room_id=? AND event_id=? AND valid_from<=? AND (valid_to IS NULL OR valid_to>?) AND deleted=0 LIMIT 1',
            [room, afterEventId, revision, revision]);
        if (found.isEmpty) throw const TimelineAnchorUnavailable();
        final handle = _SearchSnapshot(store, room, revision, length, first,
            last, _position(found.single), 0, direction);
        store._leases.add(handle);
        return handle;
      });
  @override
  void dispose() {
    _disposed = true;
    _pending = null;
    store._leases.remove(this);
    store.scheduleGarbage(room);
  }
}
