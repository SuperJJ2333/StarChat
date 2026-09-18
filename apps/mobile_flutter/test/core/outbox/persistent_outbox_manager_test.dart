import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 持久化出站消息层：表结构、幂等键、状态迁移与启动恢复。
///
/// 全部使用注入的内存/SQLite 存储与固定时钟，不触网、不用 fakeAsync。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OutboxStatus 语义（产品词汇表）', () {
    test('五个状态与文案一一对应，网络问题绝不属于终局失败', () {
      expect(OutboxStatus.queued.label, '等待发送');
      expect(OutboxStatus.sending.label, '发送中');
      expect(OutboxStatus.waitingNetwork.label, '等待网络');
      expect(OutboxStatus.failed.label, '发送失败');
      expect(OutboxStatus.sent.label, '正常');

      expect(OutboxStatus.waitingNetwork.isAutoDispatchable, isTrue);
      expect(OutboxStatus.queued.isAutoDispatchable, isTrue);
      expect(OutboxStatus.failed.isAutoDispatchable, isFalse,
          reason: '服务端明确拒绝只能手动重试，绝不自动重发');
      expect(OutboxStatus.sent.isSettled, isTrue);
    });

    test('未知列值按 queued 读取（宁可重发也不静默丢失）', () {
      expect(OutboxStatusSemantics.fromWire('nonsense'), OutboxStatus.queued);
      expect(OutboxStatusSemantics.fromWire(null), OutboxStatus.queued);
      expect(OutboxStatusSemantics.fromWire('waitingNetwork'),
          OutboxStatus.waitingNetwork);
    });
  });

  group('PersistentOutboxManager（内存存储）', () {
    late PersistentOutboxManager manager;

    setUp(() {
      manager = PersistentOutboxManager(InMemoryOutboxStore(),
          accountId: 'matrix:@me:test');
    });

    test('save 先落盘：创建时生成一次 localId/txid，status=queued', () async {
      final row = await manager.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      expect(row, isNotNull);
      expect(row!.localId, isNotEmpty);
      expect(row.txid, isNotEmpty);
      expect(row.status, OutboxStatus.queued);
      expect(row.content, 'hello');
      expect(row.roomId, '!room:test');
      expect(row.accountId, 'matrix:@me:test');
      expect(await manager.queryPending(), hasLength(1));
    });

    test('同一 txid 二次 save 不产生第二行（幂等）', () async {
      final first = await manager.save(
          receiverId: '@peer:test', content: 'hello', txid: 'tx-1');
      final second = await manager.save(
          receiverId: '@peer:test', content: 'hello', txid: 'tx-1');

      expect(first!.localId, second!.localId);
      expect(await manager.unsent(), hasLength(1),
          reason: 'txid 是幂等键：同一事务 ID 只能有一行');
    });

    test('claim 是原子的：第二次认领失败，且等待网络的行可被重新认领', () async {
      final row = await manager.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      expect(await manager.claim(row!.localId), isTrue);
      expect(await manager.claim(row.localId), isFalse,
          reason: '行已在派发中，别的派发者不得再发一次');
      final sending = await manager.byLocalId(row.localId);
      expect(sending!.status, OutboxStatus.sending);
      expect(sending.retryCount, 1);

      await manager.updateStatus(
          row.localId, OutboxStatus.waitingNetwork,
          lastError: 'offline');
      expect(await manager.claim(row.localId), isTrue,
          reason: '网络失败后的行恢复时必须能再次认领（复用同一 txid）');
      expect((await manager.byLocalId(row.localId))!.txid, row.txid);
    });

    test('failed 的行不会被 queryPending 选中（不自动重发）', () async {
      final row = await manager.save(
          receiverId: '@peer:test', content: '被拒绝', roomId: '!room:test');
      await manager.updateStatus(row!.localId, OutboxStatus.failed,
          lastError: 'M_FORBIDDEN');

      expect(await manager.queryPending(), isEmpty);
      expect(await manager.unsent(), hasLength(1),
          reason: '失败行仍要保留，供用户手动重试');
    });

    test('complete/removeOrArchive：已送达的行从表里移除', () async {
      final row = await manager.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');
      await manager.removeOrArchive(row!.localId);

      expect(await manager.unsent(), isEmpty);
      expect(await manager.byLocalId(row.localId), isNull);
    });

    test('recoverOnStartup：派发中→等待发送，txid 保持不变', () async {
      final row = await manager.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');
      await manager.claim(row!.localId);
      expect((await manager.unsent()).single.status, OutboxStatus.sending);

      final recovered = await manager.recoverOnStartup();

      expect(recovered.single.status, OutboxStatus.queued);
      expect(recovered.single.txid, row.txid,
          reason: '重启恢复必须复用同一 txid，靠服务端幂等避免重复消息');
      expect(recovered.single.localId, row.localId);
    });

    test('bindRoomForReceiver：把该接收方所有没有房间号的行绑定到房间', () async {
      final a = await manager.save(receiverId: '@peer:test', content: 'a');
      final b = await manager.save(receiverId: '@peer:test', content: 'b');
      final other = await manager.save(receiverId: '@other:test', content: 'c');
      final sent = await manager.save(receiverId: '@peer:test', content: 'd');
      await manager.removeOrArchive(sent!.localId);

      final bound = await manager.bindRoomForReceiver('@peer:test', '!room:test');

      expect(bound, 2);
      expect((await manager.byLocalId(a!.localId))!.roomId, '!room:test');
      expect((await manager.byLocalId(b!.localId))!.roomId, '!room:test');
      expect((await manager.byLocalId(other!.localId))!.roomId, isNull,
          reason: '其他接收方的行不得被误绑');
    });

    test('账号命名空间隔离：查询只返回当前账号的行', () async {
      final other = PersistentOutboxManager(InMemoryOutboxStore(),
          accountId: 'matrix:@other:test');
      await other.save(receiverId: '@peer:test', content: '别人的消息');
      await manager.save(receiverId: '@peer:test', content: '我的消息');

      final mine = await manager.unsent();

      expect(mine, hasLength(1));
      expect(mine.single.content, '我的消息');
    });
  });

  group('SqliteOutboxStore：真实落盘与重启恢复', () {
    late String path;
    late SqliteOutboxStore store;

    setUp(() {
      sqfliteFfiInit();
      path = '${Directory.current.path}/../../docs/verification/artifacts/'
          '2026-09-18/outbox/outbox-${DateTime.now().microsecondsSinceEpoch}.db';
      store = SqliteOutboxStore(databasePath: path);
    });

    tearDown(() async {
      await store.close();
      await databaseFactoryFfi.deleteDatabase(path);
    });

    test('表结构与键：outbox_messages / 主键 local_id / 唯一索引 txid', () async {
      final manager = PersistentOutboxManager(store, accountId: 'me');
      await manager.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');

      final db = await databaseFactoryFfi.openDatabase(path);
      final master = await db.rawQuery(
          "SELECT name, type FROM sqlite_master WHERE tbl_name = 'outbox_messages' ORDER BY name");
      final names = <String>[
        for (final row in master) '${row['type']}:${row['name']}'
      ];
      expect(names, contains('table:outbox_messages'));
      expect(names, contains('index:outbox_messages_txid'));
      expect(names, contains('index:outbox_messages_pending'));
      expect(names, contains('index:outbox_messages_room'));

      final columns = await db.rawQuery('PRAGMA table_info(outbox_messages)');
      final columnNames = <String>[
        for (final row in columns) row['name']! as String
      ];
      expect(
          columnNames,
          containsAll(<String>[
            'local_id',
            'txid',
            'room_id',
            'receiver_id',
            'account_id',
            'content',
            'status',
            'retry_count',
            'created_at',
            'updated_at',
            'last_error',
          ]));

      final txidIndex = await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE name = 'outbox_messages_txid'");
      expect(txidIndex.single['sql'], contains('UNIQUE'));
      await db.close();
    });

    test('新进程（新 manager/新连接）仍能读到未送达行并复用 txid', () async {
      final first = PersistentOutboxManager(store, accountId: 'me');
      final row = await first.save(
          receiverId: '@peer:test', content: 'hello', roomId: '!room:test');
      await first.claim(row!.localId);
      await store.close();

      store = SqliteOutboxStore(databasePath: path);
      final restarted = PersistentOutboxManager(store, accountId: 'me');
      final report = await restarted.recoverOnStartup();

      expect(report, hasLength(1));
      expect(report.single.localId, row.localId);
      expect(report.single.txid, row.txid,
          reason: '跨进程恢复必须复用同一 txid（幂等键）');
      expect(report.single.status, OutboxStatus.queued);
      expect(report.single.content, 'hello');
    });

    test('updateStatus 的条件更新（认领）在 SQLite 上同样原子', () async {
      final manager = PersistentOutboxManager(store, accountId: 'me');
      final row = await manager.save(receiverId: '@peer', content: 'x');

      expect(await manager.claim(row!.localId), isTrue);
      expect(await manager.claim(row.localId), isFalse);
      expect((await manager.byLocalId(row.localId))!.retryCount, 1);
    });
  });
}
