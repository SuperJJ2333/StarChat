import 'package:flutter/material.dart';
import '../../core/business_api_client.dart';
final class CaibiPage extends StatelessWidget {
  const CaibiPage({super.key, this.api});
  final BusinessApiClient? api;
  @override Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [const Text('彩币', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)), const SizedBox(height: 12), Card(child: ListTile(title: const Text('彩币余额'), subtitle: FutureBuilder<Map<String, dynamic>>(future: api?.caibiBalance(), builder: (_, s) => Text(s.hasError ? '余额暂不可用' : '${s.data?['balance'] ?? '加载中…'} 彩币')), trailing: const Text('CAIBI'))), const ListTile(leading: Icon(Icons.swap_horiz), title: Text('转账'), subtitle: Text('手续费 0.5%，由转出方承担')), const ListTile(leading: Icon(Icons.card_giftcard), title: Text('红包'), subtitle: Text('等额 / 拼手气'))]);
}
