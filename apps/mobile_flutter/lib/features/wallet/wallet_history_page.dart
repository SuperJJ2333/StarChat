import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/wechat_empty_state.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../finance/wallet_entry_store.dart';
import '../ledger/ledger_pages.dart';
import 'wallet_read_cache.dart';

final class WalletHistoryPage extends StatefulWidget {
  const WalletHistoryPage(
      {super.key, required this.client, required this.scope});
  final BusinessApiClient client;
  final String scope;
  @override
  State<WalletHistoryPage> createState() => _WalletHistoryPageState();
}

final class _WalletHistoryPageState extends State<WalletHistoryPage> {
  late WalletEntryStore cache = walletReadCache(
      widget.client, widget.scope, 'history', widget.client.walletHistory);
  String filter = 'all';
  late int cacheEpoch;
  @override
  void initState() {
    super.initState();
    cacheEpoch = widget.client.sessionEpoch;
    unawaited(cache.enter(maxAge: const Duration(seconds: 30)));
  }

  @override
  void didUpdateWidget(covariant WalletHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope ||
        oldWidget.client != widget.client ||
        cacheEpoch != widget.client.sessionEpoch) {
      filter = 'all';
      cacheEpoch = widget.client.sessionEpoch;
      cache = walletReadCache(
          widget.client, widget.scope, 'history', widget.client.walletHistory);
      unawaited(cache.enter(maxAge: const Duration(seconds: 30)));
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          middle: const Text('钱包记录'),
          trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: cache.refresh,
              child: const Icon(CupertinoIcons.refresh))),
      child: SafeArea(
          child: ValueListenableBuilder<WalletEntryState>(
              valueListenable: cache.view,
              builder: (context, state, _) {
                final rows = (state.data?['items'] as List? ?? [])
                    .whereType<Map>()
                    .where((r) => filter == 'all' || r['kind'] == filter)
                    .toList();
                return Column(children: [
                  const Padding(
                      padding: EdgeInsets.only(top: WeChatSpacing.sm),
                      child: Text('最近 50 条记录 · 筛选仅限已加载内容',
                          style: TextStyle(
                              fontSize: 12, color: WeChatColors.textTertiary))),
                  Padding(
                      padding: const EdgeInsets.all(WeChatSpacing.md),
                      child: CupertinoSlidingSegmentedControl<String>(
                          groupValue: filter,
                          children: const {
                            'all': Text('全部'),
                            'deposit': Text('充值'),
                            'withdrawal': Text('提现')
                          },
                          onValueChanged: (value) {
                            if (value != null) setState(() => filter = value);
                          })),
                  if (state.refreshing && !state.hasData)
                    const CupertinoActivityIndicator(),
                  if (state.phase == WalletLoadPhase.cached ||
                      state.lastError != null)
                    CupertinoButton(
                        onPressed: cache.refresh,
                        child: Text(
                            state.hasData ? '显示上次记录 · 点此重试更新' : '记录加载失败 · 重试')),
                  Expanded(
                      child: ListView(children: [
                    if (rows.isEmpty &&
                        !state.refreshing &&
                        state.lastError == null)
                      const WeChatEmptyState(
                          icon: CupertinoIcons.doc_text,
                          title: '最近记录中暂无此类交易',
                          description: '充值和提现记录会显示在这里'),
                    for (final row in rows)
                      LedgerRecordRow(
                          recordId: '${row['id']}',
                          icon: row['kind'] == 'deposit'
                              ? CupertinoIcons.arrow_up
                              : CupertinoIcons.arrow_down,
                          iconBg: row['kind'] == 'deposit'
                              ? const Color(0xFFFA9D3B)
                              : const Color(0xFF5F7BF7),
                          title: row['kind'] == 'deposit' ? '充值' : '提现',
                          subtitle: formatLedgerShortTime(row['created_at']),
                          amount: '${row['amount'] ?? '—'} USDT',
                          status: walletHistoryStatus(row['status'])),
                  ])),
                ]);
              })));
}

String walletHistoryStatus(Object? value) => switch (value) {
      'CREDITED' => '已到账',
      'COMPLETED' || 'SETTLED' || 'CHAIN_CONFIRMED' => '已完成',
      'FAILED_COMPENSATED' => '失败已退回',
      'REQUESTED' || 'PENDING' => '待处理',
      'CLAIMED' ||
      'SUBMITTED' ||
      'APPROVED' ||
      'PROCESSING' ||
      'FINANCE_APPROVED' ||
      'ADMIN_APPROVED' ||
      'SUBMITTING' ||
      'PROVIDER_SUBMITTED' =>
        '处理中',
      'MANUAL_REVIEW' || 'REVIEW' => '待人工核验',
      'UNKNOWN' => '结果待核验',
      'REJECTED' => '已拒绝',
      'CANCELLED' => '已取消',
      'EXPIRED' => '已过期',
      _ => '待核验',
    };
