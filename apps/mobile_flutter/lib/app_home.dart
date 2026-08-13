import 'package:flutter/cupertino.dart';
import 'core/business_api_client.dart';
import 'features/contacts/contacts_page.dart';
import 'features/discovery/discovery_page.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'features/matrix/matrix_home_page.dart';
import 'features/caibi/caibi_page.dart';
import 'features/redpacket/redpacket_page.dart';
import 'features/wallet/wallet_page.dart';
import 'ui/components/wechat_list_tile.dart';

final class AppHome extends StatelessWidget{const AppHome({super.key,required this.api,required this.matrix});final BusinessApiClient api;final MatrixSdkE2eeClient matrix;@override Widget build(BuildContext context)=>CupertinoTabScaffold(tabBar:CupertinoTabBar(activeColor:const Color(0xff07c160),items:const [BottomNavigationBarItem(icon:Icon(CupertinoIcons.chat_bubble_2_fill),label:'消息'),BottomNavigationBarItem(icon:Icon(CupertinoIcons.person_2_fill),label:'通讯录'),BottomNavigationBarItem(icon:Icon(CupertinoIcons.compass_fill),label:'发现'),BottomNavigationBarItem(icon:Icon(CupertinoIcons.person_crop_circle_fill),label:'我')]),tabBuilder:(_,index)=>CupertinoTabView(builder:(_)=>switch(index){0=>MatrixHomePage(matrix:matrix),1=>ContactsPage(api:api),2=>DiscoveryPage(api:api),_=>ProfilePage(api:api)}));}
final class ProfilePage extends StatelessWidget{const ProfilePage({super.key,required this.api});final BusinessApiClient api;@override Widget build(BuildContext context)=>CupertinoPageScaffold(navigationBar:const CupertinoNavigationBar(middle:Text('我')),child:SafeArea(child:ListView(children:[const SizedBox(height:16),WeChatListTile(leading:const Icon(CupertinoIcons.money_dollar_circle_fill),title:const Text('彩币'),onTap:()=>Navigator.push(context,CupertinoPageRoute(builder:(_)=>CupertinoPageScaffold(navigationBar:const CupertinoNavigationBar(middle:Text('彩币')),child:CaibiPage(api:api))))),WeChatListTile(leading:const Icon(CupertinoIcons.gift_fill),title:const Text('红包'),onTap:()=>Navigator.push(context,CupertinoPageRoute(builder:(_)=>CupertinoPageScaffold(navigationBar:const CupertinoNavigationBar(middle:Text('红包')),child:RedPacketPage(api:api))))),WeChatListTile(leading:const Icon(CupertinoIcons.creditcard_fill),title:const Text('钱包'),onTap:()=>Navigator.push(context,CupertinoPageRoute(builder:(_)=>CupertinoPageScaffold(navigationBar:const CupertinoNavigationBar(middle:Text('钱包')),child:WalletPage(api:api))))) ])));}
