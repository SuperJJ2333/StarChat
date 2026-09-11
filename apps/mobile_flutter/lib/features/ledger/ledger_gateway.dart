abstract interface class LedgerGateway {
  int get sessionEpoch;
  Stream<void> get sessionInvalidations;
  Future<Map<String, dynamic>> listLedgerTransactions({
    String? kind,
    DateTime? startAt,
    DateTime? endAt,
    String? q,
    String? cursor,
    int limit = 50,
  });
  Future<Map<String, dynamic>> ledgerTransactionDetail(String transactionId);
}
