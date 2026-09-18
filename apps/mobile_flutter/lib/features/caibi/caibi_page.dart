import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_gradient_divider.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../finance/wallet_entry_store.dart';

/// 点钻页（demo 定稿改版）：
/// - 余额 hero：居中大字余额 + 副说明（无操作按钮——充值/提现入口不保留）；
/// - 最近 3 条点钻流水预览 + 本月收支汇总行；
/// - 右上角「全部账单」入口 → 全部账单页；底部「查看全部」同目标。
///
/// 进入态（2026-09-18 修复）：三路请求合并为一份 [WalletEntryStore] 快照，
/// **缓存优先 + 后台刷新**。之前 `FutureBuilder` 每次进入都替换 future，失败
/// 就用「暂不可用」覆盖上一份好数据，于是余额/流水会闪一下再恢复。
/// 现在：有缓存时先用缓存渲染（不闪、不空转），刷新失败保留旧值；只有
/// [WalletEntryState.fatalError]（从未成功过且没有缓存）才显示错误与重试。
final class CaibiPage extends StatefulWidget {
  const CaibiPage({super.key, this.api, this.onOpenAllBills});
  final BusinessApiClient? api;

  /// 全部账单入口回调（宿主提供导航；缺省时隐藏右上角入口）。
  final VoidCallback? onOpenAllBills;
  @override
  State<CaibiPage> createState() => _CaibiPageState();
}

final class _CaibiPageState extends State<CaibiPage> {
  /// 共享进入态 Store（持有者是 WalletEntryStores）：页面只借用、只退订。
  WalletEntryStore? entry;
  bool _bootstrapping = false;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void didUpdateWidget(covariant CaibiPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) unawaited(_bootstrap());
  }

  @override
  void dispose() {
    entry?.view.removeListener(_onEntryState);
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final api = widget.api;
    entry?.view.removeListener(_onEntryState);
    entry = null;
    if (api == null || _bootstrapping) {
      if (mounted) setState(() {});
      return;
    }
    _bootstrapping = true;
    try {
      final scope = await api.walletIntentScope();
      // 点钻页与钱包页的快照结构不同，作用域必须分开，否则两个页面会共享
      // 同一个 Store 实例（注册表按 scope + epoch 复用）。
      final shared = WalletEntryStores.of(
          scope: '$scope#caibi', gateway: _CaibiEntryGateway(api));
      if (!mounted || !identical(widget.api, api)) return;
      entry = shared;
      shared.view.addListener(_onEntryState);
      // 有缓存立即返回（先渲染缓存），没有缓存时等待首次加载。
      await shared.enter();
    } catch (_) {
      // 作用域读取异常时保持空态；真正的加载失败由 fatalError 呈现。
    } finally {
      _bootstrapping = false;
      if (mounted) setState(() {});
    }
  }

  void _onEntryState() {
    if (mounted) setState(() {});
  }

  Future<void> _retry() async {
    final shared = entry;
    if (shared == null) {
      await _bootstrap();
      return;
    }
    await shared.refresh();
    if (mounted) setState(() {});
  }

  /// 快照里的余额文本；没有数据时按阶段给出占位（绝不编造数字）。
  String get _balanceText {
    final map = entry?.state.data;
    if (map != null) return '${map['balance'] ?? '--'}';
    return (entry?.state.fatalError ?? false) ? '暂不可用' : '--';
  }

  /// 行间分割线：复用仓库统一的渐隐分割线（§19），行高不变。
  Widget _rowDivider() => const Padding(
      padding: EdgeInsets.only(left: 62), child: WeChatGradientDivider());

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
    final state = entry?.state;
    final hasData = state?.hasData ?? false;
    final failed = state?.fatalError ?? false;
    // 只有「首次加载、还没有任何可展示数据」才显示加载圈：
    // 有缓存的后台刷新绝不给整页 spinner（缓存优先，不闪）。
    final firstLoad = !hasData && (state?.refreshing ?? false);
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
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: _balanceText,
              style: TextStyle(
                fontSize: 44,
                fontWeight: FontWeight.w700,
                height: 1.1,
                color: WeChatColors.resolveTextPrimary(context),
              ),
            ),
            const TextSpan(
              text: ' 点钻',
              style:
                  TextStyle(fontSize: 15, color: WeChatColors.textSecondary),
            ),
          ]),
          key: const Key('caibi-balance-value'),
        ),
        if (firstLoad) ...[
          const SizedBox(height: 10),
          const CupertinoActivityIndicator(radius: 8),
        ],
        const SizedBox(height: 6),
        const Text('充值 · 红包 · 转账通用',
            style: TextStyle(fontSize: 12, color: WeChatColors.textTertiary)),
        // 只有「从未成功过」的失败才提示 + 重试（有缓存时静默保留旧值）。
        if (failed && !firstLoad) ...[
          const SizedBox(height: 10),
          Text('余额加载失败，请重试',
              key: const Key('caibi-balance-error'),
              style: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.systemRed.resolveFrom(context))),
          CupertinoButton(
            key: const Key('caibi-balance-retry'),
            onPressed: () => unawaited(_retry()),
            child: const Text('重新加载',
                style: TextStyle(color: WeChatColors.brandPrimary)),
          ),
        ],
      ]),
    );
  }

  Widget _recentSection(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final card = dark ? WeChatColors.darkElevated : WeChatColors.lightElevated;
    final state = entry?.state;
    final data = state?.data;
    final items = (data?['recent'] as Map?)?['items'] as List? ?? const [];
    final recentFailed = data?['recent_failed'] == true;
    return Container(
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        _monthlyHeader(),
        if (data == null && state?.fatalError == true)
          _recentPlaceholder(
              key: 'caibi-recent-retry', label: '流水加载失败', retry: true)
        else if (data == null && (state?.refreshing ?? false))
          const Padding(
            padding: EdgeInsets.all(24),
            child: CupertinoActivityIndicator(),
          )
        else if (data == null)
          // 尚未进入（api 为空或本地作用域未就绪）：不显示常驻加载圈。
          const Padding(
            padding: EdgeInsets.all(32),
            child: Text('暂无点钻流水',
                style:
                    TextStyle(fontSize: 14, color: WeChatColors.textTertiary)),
          )
        else if (recentFailed && items.isEmpty)
          // 流水单独失败：只标记这一块，余额继续展示缓存/最新值。
          _recentPlaceholder(
              key: 'caibi-recent-retry', label: '流水加载失败', retry: true)
        else if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Text('暂无点钻流水',
                style:
                    TextStyle(fontSize: 14, color: WeChatColors.textTertiary)),
          )
        else
          Column(children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) _rowDivider(),
              _ledgerRow(items[i] as Map<String, dynamic>),
            ],
          ]),
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

  Widget _recentPlaceholder(
          {required String key,
          required String label,
          bool retry = false}) =>
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13, color: WeChatColors.textSecondary)),
          if (retry)
            CupertinoButton(
              key: Key(key),
              onPressed: () => unawaited(_retry()),
              child: const Text('重试',
                  style: TextStyle(color: WeChatColors.brandPrimary)),
            ),
        ]),
      );

  /// 本月收支汇总行（demo：本月支出 x · 收入 y）。
  Widget _monthlyHeader() {
    final monthly = entry?.state.data?['monthly'] as Map?;
    final items = (monthly?['items'] as List?) ?? const [];
    var income = 0.0;
    var expense = 0.0;
    for (final row in items) {
      final amount = double.tryParse('${(row as Map)['amount'] ?? ''}') ?? 0;
      if (amount >= 0) {
        income += amount;
      } else {
        expense -= amount;
      }
    }
    // 没有快照时不显示汇总（不编造 0）。
    final summary = monthly == null
        ? ''
        : '本月支出 ${expense.toStringAsFixed(2)} · 收入 ${income.toStringAsFixed(2)}';
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

/// 点钻页进入快照网关：余额 + 最近流水 + 本月汇总合并为一份快照。
///
/// 余额是权威读：失败即整份刷新失败（回退缓存，绝不显示半份数据）。流水与
/// 本月汇总各自失败时用 `recent_failed`/`monthly_failed` 单独标记，**不隐藏
/// 余额**，也不覆盖上一份好数据。
final class _CaibiEntryGateway implements WalletEntryGateway {
  _CaibiEntryGateway(this.api);

  final BusinessApiClient api;
  Map<String, dynamic>? _recent;
  Map<String, dynamic>? _monthly;

  @override
  int get sessionEpoch => api.sessionEpoch;

  @override
  Future<Map<String, dynamic>> load() async {
    final scope = await api.walletIntentScope();
    final balance = await api.caibiBalance();
    if (await api.walletIntentScope() != scope) {
      throw StateError('账户已切换，请重新打开点钻页');
    }
    final now = DateTime.now();
    var recentFailed = false;
    var monthlyFailed = false;
    _recent = await _keep(api.ledgerTransactions(limit: 3),
            onError: () => recentFailed = true) ??
        _recent;
    _monthly = await _keep(
            api.ledgerTransactions(
                startAt: DateTime(now.year, now.month, 1), limit: 100),
            onError: () => monthlyFailed = true) ??
        _monthly;
    return {
      'balance': balance['balance'],
      'recent': _recent ?? const <String, dynamic>{},
      'recent_failed': recentFailed,
      'monthly': _monthly ?? const <String, dynamic>{},
      'monthly_failed': monthlyFailed,
    };
  }

  Future<Map<String, dynamic>?> _keep(Future<Map<String, dynamic>> read,
      {required void Function() onError}) async {
    try {
      return await read;
    } catch (_) {
      onError();
      return null;
    }
  }
}
