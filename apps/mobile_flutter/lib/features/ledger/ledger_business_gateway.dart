import '../../core/business_api_client.dart';
import 'ledger_gateway.dart';

final class BusinessLedgerGateway implements LedgerGateway {
  BusinessLedgerGateway(this.api);
  final BusinessApiClient api;
  @override
  int get sessionEpoch => api.sessionEpoch;
  @override
  Stream<void> get sessionInvalidations => api.sessionInvalidations.map((_) {});
  @override
  Future<Map<String, dynamic>> listLedgerTransactions(
          {String? kind,
          DateTime? startAt,
          DateTime? endAt,
          String? q,
          String? cursor,
          int limit = 50}) =>
      api.ledgerTransactions(
          kind: kind,
          startAt: startAt,
          endAt: endAt,
          q: q,
          cursor: cursor,
          limit: limit);
  @override
  Future<Map<String, dynamic>> ledgerTransactionDetail(String transactionId) =>
      api.ledgerTransactionDetail(transactionId);
}
