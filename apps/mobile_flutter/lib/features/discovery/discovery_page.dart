import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../moments/moments_page.dart';
import '../../ui/components/wechat_list_tile.dart';
final class DiscoveryPage extends StatelessWidget {
 const DiscoveryPage({super.key,required this.api}); final BusinessApiClient api;
 @override Widget build(BuildContext context)=>CupertinoPageScaffold(navigationBar:const CupertinoNavigationBar(middle:Text('发现')),child:SafeArea(child:ListView(children:[WeChatListTile(leading:const Icon(CupertinoIcons.photo),title:const Text('朋友圈'),trailing:const Icon(CupertinoIcons.chevron_right),onTap:()=>Navigator.push(context,CupertinoPageRoute(builder:(_)=>MomentsPage(api:api))))])));
}
