import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';

/// 点钻页（demo 定稿改版）：
/// - 余额 hero：居中大字余额 + 副说明（无操作按钮——充值/提现入口不保留）；
/// - 最近 3 条点钻流水预览 + 本月收支汇总行；
/// - 右上角「全部账单」入口 → 全部账单页；底部「查看全部」同目标。
final class CaibiPage extends StatefulWidget {
  const CaibiPage({super.key, this.api, this.onOpenAllBills});
  final BusinessApiClient? api;

  /// 全部账单入口回调（宿主提供导航；缺省时隐藏右上角入口）。
  final VoidCallback? onOpenAllBills;
  @override
  State<CaibiPage> createState() => _CaibiPageState();
}

final class _CaibiPageState extends State<CaibiPage> {
  Future<Map<String, dynamic>>? balance;
  Future<Map<String, dynamic>>? recent;
  Future<Map<String, dynamic>>? monthly;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final api = widget.api;
    if (api == null) return;
    balance = api.caibiBalance();
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    recent = api.ledgerTransactions(limit: 3);
    monthly = api.ledgerTransactions(startAt: monthStart, limit: 100);
  }

  @override
  void didUpdateWidget(covariant CaibiPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final pageBg = dark
        ? WeChatColors.darkPageBackground
        : WeChatColors.lightPageBackground;
    return WeChatPageScaffold.navigation(
      backgroundColor: pageBg,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.navigationBackground(context),
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const Text('点钻'),
        trailing: widget.onOpenAllBills == null
            ? null
            : CupertinoButton(
                key: const Key('caibi-all-bills-entry'),
                padding: EdgeInsets.zero,
                onPressed: widget.onOpenAllBills,
                child: const Text('全部账单',
                    style: TextStyle(
                        fontSize: 14, color: WeChatColors.brandPrimary)),
              ),
      ),
      child: SafeArea(
        child: ListView(
          key: const Key('caibi-page'),
          padding: const EdgeInsets.all(12),
          children: [
            _balanceHero(context),
            const SizedBox(height: 12),
            _recentSection(context),
          ],
        ),
      ),
    );
  }

  Widget _balanceHero(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final card = dark ? WeChatColors.darkElevated : WeChatColors.lightElevated;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
        const Text('点钻余额',
            style:
                TextStyle(fontSize: 13, color: WeChatColors.textSecondary)),
        const SizedBox(height: 6),
        FutureBuilder<Map<String, dynamic>>(
          future: balance,
          builder: (_, snapshot) => Text.rich(
            TextSpan(children: [
              TextSpan(
                text: snapshot.hasError
                    ? '暂不可用'
                    : '${snapshot.data?['balance'] ?? '--'}',
                style: TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                  color: WeChatColors.resolveTextPrimary(context),
                ),
              ),
              const TextSpan(
                text: ' 点钻',
                style: TextStyle(
                    fontSize: 15, color: WeChatColors.textSecondary),
              ),
            ]),
            key: const Key('caibi-balance-value'),
          ),
        ),
        const SizedBox(height: 6),
        const Text('充值 · 红包 · 转账通用',
            style:
                TextStyle(fontSize: 12, color: WeChatColors.textTertiary)),
      ]),
    );
  }

  Widget _recentSection(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final card = dark ? WeChatColors.darkElevated : WeChatColors.lightElevated;
    return Container(
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        _monthlyHeader(),
        FutureBuilder<Map<String, dynamic>>(
          future: recent,
          builder: (_, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: CupertinoActivityIndicator(),
              );
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  const Text('流水加载失败',
                      style: TextStyle(
                          fontSize: 13, color: WeChatColors.textSecondary)),
                  CupertinoButton(
                    key: const Key('caibi-recent-retry'),
                    onPressed: () => setState(_refresh),
                    child: const Text('重试',
                        style: TextStyle(color: WeChatColors.brandPrimary)),
                  ),
                ]),
              );
            }
            final items = (snapshot.data?['items'] as List? ?? const []);
            if (items.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Text('暂无点钻流水',
                    style: TextStyle(
                        fontSize: 14, color: WeChatColors.textTertiary)),
              );
            }
            return Column(children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0)
                  Container(
                    height: .5,
                    margin: const EdgeInsets.only(left: 62),
                    color: WeChatColors.resolve(context, WeChatColors.divider),
                  ),
                _ledgerRow(items[i] as Map<String, dynamic>),
              ],
            ]);
          },
        ),
        CupertinoButton(
          key: const Key('caibi-view-all'),
          padding: const EdgeInsets.symmetric(vertical: 10),
          onPressed: widget.onOpenAllBills,
          child: const Text('查看全部 ›',
              style: TextStyle(
                  fontSize: 13, color: WeChatColors.brandPrimary)),
        ),
      ]),
    );
  }

  /// 本月收支汇总行（demo：本月支出 x · 收入 y）。
  Widget _monthlyHeader() {
    return FutureBuilder<Map<String, dynamic>>(
      future: monthly,
      builder: (_, snapshot) {
        var income = 0.0;
        var expense = 0.0;
        if (snapshot.hasData) {
          for (final entry in (snapshot.data?['items'] as List? ?? const [])) {
            final amount =
                double.tryParse('${(entry as Map)['amount'] ?? ''}') ?? 0;
            if (amount >= 0) {
              income += amount;
            } else {
              expense -= amount;
            }
          }
        }
        final summary = snapshot.hasData
            ? '本月支出 ${expense.toStringAsFixed(2)} · 收入 ${income.toStringAsFixed(2)}'
            : '';
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 13, 16, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('最近点钻流水',
                  style: TextStyle(
                      fontSize: 13, color: WeChatColors.textSecondary)),
              if (summary.isNotEmpty)
                Text(summary,
                    key: const Key('caibi-monthly-summary'),
                    style: const TextStyle(
                        fontSize: 13, color: WeChatColors.textSecondary)),
            ],
          ),
        );
      },
    );
  }

  Widget _ledgerRow(Map<String, dynamic> item) {
    final kind = '${item['kind'] ?? ''}';
    final amount = double.tryParse('${item['amount'] ?? ''}') ?? 0;
    final (icon, iconBg, title) = switch (kind) {
      'redpacket' => (
          CupertinoIcons.gift_fill,
          const Color(0xFFFA5151),
          '红包'
        ),
      'transfer' => (
          CupertinoIcons.arrow_left_right,
          WeChatColors.brandPrimary,
          '转账'
        ),
      'deposit' => (
          CupertinoIcons.arrow_up,
          const Color(0xFFFA9D3B),
          '充值'
        ),
      'withdrawal' => (
          CupertinoIcons.arrow_down,
          const Color(0xFF5F7BF7),
          '提现'
        ),
      _ => (
          CupertinoIcons.circle,
          WeChatColors.textTertiary,
          '其他'
        ),
    };
    final createdAt = DateTime.tryParse('${item['created_at'] ?? ''}');
    String two(int v) => v.toString().padLeft(2, '0');
    final timeText = createdAt == null
        ? ''
        : '${two(createdAt.month)}-${two(createdAt.day)} '
            '${two(createdAt.hour)}:${two(createdAt.minute)}';
    final description = '${item['description'] ?? ''}';
    return CupertinoButton(
      key: Key('caibi-recent-${item['id'] ?? title}'),
      padding: EdgeInsets.zero,
      onPressed: widget.onOpenAllBills,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
            child: Icon(icon, color: CupertinoColors.white, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 16)),
                if (timeText.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    description.isEmpty ? timeText : '$timeText · $description',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: WeChatColors.textTertiary),
                  ),
                ],
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${amount >= 0 ? '+' : ''}${amount.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: amount >= 0
                      ? WeChatColors.brandPrimary
                      : WeChatColors.resolveTextPrimary(context),
                ),
              ),
              Text(
                '${item['status'] ?? ''}',
                style: const TextStyle(
                    fontSize: 11, color: WeChatColors.textTertiary),
              ),
            ],
          ),
        ]),
      ),
    );
  }
}
