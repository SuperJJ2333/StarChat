import 'package:flutter/material.dart';
import 'features/caibi/caibi_page.dart';
import 'features/redpacket/redpacket_page.dart';
import 'features/wallet/wallet_page.dart';
final class AppHome extends StatefulWidget { const AppHome({super.key}); @override State<AppHome> createState() => _AppHomeState(); }
class _AppHomeState extends State<AppHome> {
  int index = 0;
  final pages = const [CaibiPage(), RedPacketPage(), WalletPage()];
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('六合通')), body: pages[index], bottomNavigationBar: NavigationBar(selectedIndex: index, onDestinationSelected: (value) => setState(() => index = value), destinations: const [NavigationDestination(icon: Icon(Icons.monetization_on), label: '彩币'), NavigationDestination(icon: Icon(Icons.card_giftcard), label: '红包'), NavigationDestination(icon: Icon(Icons.account_balance_wallet), label: '钱包')]));
}
