abstract interface class LedgerGateway {
  int get sessionEpoch;
  Stream<void> get sessionInvalidations;

  /// 本地缓存作用域（含账号主体）。账单快照只在该作用域匹配时使用/写入，
  /// 账号切换后立即失效，账单绝不跨账号展示。抛错表示作用域不可知（此时不落盘）。
  Future<String> resolveCacheScope();
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
