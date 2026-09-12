import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_gateway.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_pages.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_detail_controller.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_detail_sheet.dart';
import 'package:liuhetong_mobile/ui/components/wechat_scaffold.dart';

void main() {
  testWidgets(
      'receiver receipt is a scrollable full page with the authoritative role label',
      (tester) async {
    final api = await _api((request) async {
      expect(request.url.path, '/api/v1/chat-transfers/transfer-1');
      return http.Response(
          jsonEncode(_detail('ACCEPTED', billId: 'ledger-1')), 200,
          headers: const {'content-type': 'application/json'});
    });
    await tester.pumpWidget(CupertinoApp(
      home: ChatTransferDetailSheet(
        api: api,
        transferId: 'transfer-1',
        viewerId: 'receiver-1',
      ),
    ));
    await tester.pump();

    expect(find.byType(WeChatPageScaffold), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    expect(find.text('转账已收款'), findsOneWidget);
    expect(find.textContaining('200.00'), findsOneWidget);
    expect(find.text('转账时间'), findsOneWidget);
    expect(find.text('收款时间'), findsOneWidget);
    expect(find.text(_localTime('2026-09-11T10:20:00Z')), findsOneWidget);
    expect(find.text(_localTime('2026-09-11T10:21:00Z')), findsOneWidget);
    expect(find.text('账单详情'), findsOneWidget);
    expect(find.text('全部账单'), findsOneWidget);
    expect(find.byKey(const Key('chat-transfer-detail-accept')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'pending receiver action is single-flight and preserves success when refresh fails',
      (tester) async {
    final gateway = _DetailGateway()
      ..details.add(_detail('PENDING'))
      ..accepts.add(_detail('ACCEPTED'))
      ..details.add(StateError('refresh offline'))
      ..details.add(_detail('ACCEPTED', billId: 'bill-1'));
    await tester.pumpWidget(CupertinoApp(
      home: ChatTransferDetailSheet(
        gateway: gateway,
        transferId: 'transfer-1',
        viewerId: 'receiver-1',
      ),
    ));
    addTearDown(gateway.dispose);
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-transfer-detail-accept')));
    await tester.tap(find.byKey(const Key('chat-transfer-detail-accept')));
    await tester.pump();

    expect(gateway.acceptCalls, 1);
    expect(find.text('转账已收款'), findsOneWidget);
    expect(find.text('详情更新失败，请稍后重试'), findsOneWidget);
    expect(find.byKey(const Key('chat-transfer-detail-accept')), findsNothing);
    expect(find.byKey(const Key('chat-transfer-detail-refresh-retry')),
        findsOneWidget);

    await tester
        .tap(find.byKey(const Key('chat-transfer-detail-refresh-retry')));
    await tester.pump();
    expect(gateway.detailCalls, 3);
    expect(find.text('转账已收款'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'real bill id opens LedgerDetailPage and all bills starts a ledger list request',
      (tester) async {
    final gateway = _DetailGateway()
      ..details.add(_detail('ACCEPTED', billId: 'bill-1'));
    final ledger = _LedgerGateway();
    await tester.pumpWidget(CupertinoApp(
      home: ChatTransferDetailSheet(
        gateway: gateway,
        ledgerGateway: ledger,
        transferId: 'transfer-1',
        viewerId: 'receiver-1',
      ),
    ));
    addTearDown(() async {
      gateway.dispose();
      await ledger.dispose();
    });
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-transfer-detail-ledger')));
    await tester.pumpAndSettle();
    expect(find.byType(LedgerDetailPage), findsOneWidget);
    expect(ledger.detailIds, ['bill-1']);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const Key('chat-transfer-detail-all-bills')));
    await tester.tap(find.byKey(const Key('chat-transfer-detail-all-bills')));
    await tester.pumpAndSettle();
    expect(find.byType(LedgerListPage), findsOneWidget);
    expect(ledger.listCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'epoch change without invalidation blocks stale ledger navigation',
      (tester) async {
    final gateway = _DetailGateway()
      ..details.add(_detail('ACCEPTED', billId: 'bill-1'));
    final ledger = _LedgerGateway();
    await tester.pumpWidget(CupertinoApp(
      home: ChatTransferDetailSheet(
        gateway: gateway,
        ledgerGateway: ledger,
        transferId: 'transfer-1',
        viewerId: 'receiver-1',
      ),
    ));
    addTearDown(() async {
      gateway.dispose();
      await ledger.dispose();
    });
    await tester.pump();
    gateway.advanceEpoch();

    await tester.tap(find.byKey(const Key('chat-transfer-detail-ledger')));
    await tester.pump();
    expect(find.byType(LedgerDetailPage), findsNothing);
    expect(ledger.detailIds, isEmpty);
    expect(find.text('会话已结束，请重新打开转账详情'), findsOneWidget);
  });

  testWidgets('receipt has no overflow at 320px and 2x text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _DetailGateway()
      ..details
          .add({..._detail('ACCEPTED'), 'amount': '12345678901234567890.00'});
    await tester.pumpWidget(CupertinoApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: ChatTransferDetailSheet(
          gateway: gateway,
          transferId: 'transfer-1',
          viewerId: 'receiver-1',
        ),
      ),
    ));
    addTearDown(gateway.dispose);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

String _localTime(String iso) {
  final date = DateTime.parse(iso).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
}

Map<String, dynamic> _detail(String status, {String? billId}) => {
      'id': 'transfer-1',
      'sender_id': 'sender-1',
      'receiver_id': 'receiver-1',
      'status': status,
      'amount': '200.00',
      'note': '午饭',
      'created_at': '2026-09-11T10:20:00Z',
      'accepted_at': status == 'ACCEPTED' ? '2026-09-11T10:21:00Z' : null,
      if (billId != null) 'bill_id': billId,
    };

Future<BusinessApiClient> _api(
    Future<http.Response> Function(http.Request request) handler) async {
  final store = SecureSessionStore(_MemoryStore());
  await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.example'),
    sessionStore: store,
    client: MockClient(handler),
  );
}

final class _MemoryStore implements SecureKeyValueStore {
  final _values = <String, String>{};

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}

final class _DetailGateway implements ChatTransferDetailGateway {
  final details = <Object?>[];
  final accepts = <Object?>[];
  final declines = <Object?>[];
  final _invalidations = StreamController<void>.broadcast();
  var _epoch = 1;
  var detailCalls = 0;
  var acceptCalls = 0;

  @override
  int get sessionEpoch => _epoch;

  @override
  Stream<void> get sessionInvalidations => _invalidations.stream;

  void advanceEpoch() => _epoch++;

  @override
  Future<Map<String, dynamic>> accept(String transferId) =>
      _next(accepts, ++acceptCalls);

  @override
  Future<Map<String, dynamic>> decline(String transferId) => _next(declines, 0);

  @override
  Future<Map<String, dynamic>> detail(String transferId) =>
      _next(details, ++detailCalls);

  Future<Map<String, dynamic>> _next(List<Object?> source, int call) {
    if (source.isEmpty) return Future.error(StateError('missing result $call'));
    final result = source.removeAt(0);
    if (result is Map<String, dynamic>) return Future.value(result);
    if (result is Future<Map<String, dynamic>>) return result;
    return Future.error(result ?? StateError('missing result $call'));
  }

  void dispose() => _invalidations.close();
}

final class _LedgerGateway implements LedgerGateway {
  final _invalidations = StreamController<void>.broadcast();
  final detailIds = <String>[];
  var listCalls = 0;

  @override
  int get sessionEpoch => 1;

  @override
  Stream<void> get sessionInvalidations => _invalidations.stream;

  @override
  Future<Map<String, dynamic>> ledgerTransactionDetail(String transactionId) {
    detailIds.add(transactionId);
    return Future.value({
      'id': transactionId,
      'asset': 'CAIBI',
      'amount': '200.00',
      'kind': 'transfer',
      'status': 'ACCEPTED',
      'note': '午饭',
      'created_at': '2026-09-11T10:20:00Z',
      'accepted_at': '2026-09-11T10:21:00Z',
    });
  }

  @override
  Future<Map<String, dynamic>> listLedgerTransactions({
    String? kind,
    DateTime? startAt,
    DateTime? endAt,
    String? q,
    String? cursor,
    int limit = 50,
  }) {
    listCalls++;
    return Future.value(
        {'items': const <Map<String, dynamic>>[], 'next_cursor': null});
  }

  Future<void> dispose() => _invalidations.close();
}
