import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';

final class WalletPage extends StatefulWidget {
  const WalletPage({super.key, this.api});
  final BusinessApiClient? api;
  @override
  State<WalletPage> createState() => _WalletPageState();
}

final class _WalletPageState extends State<WalletPage> {
  final amount = TextEditingController();
  final address = TextEditingController();
  Future<Map<String, dynamic>>? balance;
  String? depositAddress;
  String? status;
  Timer? poller;
  String? withdrawalId;

  static final RegExp _trc20Pattern = RegExp(r'^T[1-9A-HJ-NP-Za-km-z]{33}$');
  static final RegExp _amountPattern = RegExp(r'^(0|[1-9]\d*)(\.\d{1,6})?$');

  @override
  void initState() {
    super.initState();
    final api = widget.api;
    if (api != null) balance = api.walletBalance();
  }

  @override
  void dispose() {
    poller?.cancel();
    amount.dispose();
    address.dispose();
    super.dispose();
  }

  String? _validateWithdrawal() {
    final text = amount.text.trim();
    if (text.isEmpty) return '请输入提现金额';
    if (!_amountPattern.hasMatch(text)) {
      return text.split('.').length > 1 && text.split('.').last.length > 6
          ? '提现金额最多支持六位小数'
          : '提现金额格式不正确';
    }
    if (double.tryParse(text)! <= 0) return '提现金额必须大于0';
    if (!_trc20Pattern.hasMatch(address.text.trim())) {
      return '请输入正确的 TRC20 收款地址';
    }
    return null;
  }

  Future<void> _loadDepositAddress() async {
    try {
      final body = await widget.api?.walletDepositAddress();
      if (mounted) setState(() => depositAddress = body?['address']?.toString());
    } catch (_) {
      if (mounted) setState(() => status = '充值地址获取失败，请稍后重试');
    }
  }

  Future<void> _copyAddress() async {
    if (depositAddress == null) return;
    await Clipboard.setData(ClipboardData(text: depositAddress!));
    if (mounted) setState(() => status = '充值地址已复制');
  }

  Future<void> withdraw() async {
    final error = _validateWithdrawal();
    if (error != null) {
      setState(() => status = error);
      return;
    }
    try {
      final r = await widget.api?.requestWithdrawal(
          amount: amount.text.trim(),
          address: address.text.trim(),
          clientOrderId: 'mobile-${DateTime.now().millisecondsSinceEpoch}',
          reasonCode: 'USER_WITHDRAWAL');
      withdrawalId = r?['id']?.toString();
      setState(() => status = '提现申请已提交：${r?['status'] ?? '审核中'}');
      if (withdrawalId != null) {
        poller = Timer.periodic(const Duration(seconds: 10), (_) async {
          final latest = await widget.api?.withdrawalStatus(withdrawalId!);
          if (mounted) setState(() => status = '提现状态：${latest?['status']}');
          if ({'CHAIN_CONFIRMED', 'FAILED'}.contains(latest?['status'])) {
            poller?.cancel();
          }
        });
      }
    } catch (e) {
      setState(
          () => status = e is BusinessApiException ? e.message : '提现提交失败，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = WeChatColors.elevatedSurface(context);
    return ListView(
      key: const Key('wallet-page-list'),
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(ChangliaoIcons.wallet,
                    size: 20, color: WeChatColors.brandPrimary),
                const SizedBox(width: 8),
                Text('USDT-TRC20 余额',
                    style: const TextStyle(
                        color: WeChatColors.textSecondary, fontSize: 14)),
              ]),
              const SizedBox(height: 10),
              FutureBuilder<Map<String, dynamic>>(
                future: balance,
                builder: (_, snapshot) => Text(
                  snapshot.hasError
                      ? '钱包暂不可用'
                      : '${snapshot.data?['balance'] ?? '--'} USDT',
                  key: const Key('wallet-balance-value'),
                  style: TextStyle(
                      fontSize: WeChatTypography.display,
                      fontWeight: FontWeight.w600,
                      height: 36 / 28,
                      color: WeChatColors.resolveTextPrimary(context)),
                ),
              ),
              const SizedBox(height: 6),
              const Text('六位小数 · 与点钻严格隔离，不可互兑',
                  style:
                      TextStyle(color: WeChatColors.textSecondary, fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: WeChatListTile(
            leading: Icon(CupertinoIcons.arrow_down_circle,
                size: 24, color: WeChatColors.brandPrimary),
            title: Text('获取充值地址',
                style: TextStyle(
                    fontSize: 16,
                    color: WeChatColors.resolveTextPrimary(context))),
            subtitle: Text(depositAddress == null
                ? '最低充值 1 USDT，20 个确认后到账'
                : '已生成专属充值地址',
                style: const TextStyle(
                    color: WeChatColors.textSecondary, fontSize: 13)),
            onTap: _loadDepositAddress,
          ),
        ),
        if (depositAddress != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: card,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(children: [
              Text(depositAddress!,
                  key: const Key('wallet-deposit-address'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: WeChatColors.resolveTextPrimary(context))),
              const SizedBox(height: 10),
              ModernActionButton(
                icon: ChangliaoIcons.confirm,
                label: '复制完整地址',
                onPressed: _copyAddress,
              ),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('提现',
                style: TextStyle(
                    fontSize: 13,
                    color: WeChatColors.textSecondary)),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            _field('金额', amount, '0.000000',
                key: const Key('wallet-withdraw-amount'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                suffix: 'USDT'),
            _divider(),
            _field('地址', address, 'TRC20 收款地址',
                key: const Key('wallet-withdraw-address')),
          ]),
        ),
        const SizedBox(height: 8),
        const Text('提现状态：申请 → 审核 → 托管方处理 → 链上确认',
            textAlign: TextAlign.center,
            style: TextStyle(color: WeChatColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 16),
        ModernActionButton(
          icon: ChangliaoIcons.transfer,
          label: '提交提现申请',
          onPressed: widget.api == null ? null : withdraw,
        ),
        if (status != null) ...[
          const SizedBox(height: 12),
          Text(status!,
              key: const Key('wallet-status'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: WeChatColors.textSecondary, fontSize: 13)),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('交易记录',
                style: TextStyle(
                    fontSize: 13, color: WeChatColors.textSecondary)),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: FutureBuilder<Map<String, dynamic>>(
            future: widget.api?.walletHistory(),
            builder: (_, snapshot) {
              final rows = (snapshot.data?['items'] as List?) ?? const [];
              if (rows.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(
                      child: Text('暂无交易记录',
                          style: TextStyle(
                              color: WeChatColors.textSecondary,
                              fontSize: 14))),
                );
              }
              return Column(
                children: [
                  for (final r in rows)
                    WeChatListTile(
                      leading: Icon(
                        r['kind'] == 'deposit'
                            ? CupertinoIcons.arrow_down_circle
                            : CupertinoIcons.arrow_up_circle,
                        size: 24,
                        color: WeChatColors.brandPrimary,
                      ),
                      title: Text(r['kind'] == 'deposit' ? '充值' : '提现',
                          style: TextStyle(
                              fontSize: 16,
                              color:
                                  WeChatColors.resolveTextPrimary(context))),
                      subtitle: Text(r['status'].toString(),
                          style: const TextStyle(
                              color: WeChatColors.textSecondary,
                              fontSize: 13)),
                      trailing: Text('${r['amount']} USDT',
                          style: TextStyle(
                              fontSize: 14,
                              color:
                                  WeChatColors.resolveTextPrimary(context))),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String placeholder, {
    Key? key,
    TextInputType? keyboardType,
    String? suffix,
  }) =>
      Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: WeChatColors.elevatedSurface(context),
        child: Row(children: [
          SizedBox(
              width: 64,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 16,
                      color: WeChatColors.resolveTextPrimary(context)))),
          Expanded(
            child: CupertinoTextField(
              key: key,
              controller: controller,
              textAlign: TextAlign.right,
              keyboardType: keyboardType,
              placeholder: placeholder,
              placeholderStyle: const TextStyle(
                  fontSize: 15, color: WeChatColors.textTertiary),
              style: TextStyle(
                  fontSize: 15,
                  color: WeChatColors.resolveTextPrimary(context)),
              decoration: const BoxDecoration(),
            ),
          ),
          if (suffix != null) ...[
            const SizedBox(width: 6),
            Text(suffix,
                style: const TextStyle(
                    fontSize: 14, color: WeChatColors.textSecondary)),
          ],
        ]),
      );

  Widget _divider() => Container(
      height: .5,
      margin: const EdgeInsets.only(left: 16),
      color: WeChatColors.divider);
}
