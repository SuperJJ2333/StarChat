import 'package:flutter/cupertino.dart';
import 'features/caibi/caibi_page.dart';
import 'features/redpacket/redpacket_page.dart';
import 'features/wallet/wallet_page.dart';
import 'core/business_api_client.dart';
final class AppHome extends StatelessWidget {
  const AppHome({super.key, this.api});
  final BusinessApiClient? api;
  @override Widget build(BuildContext context) => CupertinoTabScaffold(tabBar: CupertinoTabBar(items: const [BottomNavigationBarItem(icon: Icon(CupertinoIcons.money_dollar_circle_fill), label: '彩币'), BottomNavigationBarItem(icon: Icon(CupertinoIcons.gift_fill), label: '红包'), BottomNavigationBarItem(icon: Icon(CupertinoIcons.creditcard_fill), label: '钱包')]), tabBuilder: (context, index) => CupertinoTabView(builder: (_) => CupertinoPageScaffold(navigationBar: CupertinoNavigationBar(middle: Text(['彩币', '红包', '钱包'][index])), child: [CaibiPage(api: api), RedPacketPage(api: api), WalletPage(api: api)][index])));
}
