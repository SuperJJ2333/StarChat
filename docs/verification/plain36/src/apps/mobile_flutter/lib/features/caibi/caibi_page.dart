import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../core/amount_rules.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';

final class CaibiPage extends StatefulWidget {
  const CaibiPage({super.key, this.api});
  final BusinessApiClient? api;
  @override
  State<CaibiPage> createState() => _CaibiPageState();
}

final class _CaibiPageState extends State<CaibiPage> {
  final receiver = TextEditingController();
  final amount = TextEditingController();
  Future<Map<String, dynamic>>? balance;
  String? result;
  bool submitting = false;

  @override
  void initState() {
    super.initState();
    _refreshBalance();
  }

  @override
  void dispose() {
    receiver.dispose();
    amount.dispose();
    super.dispose();
  }

  void _refreshBalance() {
    final api = widget.api;
    if (api == null) return;
    balance = api.caibiBalance();
  }

  Future<void> transfer() async {
    final receiverId = receiver.text.trim();
    if (receiverId.isEmpty) {
      setState(() => result = '请输入收款用户的畅聊号或用户 ID');
      return;
    }
    final amountError = AmountRules.validate(amount.text);
    if (amountError != null) {
      setState(() => result = amountError);
      return;
    }
    setState(() {
      submitting = true;
      result = null;
    });
    try {
      await widget.api?.transferCaibi(receiverId, amount.text.trim());
      setState(() {
        result = '转账已提交，手续费由转出方承担';
        amount.clear();
      });
      _refreshBalance();
    } catch (e) {
      setState(
          () => result = e is BusinessApiException ? e.message : '转账失败，请稍后重试');
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = WeChatColors.elevatedSurface(context);
    return ListView(
      key: const Key('caibi-page-list'),
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
                Icon(ChangliaoIcons.transferFilled,
                    size: 20, color: WeChatColors.brandPrimary),
                const SizedBox(width: 8),
                Text('点钻余额',
                    style: const TextStyle(
                        color: WeChatColors.textSecondary, fontSize: 14)),
              ]),
              const SizedBox(height: 10),
              FutureBuilder<Map<String, dynamic>>(
                future: balance,
                builder: (_, snapshot) => Text(
                  snapshot.hasError
                      ? '暂不可用'
                      : '${snapshot.data?['balance'] ?? '--'} 点钻',
                  key: const Key('caibi-balance-value'),
                  style: TextStyle(
                      fontSize: WeChatTypography.display,
                      fontWeight: FontWeight.w600,
                      height: 36 / 28,
                      color: WeChatColors.resolveTextPrimary(context)),
                ),
              ),
              const SizedBox(height: 6),
              const Text('CAIBI · 两位小数 · 仅用于红包与转账',
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
          child: Column(children: [
            _field('收款用户', receiver, '对方畅聊号或用户 ID',
                key: const Key('caibi-transfer-receiver')),
            _divider(),
            _field('金额', amount, '0.00',
                key: const Key('caibi-transfer-amount'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: const [TwoDecimalAmountFormatter()],
                suffix: '点钻'),
          ]),
        ),
        const SizedBox(height: 8),
        const Text('转出方承担 0.5% 手续费，最低 0.01 点钻',
            textAlign: TextAlign.center,
            style: TextStyle(color: WeChatColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 16),
        ModernActionButton(
          icon: ChangliaoIcons.transfer,
          label: '转出',
          loading: submitting,
          onPressed: widget.api == null || submitting ? null : transfer,
        ),
        if (result != null) ...[
          const SizedBox(height: 12),
          Text(result!,
              key: const Key('caibi-transfer-result'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: WeChatColors.textSecondary, fontSize: 13)),
        ],
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String placeholder, {
    Key? key,
    TextInputType? keyboardType,
    List<TextInputFormatter> inputFormatters = const [],
    String? suffix,
  }) =>
      Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: WeChatColors.elevatedSurface(context),
        child: Row(children: [
          SizedBox(
              width: 84,
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
              inputFormatters: inputFormatters,
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
