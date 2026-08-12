import 'package:flutter/material.dart';
import '../../core/business_api_client.dart';
final class RedPacketPage extends StatelessWidget {
  const RedPacketPage({super.key, this.api});
  final BusinessApiClient? api;
  @override Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [const Text('彩币红包', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)), const SizedBox(height: 12), Card(child: ListTile(leading: const Icon(Icons.redeem), title: const Text('群红包 / 私聊红包'), subtitle: Text(api == null ? '24 小时未领取自动退回' : '已连接业务 API · 24 小时未领取自动退回')))]);
}
