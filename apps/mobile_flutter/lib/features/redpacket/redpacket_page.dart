import 'package:flutter/material.dart';
final class RedPacketPage extends StatelessWidget {
  const RedPacketPage({super.key});
  @override Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: const [Text('彩币红包', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)), SizedBox(height: 12), Card(child: ListTile(leading: Icon(Icons.redeem), title: Text('群红包 / 私聊红包'), subtitle: Text('24 小时未领取自动退回')))]);
}
