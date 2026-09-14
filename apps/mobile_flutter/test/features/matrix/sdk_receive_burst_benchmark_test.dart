import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _roomId = '!receive-burst:synthetic';
const _timelineTable = 'box_timeline_fragments';
const _eventsTable = 'box_events';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final historySize in [1500, 10000]) {
    test('SQLite timeline burst measures $historySize seeded events', () async {
      final evidenceRoot = Directory(
          '../../docs/verification/artifacts/2026-09-12/history-latency/receive-burst')
        ..createSync(recursive: true);
      final evidencePrefix =
          '${evidenceRoot.absolute.path}${Platform.pathSeparator}';
      final directory = await evidenceRoot.createTemp('sqlite-');
      expect(directory.absolute.path.startsWith(evidencePrefix), isTrue);
      final path = '${directory.path}${Platform.pathSeparator}matrix.sqlite';
      final raw = await databaseFactoryFfi.openDatabase(path);
      final counter = _TimelineFragmentWriteCounter();
      final database = MatrixSdkDatabase(path,
          database: _CountingDatabase(raw, counter),
          sqfliteFactory: databaseFactoryFfi);
      final client = Client('receive-burst-fixture');
      final room = Room(id: _roomId, client: client);
      final seedIds = List.generate(historySize, (index) => '\$seed-$index');
      final burstIds = List.generate(50, (index) => '\$burst-$index');
      var databaseClosed = false;
      try {
        await database.open();
        await _bulkSeed(raw, seedIds);
        counter.reset();

        var actionMicros = 0;
        final total = Stopwatch()..start();
        await database.transaction(() async {
          final action = Stopwatch()..start();
          for (var index = 0; index < burstIds.length; index++) {
            await database.storeEventUpdate(
                EventUpdate(
                    roomID: _roomId,
                    type: EventUpdateType.timeline,
                    content: _eventSource(burstIds[index],
                        '@sender-$index:synthetic', historySize + index + 1)),
                client);
          }
          action.stop();
          actionMicros = action.elapsedMicroseconds;
        });
        total.stop();

        final expectedIds = <String>[...burstIds.reversed, ...seedIds];
        final finalListBytes = utf8.encode(jsonEncode(expectedIds)).length;
        final events = await database.getEventList(room);
        expect(events.map((event) => event.eventId), expectedIds);
        expect(events.map((event) => event.eventId).toSet().length,
            expectedIds.length);
        expect(counter.timelineFragmentWrites, burstIds.length);
        expect(counter.serializedBytes, greaterThan(finalListBytes));

        final writesBeforeReplay = counter.timelineFragmentWrites;
        await database.transaction(() async {
          for (var index = 0; index < burstIds.length; index++) {
            await database.storeEventUpdate(
                EventUpdate(
                    roomID: _roomId,
                    type: EventUpdateType.timeline,
                    content: _eventSource(burstIds[index],
                        '@sender-$index:synthetic', historySize + index + 1)),
                client);
          }
        });
        expect(counter.timelineFragmentWrites, writesBeforeReplay);
        expect(
            (await database.getEventList(room)).map((event) => event.eventId),
            expectedIds);

        final measurement = <String, int>{
          'history_size': historySize,
          'burst_count': burstIds.length,
          'timeline_fragment_batch_inserts': counter.timelineFragmentWrites,
          'timeline_fragment_serialized_utf8_bytes': counter.serializedBytes,
          'final_timeline_serialized_utf8_bytes': finalListBytes,
          'instrumented_action_microseconds': actionMicros,
          'instrumented_commit_microseconds':
              total.elapsedMicroseconds - actionMicros,
          'instrumented_transaction_microseconds': total.elapsedMicroseconds,
        };
        debugPrint(jsonEncode(measurement));

        await database.close();
        databaseClosed = true;
        final reopened = MatrixSdkDatabase(path,
            database: await databaseFactoryFfi.openDatabase(path),
            sqfliteFactory: databaseFactoryFfi);
        await reopened.open();
        try {
          expect(
              (await reopened.getEventList(room)).map((event) => event.eventId),
              expectedIds);
        } finally {
          await reopened.close();
        }
      } finally {
        if (!databaseClosed) await database.close();
        await client.dispose();
        if (directory.absolute.path.startsWith(evidencePrefix) &&
            File(path).absolute.path.startsWith(evidencePrefix)) {
          await databaseFactoryFfi.deleteDatabase(path);
          await directory.delete();
        }
      }
    });
  }
}

Map<String, dynamic> _eventSource(String eventId, String sender, int order) => {
      'event_id': eventId,
      'type': EventTypes.Message,
      'sender': sender,
      'origin_server_ts': order + 1,
      'content': {'msgtype': 'm.text', 'body': 'synthetic'},
    };

Future<void> _bulkSeed(Database raw, List<String> eventIds) async {
  final batch = raw.batch();
  for (var index = 0; index < eventIds.length; index++) {
    final eventId = eventIds[index];
    batch.insert(
        _eventsTable,
        {
          'k': '$_roomId|$eventId',
          'v': jsonEncode(_eventSource(
              eventId, '@seed:synthetic', eventIds.length - index)),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
  batch.insert(
      _timelineTable,
      {
        'k': '$_roomId|',
        'v': jsonEncode(eventIds),
      },
      conflictAlgorithm: ConflictAlgorithm.replace);
  await batch.commit(noResult: true);
}

class _TimelineFragmentWriteCounter {
  int timelineFragmentWrites = 0;
  int serializedBytes = 0;

  void record(String table, Map<String, Object?> values) {
    if (table != _timelineTable) return;
    final value = values['v'];
    if (value is! String) return;
    timelineFragmentWrites++;
    serializedBytes += utf8.encode(value).length;
  }

  void reset() {
    timelineFragmentWrites = 0;
    serializedBytes = 0;
  }
}

class _CountingDatabase implements Database {
  _CountingDatabase(this._delegate, this._counter);

  final Database _delegate;
  final _TimelineFragmentWriteCounter _counter;

  @override
  Batch batch() => _CountingBatch(_delegate.batch(), _counter);

  @override
  Future<void> close() => _delegate.close();

  @override
  Database get database => this;

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _delegate.delete(table, where: where, whereArgs: whereArgs);

  @override
  Future<T> devInvokeMethod<T>(String method, [Object? arguments]) {
    // ignore: deprecated_member_use
    return _delegate.devInvokeMethod<T>(method, arguments);
  }

  @override
  Future<T> devInvokeSqlMethod<T>(String method, String sql,
      [List<Object?>? arguments]) {
    // ignore: deprecated_member_use
    return _delegate.devInvokeSqlMethod<T>(method, sql, arguments);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      _delegate.execute(sql, arguments);

  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      _delegate.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);

  @override
  bool get isOpen => _delegate.isOpen;

  @override
  String get path => _delegate.path;

  @override
  Future<List<Map<String, Object?>>> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      _delegate.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);

  @override
  Future<QueryCursor> queryCursor(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset,
          int? bufferSize}) =>
      _delegate.queryCursor(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset,
          bufferSize: bufferSize);

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _delegate.rawDelete(sql, arguments);

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      _delegate.rawInsert(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      _delegate.rawQuery(sql, arguments);

  @override
  Future<QueryCursor> rawQueryCursor(String sql, List<Object?>? arguments,
          {int? bufferSize}) =>
      _delegate.rawQueryCursor(sql, arguments, bufferSize: bufferSize);

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      _delegate.rawUpdate(sql, arguments);

  @override
  Future<T> readTransaction<T>(Future<T> Function(Transaction txn) action) =>
      _delegate.readTransaction(action);

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
          {bool? exclusive}) =>
      _delegate.transaction(action, exclusive: exclusive);

  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      _delegate.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
}

class _CountingBatch implements Batch {
  _CountingBatch(this._delegate, this._counter);

  final Batch _delegate;
  final _TimelineFragmentWriteCounter _counter;

  @override
  Future<List<Object?>> apply({bool? noResult, bool? continueOnError}) =>
      _delegate.apply(noResult: noResult, continueOnError: continueOnError);

  @override
  Future<List<Object?>> commit(
          {bool? exclusive, bool? noResult, bool? continueOnError}) =>
      _delegate.commit(
          exclusive: exclusive,
          noResult: noResult,
          continueOnError: continueOnError);

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _delegate.delete(table, where: where, whereArgs: whereArgs);

  @override
  void execute(String sql, [List<Object?>? arguments]) =>
      _delegate.execute(sql, arguments);

  @override
  void insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) {
    _counter.record(table, values);
    _delegate.insert(table, values,
        nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  }

  @override
  int get length => _delegate.length;

  @override
  void query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      _delegate.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);

  @override
  void rawDelete(String sql, [List<Object?>? arguments]) =>
      _delegate.rawDelete(sql, arguments);

  @override
  void rawInsert(String sql, [List<Object?>? arguments]) =>
      _delegate.rawInsert(sql, arguments);

  @override
  void rawQuery(String sql, [List<Object?>? arguments]) =>
      _delegate.rawQuery(sql, arguments);

  @override
  void rawUpdate(String sql, [List<Object?>? arguments]) =>
      _delegate.rawUpdate(sql, arguments);

  @override
  void update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      _delegate.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
}
