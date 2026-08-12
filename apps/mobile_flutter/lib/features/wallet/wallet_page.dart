import 'package:flutter/material.dart';
final class WalletPage extends StatelessWidget {
  const WalletPage({super.key});
  @override Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: const [Text('USDT 钱包', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)), SizedBox(height: 12), Card(child: ListTile(title: Text('USDT-TRC20'), subtitle: Text('充值、提现、链上确认'), trailing: Text('0.000000'))), ListTile(leading: Icon(Icons.download), title: Text('充值')), ListTile(leading: Icon(Icons.upload), title: Text('提现'))]);
}
