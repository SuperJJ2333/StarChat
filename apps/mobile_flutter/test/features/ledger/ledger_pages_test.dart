import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_gateway.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_pages.dart';

void main() {
  test(
      'formats decimal strings without floating-point conversion or truncation',
      () {
    expect(formatLedgerAmount('9007199254740993'), '9007199254740993.00 点钻');
    expect(formatLedgerAmount('1.234'), '--');
  });

  test('maps technical reason codes to stable user-facing descriptions', () {
    expect(
        ledgerDisplayDescription({'reason_code': 'RED_PACKET_CREATE'}), '发出红包');
    expect(ledgerDisplayDescription({'reason_code': 'RED_PACKET_EXPIRED'}),
        '红包退回');
    expect(ledgerDisplayDescription({'reason_code': 'MANUAL_PAYOUT_CANCELLED'}),
        '提现退回');
    expect(ledgerDisplayDescription({'reason_code': 'INTERNAL_RECONCILIATION'}),
        '其他');
    expect(
        ledgerDisplayDescription(
            {'kind': 'transfer', 'note': '午饭分摊', 'reason_code': 'TRANSFER'}),
        '午饭分摊');
  });

  testWidgets(
      'filters, search and a cancelled date picker issue usable queries',
      (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    gateway.completeList(items: const []);
    await tester.pump();

    await tester.tap(find.byKey(const Key('ledger-kind-转账')));
    expect(gateway.listCalls.last.kind, 'transfer');
    gateway.completeList(items: const []);
    await tester.pump();

    await tester.enterText(find.byType(CupertinoSearchTextField), '红包');
    await tester.pump(const Duration(milliseconds: 301));
    expect(gateway.listCalls.last.q, '红包');
    gateway.completeList(items: const []);
    await tester.pump();

    final calls = gateway.listCalls.length;
    await tester.tap(find.byKey(const Key('ledger-start-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(gateway.listCalls.length, calls);
  });

  testWidgets('loads another page, opens its real detail and copies its id',
      (tester) async {
    final gateway = _Gateway();
    final copied = <String>[];
    Future<void> clipboardHandler(MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, clipboardHandler);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(_app(gateway));
    gateway.completeList(
      items: List.generate(20, (index) => _row('ledger-first-$index')),
      cursor: 'next',
    );
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pump();
    expect(gateway.listCalls.last.cursor, 'next');
    gateway.completeList(items: [_row('ledger-second')]);
    await tester.pump();

    await tester.tap(find.textContaining('ledger-second'));
    await tester.pump(const Duration(seconds: 1));
    expect(gateway.detailIds, ['ledger-second']);
    gateway.completeDetail(_row('ledger-second')
      ..addAll({
        'kind': 'transfer',
        'status': 'ACCEPTED',
        'transfer_created_at': '2026-09-11T01:02:03',
        'accepted_at': '2026-09-11T02:02:03',
        'transfer_amount': '10',
        'fee': '0.20',
      }));
    await tester.pumpAndSettle();
    expect(find.text('已收款'), findsOneWidget);
    expect(find.text('12.00 点钻'), findsOneWidget);
    expect(find.text('10.00 点钻'), findsOneWidget);
    expect(find.text('0.20 点钻'), findsOneWidget);
    expect(find.text('2026-09-11 01:02:03'), findsOneWidget);
    expect(find.text('2026-09-11 02:02:03'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('ledger-copy-id')));
    await tester.tap(find.byKey(const Key('ledger-copy-id')));
    await tester.pump();
    expect(copied, ['ledger-second']);
    expect(find.text('账单ID已复制'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ledger-all-bills')));
    await tester.pumpAndSettle();
    expect(find.text('全部账单'), findsOneWidget);
  });

  testWidgets(
      'first-page failure retries and a late detail response is ignored',
      (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    gateway.failList();
    await tester.pump();
    expect(find.text('账单加载失败，请重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(gateway.listCalls, hasLength(2));
    gateway.completeList(items: const []);
    await tester.pump();

    await tester.pumpWidget(CupertinoApp(
      home: LedgerDetailPage(gateway: gateway, transactionId: 'late-id'),
    ));
    gateway.emitInvalidation();
    await tester.pump();
    gateway.completeDetail(_row('late-id'));
    await tester.pump();
    expect(find.text('会话已结束，请重新打开账单'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets(
      'rejects a non-CAIBI detail before rendering money or copy controls',
      (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(CupertinoApp(
      home: LedgerDetailPage(gateway: gateway, transactionId: 'direct-id'),
    ));
    gateway.completeDetail({..._row('direct-id'), 'asset': 'USDT'});
    await tester.pump();
    expect(find.text('账单加载失败，请重试'), findsOneWidget);
    expect(find.byKey(const Key('ledger-copy-id')), findsNothing);
  });

  testWidgets('an epoch change without an event ends a failed detail request',
      (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(CupertinoApp(
      home: LedgerDetailPage(gateway: gateway, transactionId: 'old-epoch'),
    ));
    gateway.advanceEpoch();
    gateway.failDetail();
    await tester.pump();
    expect(find.text('会话已结束，请重新打开账单'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets(
      'keeps a large string amount within a 320-wide two-times text layout',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _Gateway();
    await tester.pumpWidget(CupertinoApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: LedgerListPage(gateway: gateway),
      ),
    ));
    gateway.completeList(items: [
      {..._row('large-id'), 'amount': '123456789012345678901234567890'}
    ]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reports a clipboard platform failure without altering the detail',
      (tester) async {
    final gateway = _Gateway();
    Future<void> clipboardFailure(MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        throw PlatformException(code: 'denied');
      }
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, clipboardFailure);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(CupertinoApp(
      home: LedgerDetailPage(gateway: gateway, transactionId: 'copy-failure'),
    ));
    gateway.completeDetail(_row('copy-failure'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ledger-copy-id')));
    await tester.pump();
    expect(find.text('无法复制账单ID'), findsOneWidget);
    expect(find.text('实际收支'), findsOneWidget);
  });

  testWidgets('direct detail opens all bills with a real list request',
      (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(CupertinoApp(
      home: LedgerDetailPage(gateway: gateway, transactionId: 'direct-all'),
    ));
    gateway.completeDetail({
      ..._row('direct-all'),
      'note': null,
      'reason_code': 'RED_PACKET_EXPIRED',
    });
    await tester.pump();
    expect(find.text('红包退回'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ledger-all-bills')));
    await tester.pump();
    expect(gateway.listCalls, hasLength(1));
    gateway.completeList(items: const []);
    await tester.pump();
    expect(find.byType(LedgerListPage), findsOneWidget);
  });

  testWidgets('session-ended direct detail cannot open a new ledger page',
      (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(CupertinoApp(
      home: LedgerDetailPage(gateway: gateway, transactionId: 'ended-all'),
    ));
    gateway.completeDetail(_row('ended-all'));
    await tester.pump();
    gateway.advanceEpoch();

    await tester.tap(find.byKey(const Key('ledger-all-bills')));
    await tester.pump();
    expect(gateway.listCalls, isEmpty);
    expect(find.byType(LedgerListPage), findsNothing);
    expect(find.text('会话已结束，请重新打开账单'), findsOneWidget);
  });

  testWidgets('confirmed end date reopens on the same inclusive calendar day',
      (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    gateway.completeList(items: const []);
    await tester.pump();

    await tester.tap(find.byKey(const Key('ledger-end-date')));
    await tester.pumpAndSettle();
    tester
        .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
        .onDateTimeChanged(DateTime(2026, 1, 15));
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(gateway.listCalls.last.endAt, DateTime(2026, 1, 16));
    gateway.completeList(items: const []);
    await tester.pump();

    await tester.tap(find.byKey(const Key('ledger-end-date')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
            .initialDateTime,
        DateTime(2026, 1, 15));
    final callsBeforeSecondConfirm = gateway.listCalls.length;
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(gateway.listCalls.last.endAt, DateTime(2026, 1, 16));
    if (gateway.listCalls.length > callsBeforeSecondConfirm) {
      gateway.completeList(items: const []);
      await tester.pump();
    }
  });
}

Widget _app(_Gateway gateway) => CupertinoApp(
      home: LedgerListPage(gateway: gateway),
    );

Map<String, dynamic> _row(String id) => {
      'id': id,
      'asset': 'CAIBI',
      'kind': 'redpacket',
      'amount': '12',
      'note': id,
      'created_at': '2026-09-11T01:02:03Z',
    };

final class _Call {
  const _Call(this.kind, this.startAt, this.endAt, this.q, this.cursor);
  final String? kind;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? q;
  final String? cursor;
}

final class _Gateway implements LedgerGateway {
  final _invalidations = StreamController<void>.broadcast();
  final listCalls = <_Call>[];
  final _lists = <Completer<Map<String, dynamic>>>[];
  final detailIds = <String>[];
  final _details = <Completer<Map<String, dynamic>>>[];
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
    listCalls.add(_Call(kind, startAt, endAt, q, cursor));
    final result = Completer<Map<String, dynamic>>();
    _lists.add(result);
    return result.future;
  }

  void completeList(
          {required List<Map<String, dynamic>> items, String? cursor}) =>
      _lists.removeAt(0).complete({'items': items, 'next_cursor': cursor});
  void failList() => _lists.removeAt(0).completeError(StateError('offline'));
  @override
  Future<Map<String, dynamic>> ledgerTransactionDetail(String transactionId) {
    detailIds.add(transactionId);
    final result = Completer<Map<String, dynamic>>();
    _details.add(result);
    return result.future;
  }

  void completeDetail(Map<String, dynamic> value) =>
      _details.removeAt(0).complete(value);
  void failDetail() =>
      _details.removeAt(0).completeError(StateError('expired'));
  void advanceEpoch() => sessionEpoch++;
  void emitInvalidation() => _invalidations.add(null);
}
