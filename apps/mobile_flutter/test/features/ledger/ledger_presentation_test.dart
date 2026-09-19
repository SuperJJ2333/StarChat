import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_gateway.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_pages.dart';

Map<String, dynamic> _row(String id, DateTime createdAt) => {
      'id': id,
      'asset': 'CAIBI',
      'kind': 'redpacket',
      'amount': '12',
      'note': id,
      'created_at': createdAt.toUtc().toIso8601String(),
    };

final class _Call {
  const _Call(this.kind, this.startAt, this.endAt, this.q);
  final String? kind;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? q;
}

final class _Gateway implements LedgerGateway {
  final _invalidations = StreamController<void>.broadcast();
  @override
  Future<String> resolveCacheScope() async => 'test-account';
  final calls = <_Call>[];
  final _pending = <Completer<Map<String, dynamic>>>[];
  @override
  int sessionEpoch = 1;
  @override
  Stream<void> get sessionInvalidations => _invalidations.stream;
  @override
  Future<Map<String, dynamic>> listLedgerTransactions(
      {String? kind,
      DateTime? startAt,
      DateTime? endAt,
      String? q,
      String? cursor,
      int limit = 50}) {
    calls.add(_Call(kind, startAt, endAt, q));
    final result = Completer<Map<String, dynamic>>();
    _pending.add(result);
    return result.future;
  }

  void complete({List<Map<String, dynamic>> items = const []}) =>
      _pending.removeAt(0).complete({'items': items, 'next_cursor': null});

  @override
  Future<Map<String, dynamic>> ledgerTransactionDetail(String id) async =>
      throw UnimplementedError();
}

Future<void> _pump(WidgetTester tester, _Gateway gateway) async {
  await tester.pumpWidget(CupertinoApp(home: LedgerListPage(gateway: gateway)));
  gateway.complete();
  await tester.pump();
}

void main() {
  test('BUG-06 filter dates are rendered as calendar days, not timestamps', () {
    expect(formatLedgerFilterDate(DateTime(2026, 9, 7)), '2026-09-07');
    expect(formatLedgerDayLabel(DateTime(2026, 9, 7), now: DateTime(2026, 9, 7)),
        '今天');
    expect(formatLedgerDayLabel(DateTime(2026, 9, 6), now: DateTime(2026, 9, 7)),
        '昨天');
    expect(formatLedgerDayLabel(DateTime(2026, 8, 31), now: DateTime(2026, 9, 7)),
        '8月31日');
    expect(formatLedgerDayLabel(DateTime(2025, 12, 31), now: DateTime(2026, 9, 7)),
        '2025年12月31日');
  });

  testWidgets('BUG-06 an untouched ledger shows a plain empty state',
      (tester) async {
    final gateway = _Gateway();
    await _pump(tester, gateway);

    expect(find.byKey(const Key('ledger-empty')), findsOneWidget);
    expect(find.text('暂无账单'), findsOneWidget);
    // 没有筛选条件时不显示筛选摘要/重置入口。
    expect(find.byKey(const Key('ledger-filter-summary')), findsNothing);
    expect(find.byKey(const Key('ledger-filter-reset')), findsNothing);
  });

  testWidgets('BUG-06 a filtered empty result explains itself and can reset',
      (tester) async {
    final gateway = _Gateway();
    await _pump(tester, gateway);

    await tester.tap(find.byKey(const Key('ledger-kind-红包')));
    gateway.complete();
    await tester.pump();

    expect(find.byKey(const Key('ledger-empty-filtered')), findsOneWidget);
    expect(find.text('没有符合条件的账单'), findsOneWidget);
    expect(find.byKey(const Key('ledger-filter-summary')), findsOneWidget);
    expect(find.textContaining('已筛选：红包'), findsOneWidget);

    await tester.tap(find.text('清除筛选'));
    gateway.complete();
    await tester.pump();

    // 一次点击清空全部筛选，只发一次请求。
    expect(gateway.calls.last.kind, isNull);
    expect(gateway.calls.last.startAt, isNull);
    expect(gateway.calls.last.endAt, isNull);
    expect(gateway.calls.last.q, isNull);
    expect(find.byKey(const Key('ledger-empty')), findsOneWidget);
  });

  testWidgets('BUG-06 the selected end date renders as a calendar day',
      (tester) async {
    final gateway = _Gateway();
    await _pump(tester, gateway);

    await tester.tap(find.byKey(const Key('ledger-end-date')));
    await tester.pumpAndSettle();
    tester
        .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
        .onDateTimeChanged(DateTime(2026, 1, 15));
    await tester.tap(find.text('确定'));
    await tester.pump();
    gateway.complete();
    await tester.pump();

    expect(find.text('2026-01-15'), findsOneWidget);
    expect(find.textContaining('00:00:00'), findsNothing);
  });

  testWidgets('BUG-06 the list groups rows under readable day headers',
      (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(CupertinoApp(home: LedgerListPage(gateway: gateway)));
    gateway.complete(items: [
      _row('today-row', DateTime.now()),
      _row('today-row-2', DateTime.now()),
      _row('old-row', DateTime(2026, 1, 2, 10)),
    ]);
    await tester.pump();

    expect(find.byKey(const Key('ledger-day-今天')), findsOneWidget);
    expect(find.byKey(const Key('ledger-day-1月2日')), findsOneWidget);
    expect(find.byKey(const Key('ledger-row-today-row')), findsOneWidget);
    expect(find.byKey(const Key('ledger-row-old-row')), findsOneWidget);
  });
}
