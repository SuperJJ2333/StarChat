import 'dart:async';
import '../../ui/components/modern_action_button.dart';
import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';

final class WalletPage extends StatefulWidget {
  const WalletPage({super.key, this.api});
  final BusinessApiClient? api;
  @override
  State<WalletPage> createState() => _WalletPageState();
}

final class _WalletPageState extends State<WalletPage> {
  final amount = TextEditingController();
  final address = TextEditingController();
  String? status;
  Timer? poller;
  String? withdrawalId;
  @override
  void dispose() {
    poller?.cancel();
    amount.dispose();
    address.dispose();
    super.dispose();
  }

  Future<void> withdraw() async {
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
      setState(() => status = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(20), children: [
        const Text('USDT 钱包',
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
        const SizedBox(height: 18),
        CupertinoListSection.insetGrouped(children: [
          CupertinoListTile(
              leading: const Icon(CupertinoIcons.creditcard_fill,
                  color: Color(0xff07c160)),
              title: const Text('USDT-TRC20'),
              subtitle: FutureBuilder<Map<String, dynamic>>(
                  future: widget.api?.walletBalance(),
                  builder: (_, s) => Text(s.hasError
                      ? '钱包暂不可用'
                      : '${s.data?['balance'] ?? '加载中…'} USDT')),
              trailing: const Text('6位小数'))
        ]),
        CupertinoListSection.insetGrouped(header: const Text('充值'), children: [
          CupertinoListTile(
              leading: const Icon(CupertinoIcons.arrow_down_circle),
              title: const Text('获取充值地址'))
        ]),
        CupertinoListSection.insetGrouped(header: const Text('提现'), children: [
          CupertinoTextField(
              controller: amount,
              placeholder: '提现金额（6位小数）',
              keyboardType: TextInputType.number,
              padding: const EdgeInsets.all(14)),
          CupertinoTextField(
              controller: address,
              placeholder: 'USDT-TRC20 地址',
              padding: const EdgeInsets.all(14)),
          ModernActionButton(
              icon: CupertinoIcons.arrow_up_circle,
              label: '提交提现申请',
              onPressed: widget.api == null ? null : withdraw)
        ]),
        CupertinoListSection.insetGrouped(
            header: const Text('交易记录'),
            children: [
              FutureBuilder<Map<String, dynamic>>(
                  future: widget.api?.walletHistory(),
                  builder: (_, s) {
                    final rows = (s.data?['items'] as List?) ?? const [];
                    return Column(children: [
                      for (final r in rows)
                        CupertinoListTile(
                            title: Text(r['kind'] == 'deposit' ? '充值' : '提现'),
                            subtitle: Text(r['status'].toString()),
                            trailing: Text('${r['amount']} USDT'))
                    ]);
                  })
            ]),
        if (status != null) Text(status!),
        const Text('提现状态：申请 → 审核 → 托管方处理 → 链上确认',
            style: TextStyle(color: CupertinoColors.secondaryLabel))
      ]);
}
