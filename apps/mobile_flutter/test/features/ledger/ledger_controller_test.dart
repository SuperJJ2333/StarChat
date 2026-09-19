import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_controller.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_gateway.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_page_snapshot_store.dart';

final class FakeLedgerGateway implements LedgerGateway {
  final pages = <Completer<Map<String, dynamic>>>[];
  final calls = <({
    String? kind,
    DateTime? startAt,
    DateTime? endAt,
    String? q,
    String? cursor
  })>[];
  final invalidations = StreamController<void>.broadcast();
  @override
  int sessionEpoch = 0;

  /// 当前账号作用域；置 null 表示作用域不可知（此时不落盘）。
  String? cacheScope = 'acct-A';
  @override
  Future<String> resolveCacheScope() async {
    final scope = cacheScope;
    if (scope == null) throw StateError('scope unknown');
    return scope;
  }

  @override
  Stream<void> get sessionInvalidations => invalidations.stream;
  @override
  Future<Map<String, dynamic>> listLedgerTransactions(
      {String? kind,
      DateTime? startAt,
      DateTime? endAt,
      String? q,
      String? cursor,
      int limit = 50}) {
    calls.add(
        (kind: kind, startAt: startAt, endAt: endAt, q: q, cursor: cursor));
    final c = Completer<Map<String, dynamic>>();
    pages.add(c);
    return c.future;
  }

  @override
  Future<Map<String, dynamic>> ledgerTransactionDetail(
          String transactionId) async =>
      {};
}

void main() {
  test('dispose ignores delayed list completion', () async {
    final gateway = FakeLedgerGateway();
    final controller = LedgerController(gateway);
    final future = controller.load(refresh: true);
    controller.dispose();
    gateway.pages.single.complete({'items': const [], 'next_cursor': null});
    await future;
  });
  test('session invalidation clears rows and rejects old response', () async {
    final gateway = FakeLedgerGateway();
    final controller = LedgerController(gateway);
    final first = controller.load(refresh: true);
    gateway.pages.single.complete({
      'items': [
        {'id': 'one'}
      ],
      'next_cursor': 'next'
    });
    await first;
    final old = controller.loadMore();
    expect(controller.items.map((row) => row['id']), ['one']);
    gateway.sessionEpoch++;
    gateway.invalidations.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(controller.items, isEmpty);
    expect(controller.sessionEnded, isTrue);
    expect(controller.loading, isFalse);
    gateway.pages.last.complete({
      'items': [
        {'id': 'stale'}
      ],
      'next_cursor': null
    });
    await old;
    expect(controller.items, isEmpty);
    await controller.load();
    expect(gateway.pages, hasLength(2));
    controller.dispose();
    await gateway.invalidations.close();
  });
  test('initial load and loadMore deduplicate and reject malformed pages',
      () async {
    final gateway = FakeLedgerGateway();
    final controller = LedgerController(gateway);
    final initial = controller.load();
    expect(gateway.pages, hasLength(1));
    gateway.pages[0].complete({
      'items': [
        {'id': 'one'}
      ],
      'next_cursor': 'next'
    });
    await initial;
    final more = controller.loadMore();
    controller.loadMore();
    expect(gateway.pages, hasLength(2));
    gateway.pages[1].complete({
      'items': [
        {'id': 'one'},
        {'id': 'two'}
      ],
      'next_cursor': null
    });
    await more;
    expect(controller.items.map((e) => e['id']), ['one', 'two']);
    await controller.loadMore();
    expect(gateway.pages, hasLength(2));
    final retry = controller.load();
    gateway.pages[2].complete({
      'items': [
        {'id': 'three'},
        {}
      ],
      'next_cursor': null
    });
    await retry;
    // 契约变更（2026-09-19，微信级加载模型）：解析失败的刷新**不再清空列表**。
    // 旧实现先 `_items.clear()` 再请求，失败后屏幕只剩错误；新契约要求失败保留
    // 上一次成功结果（只有「从未成功过且无任何数据」才允许 error）。
    expect(controller.items.map((e) => e['id']), ['one', 'two']);
    expect(controller.error, isNull);
    expect(controller.stale, isTrue);
    controller.dispose();
    await gateway.invalidations.close();
  });
  test(
      'epoch change during a request ends the session without an invalidation event',
      () async {
    final gateway = FakeLedgerGateway();
    final controller = LedgerController(gateway);
    final load = controller.load();
    gateway.sessionEpoch++;
    gateway.pages.single.complete({
      'items': [
        {'id': 'late'}
      ],
      'next_cursor': 'next'
    });
    await load;
    expect(controller.sessionEnded, isTrue);
    expect(controller.items, isEmpty);
    expect(controller.loading, isFalse);
    expect(controller.loadingMore, isFalse);
    controller.dispose();
    await gateway.invalidations.close();
  });
  test('filter changes cancel pending search and retain the new combination',
      () async {
    final gateway = FakeLedgerGateway();
    final controller = LedgerController(gateway);
    controller.search('old');
    controller.setKind('transfer');
    expect(gateway.calls, hasLength(1));
    expect(gateway.calls.single.kind, 'transfer');
    expect(gateway.calls.single.q, 'old');
    gateway.pages.single.complete({'items': const [], 'next_cursor': null});
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(gateway.calls, hasLength(1));
    controller.dispose();
    await gateway.invalidations.close();
  });
  test('date range rejects reverse bounds and retry clears an error', () async {
    final gateway = FakeLedgerGateway();
    final controller = LedgerController(gateway);
    final validStart = DateTime.utc(2026, 9, 10);
    final validEnd = DateTime.utc(2026, 9, 12);
    controller.setDateRange(validStart, validEnd);
    gateway.pages.single.complete({'items': const [], 'next_cursor': null});
    await Future<void>.delayed(Duration.zero);
    final later = DateTime.utc(2026, 9, 12),
        earlier = DateTime.utc(2026, 9, 11);
    controller.setDateRange(later, earlier);
    expect(controller.error, contains('开始'));
    expect(controller.startAt, validStart);
    expect(controller.endAt, validEnd);
    final load = controller.retry();
    expect(gateway.calls.last.startAt, validStart);
    expect(gateway.calls.last.endAt, validEnd);
    gateway.pages.last.completeError(StateError('offline'));
    await load;
    expect(controller.error, isNotNull);
    final retry = controller.retry();
    gateway.pages.last.complete({'items': const [], 'next_cursor': null});
    await retry;
    expect(controller.error, isNull);
    controller.dispose();
    await gateway.invalidations.close();
  });
  test('retrying a failed next page retains rows and clears the page error',
      () async {
    final gateway = FakeLedgerGateway();
    final controller = LedgerController(gateway);
    final first = controller.load();
    gateway.pages.single.complete({
      'items': [
        {'id': 'one'}
      ],
      'next_cursor': 'cursor-2'
    });
    await first;
    final more = controller.loadMore();
    gateway.pages.last.completeError(StateError('offline'));
    await more;
    expect(controller.items.map((row) => row['id']), ['one']);
    expect(controller.error, isNotNull);
    final retry = controller.retry();
    expect(gateway.calls.last.cursor, 'cursor-2');
    gateway.pages.last.complete({
      'items': [
        {'id': 'two'}
      ],
      'next_cursor': null
    });
    await retry;
    expect(controller.items.map((row) => row['id']), ['one', 'two']);
    expect(controller.error, isNull);
    expect(controller.loading, isFalse);
    expect(controller.loadingMore, isFalse);
    controller.dispose();
    await gateway.invalidations.close();
  });
  test('search after a flying next page clears flags and rejects the old page',
      () async {
    final gateway = FakeLedgerGateway();
    final controller = LedgerController(gateway);
    final first = controller.load();
    gateway.pages.single.complete({
      'items': [
        {'id': 'one'}
      ],
      'next_cursor': 'cursor-2'
    });
    await first;
    final more = controller.loadMore();
    expect(controller.loadingMore, isTrue);
    controller.search('new');
    controller.setKind('transfer');
    expect(controller.loading, isTrue);
    expect(controller.loadingMore, isFalse);
    gateway.pages[1].complete({
      'items': [
        {'id': 'stale'}
      ],
      'next_cursor': null
    });
    gateway.pages[2].complete({
      'items': [
        {'id': 'fresh'}
      ],
      'next_cursor': null
    });
    await more;
    await Future<void>.delayed(Duration.zero);
    expect(controller.items.map((row) => row['id']), ['fresh']);
    controller.dispose();
    await gateway.invalidations.close();
  });

  /// 微信级加载模型（2026-09-19）：「全部账单」必须先渲染上次结果、后台刷新、
  /// 失败不覆盖；原先每次进入都是空列表 + 一次请求，刷新前还会先清空。
  group('账单首页本地快照（本地优先 / 失败不覆盖）', () {
    LedgerPageSnapshot snapshotFor(String scope, List<String> ids,
            {String? cursor}) =>
        LedgerPageSnapshot(
          scope: scope,
          items: [
            for (final id in ids) {'id': id}
          ],
          nextCursor: cursor,
          savedAt: DateTime(2026, 9, 19, 8),
        );

    test('构造即有首页数据：首帧可渲染、不等待网络', () async {
      final gateway = FakeLedgerGateway();
      final snapshots = InMemoryLedgerPageSnapshotStore(
          snapshotFor('acct-A', ['cached-1', 'cached-2'], cursor: 'c2'));
      final controller =
          LedgerController(gateway, snapshots: snapshots);

      expect(controller.items.map((row) => row['id']), ['cached-1', 'cached-2']);
      expect(controller.nextCursor, 'c2');
      expect(controller.loading, isFalse);
      expect(controller.error, isNull);
      expect(gateway.pages, isEmpty, reason: '构造控制器不得发请求');

      controller.dispose();
      await gateway.invalidations.close();
    });

    test('刷新失败：本地快照数据保留、不设置 error（只留 stale）', () async {
      final gateway = FakeLedgerGateway();
      final snapshots = InMemoryLedgerPageSnapshotStore(
          snapshotFor('acct-A', ['cached-1']));
      final controller =
          LedgerController(gateway, snapshots: snapshots);

      final load = controller.load();
      // 持有本地快照时，刷新会先做一次作用域校验（异步），请求随后才发出。
      await Future<void>.delayed(Duration.zero);
      gateway.pages.single.completeError(StateError('offline'));
      await load;

      expect(controller.items.map((row) => row['id']), ['cached-1'],
          reason: '失败不得清空上一份好数据');
      expect(controller.error, isNull,
          reason: '有数据时的刷新失败不显示错误/重试条');
      expect(controller.stale, isTrue);
      controller.dispose();
      await gateway.invalidations.close();
    });

    test('刷新成功写入快照；带筛选的刷新不写入', () async {
      final gateway = FakeLedgerGateway();
      final snapshots = InMemoryLedgerPageSnapshotStore();
      final controller =
          LedgerController(gateway, snapshots: snapshots);

      final load = controller.load();
      await Future<void>.delayed(Duration.zero);
      gateway.pages.single.complete({
        'items': [
          {'id': 'fresh-1'}
        ],
        'next_cursor': 'c2'
      });
      await load;
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.read()?.items.map((row) => row['id']), ['fresh-1']);
      expect(snapshots.read()?.nextCursor, 'c2');
      expect(snapshots.read()?.scope, 'acct-A');

      // 带筛选：不落盘（避免把某个筛选条件的旧结果当成默认首页）。
      controller.setKind('transfer');
      await Future<void>.delayed(Duration.zero);
      gateway.pages.last.complete({
        'items': [
          {'id': 'filtered'}
        ],
        'next_cursor': null
      });
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.read()?.items.map((row) => row['id']), ['fresh-1']);
      controller.dispose();
      await gateway.invalidations.close();
    });

    test('账号切换：快照属于别的账号时丢弃，绝不跨账号展示', () async {
      final gateway = FakeLedgerGateway();
      final snapshots = InMemoryLedgerPageSnapshotStore(
          snapshotFor('acct-A', ['other-account-row']));
      final controller =
          LedgerController(gateway, snapshots: snapshots);
      expect(controller.items, hasLength(1));

      gateway.cacheScope = 'acct-B';
      final load = controller.load();
      await Future<void>.delayed(Duration.zero);
      expect(controller.items, isEmpty,
          reason: '作用域不一致时必须在请求期间就丢弃旧账号的账单');
      gateway.pages.single.complete({
        'items': [
          {'id': 'b-1'}
        ],
        'next_cursor': null
      });
      await load;
      await Future<void>.delayed(Duration.zero);
      expect(controller.items.map((row) => row['id']), ['b-1']);
      expect(snapshots.read()?.scope, 'acct-B');
      controller.dispose();
      await gateway.invalidations.close();
    });
  });
}
