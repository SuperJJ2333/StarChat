import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'outbox_message.dart';

/// 出站消息的本地持久化接口（插入/更新/条件认领/查询/删除）。
///
/// 复用项目既有的 SQLite 通道（`sqflite_common_ffi` + `path_provider` 的
/// 应用支持目录，与 `MomentsPageStore` / `SqliteProfileStore` 同源），
/// **不引入任何新的数据库依赖**。
abstract interface class OutboxStore {
  /// 插入一行；`local_id` 或 `txid` 已存在时不产生第二行（幂等插入）。
  Future<void> insert(OutboxMessage message);

  /// 更新状态（发送中/等待网络/失败/已送达）。
  ///
  /// [from] 非空时做**条件更新**（认领语义）：只有当前状态在 [from] 里才会
  /// 写入，返回是否真的改到了行——这是"两个派发者只有一个能发出去"的原子闸门。
  Future<bool> updateStatus(
    String localId,
    OutboxStatus status, {
    String? lastError,
    int? retryCount,
    int? serverRetryCount,
    DateTime? nextServerRetryAt,
    bool clearNextServerRetryAt = false,
    int? expectedRetryCount,
    String? accountId,
    DateTime? dueAt,
    bool incrementRetry = false,
    DateTime? updatedAt,
    Set<OutboxStatus>? from,
    bool clearLastError = false,
  });

  /// 绑定房间号（仅当该行还没有房间号时生效）。
  Future<bool> bindRoom(String localId, String roomId, {DateTime? updatedAt});

  /// 把某个接收方所有"还没有房间号"的行绑定到 [roomId]；返回受影响行数。
  Future<int> bindRoomForReceiver(
    String receiverId,
    String roomId, {
    String? accountId,
    Iterable<String>? localIds,
    DateTime? updatedAt,
  });

  Future<OutboxMessage?> byLocalId(String localId);
  Future<OutboxMessage?> byTxid(String txid);

  /// 查询；[unsent] 为 true 时排除 `sent`；[statuses] 精确过滤状态集合。
  Future<List<OutboxMessage>> query({
    Set<OutboxStatus>? statuses,
    bool unsent = false,
    String? roomId,
    String? receiverId,
    String? accountId,
    int? limit,
  });

  Future<bool> delete(String localId);

  /// 清理已送达行（隐私：确认送达后不再保留正文副本）。
  Future<int> deleteSent({String? accountId});

  Future<void> clear({String? accountId});

  Future<void> close();
}

/// SQLite 实现：`chatflow_outbox_v1.db` / 表 `outbox_messages`。
///
/// 结构（键与索引见下方 [createTableStatements]）：
/// - 主键 `local_id`；
/// - **唯一索引 `txid`**：数据库层面保证"同一个事务 ID 只有一行"，
///   这是重复发送防护的最后一道闸门；
/// - 索引 `(account_id, status, created_at)` 供 pending 扫描；
/// - 索引 `(room_id, status, created_at)` 供进房间后的恢复扫描。
final class SqliteOutboxStore implements OutboxStore {
  SqliteOutboxStore({
    String? databasePath,
    DatabaseFactory? factory,
    Future<String> Function()? supportDirectory,
  })  : _databasePath = databasePath,
        _factory = factory ?? databaseFactoryFfi,
        _supportDirectory = supportDirectory ?? _defaultSupportDirectory;

  static const String databaseName = 'chatflow_outbox_v1.db';
  static const String table = 'outbox_messages';

  /// Android 上 `databaseFactoryFfi.getDatabasesPath()` 返回的目录不可写
  /// （SQLITE_CANTOPEN 14，Mi 6 实测），与既有 profile/moments 存储一致，
  /// 使用 path_provider 的应用支持目录。
  static Future<String> _defaultSupportDirectory() async =>
      (await getApplicationSupportDirectory()).path;

  /// 建表语句（测试可据此断言结构与键）。
  static const List<String> createTableStatements = <String>[
    'CREATE TABLE $table ('
        'local_id TEXT NOT NULL PRIMARY KEY, '
        'txid TEXT NOT NULL, '
        'room_id TEXT, '
        'receiver_id TEXT NOT NULL, '
        'account_id TEXT NOT NULL DEFAULT \'\', '
        'content TEXT NOT NULL, '
        'status TEXT NOT NULL, '
        'retry_count INTEGER NOT NULL DEFAULT 0, '
        'server_retry_count INTEGER NOT NULL DEFAULT 0, '
        'next_server_retry_at INTEGER, '
        'created_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'last_error TEXT)',
    'CREATE UNIQUE INDEX ${table}_txid ON $table (txid)',
    'CREATE INDEX ${table}_pending ON $table (account_id, status, created_at)',
    'CREATE INDEX ${table}_room ON $table (room_id, status, created_at)',
  ];

  final String? _databasePath;
  final DatabaseFactory _factory;
  final Future<String> Function() _supportDirectory;
  Database? _database;
  Future<Database>? _opening;

  Future<Database> _open() {
    final existing = _database;
    if (existing != null && existing.isOpen) {
      return Future<Database>.value(existing);
    }
    return _opening ??= _openDatabase().catchError((Object error) {
      _opening = null;
      throw error;
    });
  }

  Future<Database> _openDatabase() async {
    var path = _databasePath ?? '';
    if (path.isEmpty) {
      path = p.join(await _supportDirectory(), databaseName);
    }
    final database = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 2) {
            await db.execute(
                'ALTER TABLE $table ADD COLUMN server_retry_count INTEGER NOT NULL DEFAULT 0');
            await db.execute(
                'ALTER TABLE $table ADD COLUMN next_server_retry_at INTEGER');
          }
        },
        onCreate: (db, _) async {
          for (final statement in createTableStatements) {
            await db.execute(statement);
          }
        },
      ),
    );
    _database = database;
    return database;
  }

  @override
  Future<void> insert(OutboxMessage message) async {
    final db = await _open();
    await db.insert(
      table,
      message.toRow(),
      // local_id 或 txid 冲突都不产生第二行：调用方随后用 byTxid 读取权威行。
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  @override
  Future<bool> updateStatus(
    String localId,
    OutboxStatus status, {
    String? lastError,
    int? retryCount,
    int? serverRetryCount,
    DateTime? nextServerRetryAt,
    bool clearNextServerRetryAt = false,
    int? expectedRetryCount,
    String? accountId,
    DateTime? dueAt,
    bool incrementRetry = false,
    DateTime? updatedAt,
    Set<OutboxStatus>? from,
    bool clearLastError = false,
  }) async {
    final db = await _open();
    final values = <String, Object?>{
      'status': status.wireName,
      'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
      if (clearLastError) 'last_error': null,
      if (lastError != null) 'last_error': lastError,
      if (retryCount != null) 'retry_count': retryCount,
      if (serverRetryCount != null) 'server_retry_count': serverRetryCount,
      if (clearNextServerRetryAt) 'next_server_retry_at': null,
      if (nextServerRetryAt != null)
        'next_server_retry_at': nextServerRetryAt.millisecondsSinceEpoch,
    };
    final where = StringBuffer('local_id = ?');
    final args = <Object?>[localId];
    if (from != null && from.isNotEmpty) {
      where
          .write(' AND status IN (${List.filled(from.length, '?').join(',')})');
      args.addAll(from.map((status) => status.wireName));
    }
    if (accountId != null) {
      where.write(' AND account_id = ?');
      args.add(accountId);
    }
    if (expectedRetryCount != null) {
      where.write(' AND retry_count = ?');
      args.add(expectedRetryCount);
    }
    if (dueAt != null) {
      where.write(
          ' AND (next_server_retry_at IS NULL OR next_server_retry_at <= ?)');
      args.add(dueAt.millisecondsSinceEpoch);
    }
    final assignments = values.keys.map((key) => '$key = ?').toList();
    if (incrementRetry) assignments.add('retry_count = retry_count + 1');
    return await db.rawUpdate(
          'UPDATE $table SET ${assignments.join(', ')} WHERE $where',
          [...values.values, ...args],
        ) >
        0;
  }

  @override
  Future<bool> bindRoom(String localId, String roomId,
      {DateTime? updatedAt}) async {
    final db = await _open();
    return await db.update(
          table,
          <String, Object?>{
            'room_id': roomId,
            'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
          },
          where: 'local_id = ? AND (room_id IS NULL OR room_id = \'\')',
          whereArgs: <Object?>[localId],
        ) >
        0;
  }

  @override
  Future<int> bindRoomForReceiver(
    String receiverId,
    String roomId, {
    String? accountId,
    Iterable<String>? localIds,
    DateTime? updatedAt,
  }) async {
    final db = await _open();
    final where = StringBuffer(
        'receiver_id = ? AND (room_id IS NULL OR room_id = \'\') AND status != ?');
    final args = <Object?>[receiverId, OutboxStatus.sent.wireName];
    if (accountId != null) {
      where.write(' AND account_id = ?');
      args.add(accountId);
    }
    final ids = localIds?.toList() ?? const <String>[];
    if (ids.isNotEmpty) {
      where.write(
          ' AND local_id IN (${List.filled(ids.length, '?').join(',')})');
      args.addAll(ids);
    }
    return db.update(
      table,
      <String, Object?>{
        'room_id': roomId,
        'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
      },
      where: where.toString(),
      whereArgs: args,
    );
  }

  @override
  Future<OutboxMessage?> byLocalId(String localId) async {
    final rows = await (await _open()).query(table,
        where: 'local_id = ?', whereArgs: <Object?>[localId], limit: 1);
    return rows.isEmpty ? null : OutboxMessage.fromRow(rows.first);
  }

  @override
  Future<OutboxMessage?> byTxid(String txid) async {
    final rows = await (await _open())
        .query(table, where: 'txid = ?', whereArgs: <Object?>[txid], limit: 1);
    return rows.isEmpty ? null : OutboxMessage.fromRow(rows.first);
  }

  @override
  Future<List<OutboxMessage>> query({
    Set<OutboxStatus>? statuses,
    bool unsent = false,
    String? roomId,
    String? receiverId,
    String? accountId,
    int? limit,
  }) async {
    final where = StringBuffer('1 = 1');
    final args = <Object?>[];
    if (statuses != null && statuses.isNotEmpty) {
      where.write(
          ' AND status IN (${List.filled(statuses.length, '?').join(',')})');
      args.addAll(statuses.map((status) => status.wireName));
    }
    if (unsent) {
      where.write(' AND status != ?');
      args.add(OutboxStatus.sent.wireName);
    }
    if (roomId != null) {
      where.write(' AND room_id = ?');
      args.add(roomId);
    }
    if (receiverId != null) {
      where.write(' AND receiver_id = ?');
      args.add(receiverId);
    }
    if (accountId != null) {
      where.write(' AND account_id = ?');
      args.add(accountId);
    }
    final rows = await (await _open()).query(
      table,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'created_at ASC, local_id ASC',
      limit: limit,
    );
    return <OutboxMessage>[
      for (final row in rows) OutboxMessage.fromRow(row),
    ];
  }

  @override
  Future<bool> delete(String localId) async {
    final deleted = await (await _open())
        .delete(table, where: 'local_id = ?', whereArgs: <Object?>[localId]);
    return deleted > 0;
  }

  @override
  Future<int> deleteSent({String? accountId}) async {
    final where = StringBuffer('status = ?');
    final args = <Object?>[OutboxStatus.sent.wireName];
    if (accountId != null) {
      where.write(' AND account_id = ?');
      args.add(accountId);
    }
    return (await _open())
        .delete(table, where: where.toString(), whereArgs: args);
  }

  @override
  Future<void> clear({String? accountId}) async {
    if (accountId == null) {
      await (await _open()).delete(table);
      return;
    }
    await (await _open()).delete(table,
        where: 'account_id = ?', whereArgs: <Object?>[accountId]);
  }

  @override
  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    final database = _database;
    _database = null;
    if (opening != null) {
      try {
        await (await opening).close();
      } catch (_) {
        // 打不开的库不需要关闭。
      }
    } else if (database != null && database.isOpen) {
      await database.close();
    }
  }
}

/// 内存实现：测试与"SQLite 不可用"时的降级路径。
///
/// 语义与 [SqliteOutboxStore] 完全一致（包括 txid 唯一与条件更新），
/// 因此调度器/恢复服务的行为在两种实现下相同。
final class InMemoryOutboxStore implements OutboxStore {
  final Map<String, OutboxMessage> _rows = <String, OutboxMessage>{};

  int get length => _rows.length;

  @override
  Future<void> insert(OutboxMessage message) async {
    if (_rows.containsKey(message.localId)) return;
    if (_rows.values.any((row) => row.txid == message.txid)) return;
    _rows[message.localId] = message;
  }

  @override
  Future<bool> updateStatus(
    String localId,
    OutboxStatus status, {
    String? lastError,
    int? retryCount,
    int? serverRetryCount,
    DateTime? nextServerRetryAt,
    bool clearNextServerRetryAt = false,
    int? expectedRetryCount,
    String? accountId,
    DateTime? dueAt,
    bool incrementRetry = false,
    DateTime? updatedAt,
    Set<OutboxStatus>? from,
    bool clearLastError = false,
  }) async {
    final row = _rows[localId];
    if (row == null) return false;
    if (accountId != null && row.accountId != accountId) return false;
    if (expectedRetryCount != null && row.retryCount != expectedRetryCount) {
      return false;
    }
    if (dueAt != null &&
        row.nextServerRetryAt != null &&
        row.nextServerRetryAt!.isAfter(dueAt)) {
      return false;
    }
    if (from != null && from.isNotEmpty && !from.contains(row.status)) {
      return false;
    }
    _rows[localId] = row.copyWith(
      status: status,
      retryCount: incrementRetry ? row.retryCount + 1 : retryCount,
      serverRetryCount: serverRetryCount,
      nextServerRetryAt: nextServerRetryAt,
      clearNextServerRetryAt: clearNextServerRetryAt,
      updatedAt: updatedAt ?? DateTime.now(),
      lastError: lastError,
      clearLastError: clearLastError,
    );
    return true;
  }

  @override
  Future<bool> bindRoom(String localId, String roomId,
      {DateTime? updatedAt}) async {
    final row = _rows[localId];
    if (row == null || row.hasRoom) return false;
    _rows[localId] =
        row.copyWith(roomId: roomId, updatedAt: updatedAt ?? DateTime.now());
    return true;
  }

  @override
  Future<int> bindRoomForReceiver(
    String receiverId,
    String roomId, {
    String? accountId,
    Iterable<String>? localIds,
    DateTime? updatedAt,
  }) async {
    final ids = localIds?.toSet();
    var changed = 0;
    for (final entry in _rows.entries.toList()) {
      final row = entry.value;
      if (row.receiverId != receiverId) continue;
      if (row.hasRoom || row.status.isSettled) continue;
      if (accountId != null && row.accountId != accountId) continue;
      if (ids != null && !ids.contains(row.localId)) continue;
      _rows[entry.key] =
          row.copyWith(roomId: roomId, updatedAt: updatedAt ?? DateTime.now());
      changed++;
    }
    return changed;
  }

  @override
  Future<OutboxMessage?> byLocalId(String localId) async => _rows[localId];

  @override
  Future<OutboxMessage?> byTxid(String txid) async {
    for (final row in _rows.values) {
      if (row.txid == txid) return row;
    }
    return null;
  }

  @override
  Future<List<OutboxMessage>> query({
    Set<OutboxStatus>? statuses,
    bool unsent = false,
    String? roomId,
    String? receiverId,
    String? accountId,
    int? limit,
  }) async {
    final rows = <OutboxMessage>[
      for (final row in _rows.values)
        if ((statuses == null ||
                statuses.isEmpty ||
                statuses.contains(row.status)) &&
            (!unsent || !row.status.isSettled) &&
            (roomId == null || row.roomId == roomId) &&
            (receiverId == null || row.receiverId == receiverId) &&
            (accountId == null || row.accountId == accountId))
          row,
    ]..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        return byTime != 0 ? byTime : a.localId.compareTo(b.localId);
      });
    if (limit != null && rows.length > limit) return rows.sublist(0, limit);
    return rows;
  }

  @override
  Future<bool> delete(String localId) async => _rows.remove(localId) != null;

  @override
  Future<int> deleteSent({String? accountId}) async {
    final remove = <String>[
      for (final entry in _rows.entries)
        if (entry.value.status.isSettled &&
            (accountId == null || entry.value.accountId == accountId))
          entry.key,
    ];
    for (final id in remove) {
      _rows.remove(id);
    }
    return remove.length;
  }

  @override
  Future<void> clear({String? accountId}) async {
    if (accountId == null) {
      _rows.clear();
      return;
    }
    _rows.removeWhere((_, row) => row.accountId == accountId);
  }

  @override
  Future<void> close() async {}
}
