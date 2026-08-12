import 'package:flutter/material.dart';
import '../../core/business_api_client.dart';
final class WalletPage extends StatelessWidget {
  const WalletPage({super.key, this.api});
  final BusinessApiClient? api;
  @override Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [const Text('USDT 钱包', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)), const SizedBox(height: 12), Card(child: ListTile(title: const Text('USDT-TRC20'), subtitle: FutureBuilder<Map<String, dynamic>>(future: api?.walletBalance(), builder: (_, s) => Text(s.hasError ? '钱包暂不可用' : '${s.data?['balance'] ?? '加载中…'}')), trailing: const Text('6位小数'))), const ListTile(leading: Icon(Icons.download), title: Text('充值'), subtitle: Text('显示托管商生成的充值地址')), const ListTile(leading: Icon(Icons.upload), title: Text('提现'), subtitle: Text('申请→审核→托管商→链上确认'))]);
}
