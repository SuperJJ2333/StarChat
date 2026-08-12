import 'package:flutter/material.dart';
final class CaibiPage extends StatelessWidget {
  const CaibiPage({super.key});
  @override Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: const [Text('彩币', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)), SizedBox(height: 12), Card(child: ListTile(title: Text('彩币余额'), subtitle: Text('从业务 API 获取'), trailing: Text('CAIBI'))), ListTile(leading: Icon(Icons.swap_horiz), title: Text('转账'), subtitle: Text('手续费 0.5%，最低 0.01 彩币')), ListTile(leading: Icon(Icons.card_giftcard), title: Text('红包'), subtitle: Text('等额 / 拼手气'))]);
}
