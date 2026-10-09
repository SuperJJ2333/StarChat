import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Transparent instrumentation seam; every operation executes on real SQLite.
class DelegatingSqliteDatabase implements Database {
  DelegatingSqliteDatabase(this.delegate);

  final Database delegate;

  @override
  Batch batch() => delegate.batch();

  @override
  Future<void> close() => delegate.close();

  @override
  Database get database => this;

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      delegate.delete(table, where: where, whereArgs: whereArgs);

  @override
  Future<T> devInvokeMethod<T>(String method, [Object? arguments]) {
    // ignore: deprecated_member_use
    return delegate.devInvokeMethod<T>(method, arguments);
  }

  @override
  Future<T> devInvokeSqlMethod<T>(String method, String sql,
      [List<Object?>? arguments]) {
    // ignore: deprecated_member_use
    return delegate.devInvokeSqlMethod<T>(method, sql, arguments);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      delegate.execute(sql, arguments);

  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);

  @override
  bool get isOpen => delegate.isOpen;

  @override
  String get path => delegate.path;

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
      delegate.query(table,
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
      delegate.queryCursor(table,
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
      delegate.rawDelete(sql, arguments);

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      delegate.rawInsert(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      delegate.rawQuery(sql, arguments);

  @override
  Future<QueryCursor> rawQueryCursor(String sql, List<Object?>? arguments,
          {int? bufferSize}) =>
      delegate.rawQueryCursor(sql, arguments, bufferSize: bufferSize);

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      delegate.rawUpdate(sql, arguments);

  @override
  Future<T> readTransaction<T>(Future<T> Function(Transaction txn) action) =>
      delegate.readTransaction(action);

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
          {bool? exclusive}) =>
      delegate.transaction(action, exclusive: exclusive);

  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
}
