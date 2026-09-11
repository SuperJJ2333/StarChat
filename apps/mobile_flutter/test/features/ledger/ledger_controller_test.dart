import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_controller.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_gateway.dart';

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
    expect(controller.items, isEmpty);
    expect(controller.error, isNotNull);
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
}
