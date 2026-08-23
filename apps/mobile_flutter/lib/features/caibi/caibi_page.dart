import 'package:flutter/cupertino.dart';
import '../../ui/components/modern_action_button.dart';
import '../../core/business_api_client.dart';

final class CaibiPage extends StatefulWidget {
  const CaibiPage({super.key, this.api});
  final BusinessApiClient? api;
  @override
  State<CaibiPage> createState() => _CaibiPageState();
}

final class _CaibiPageState extends State<CaibiPage> {
  final receiver = TextEditingController();
  final amount = TextEditingController();
  String? result;
  @override
  void dispose() {
    receiver.dispose();
    amount.dispose();
    super.dispose();
  }

  Future<void> transfer() async {
    try {
      await widget.api?.transferCaibi(receiver.text.trim(), amount.text.trim());
      setState(() => result = '转账已提交，手续费由转出方承担');
    } catch (e) {
      setState(() => result = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(20), children: [
        const Text('点钻',
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
        const SizedBox(height: 18),
        Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
                color: CupertinoColors.systemIndigo.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(20)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('点钻余额',
                  style: TextStyle(color: CupertinoColors.secondaryLabel)),
              const SizedBox(height: 8),
              FutureBuilder<Map<String, dynamic>>(
                  future: widget.api?.caibiBalance(),
                  builder: (_, s) => Text(
                      s.hasError
                          ? '暂不可用'
                          : '${s.data?['balance'] ?? '加载中…'} 点钻',
                      style: const TextStyle(
                          fontSize: 28, fontWeight: FontWeight.w700)))
            ])),
        const SizedBox(height: 18),
        CupertinoListSection.insetGrouped(header: const Text('转账'), children: [
          CupertinoTextField(
              controller: receiver,
              placeholder: '收款用户 ID',
              padding: const EdgeInsets.all(14)),
          CupertinoTextField(
              controller: amount,
              placeholder: '金额（两位小数）',
              keyboardType: TextInputType.number,
              padding: const EdgeInsets.all(14)),
          ModernActionButton(
              icon: CupertinoIcons.arrow_up_circle,
              label: '转出（含 0.5% 手续费）',
              onPressed: widget.api == null ? null : transfer)
        ]),
        if (result != null) Text(result!),
        CupertinoListSection.insetGrouped(children: const [
          CupertinoListTile(
              leading: Icon(CupertinoIcons.gift),
              title: Text('红包'),
              subtitle: Text('等额 / 拼手气，24 小时未领取自动退回'))
        ])
      ]);
}
