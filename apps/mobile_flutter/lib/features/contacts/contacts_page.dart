import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/wechat_list_tile.dart';
final class ContactsPage extends StatelessWidget {
  const ContactsPage({super.key,required this.api}); final BusinessApiClient api;
  @override Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar:const CupertinoNavigationBar(middle:Text('通讯录')),
    child:SafeArea(child:FutureBuilder<Map<String,dynamic>>(
      future:api.friends(), builder:(_,snapshot){
        final items=(snapshot.data?['items'] as List?)??const [];
        return ListView(children:[
          const WeChatListTile(leading:Icon(CupertinoIcons.person_add_solid),title:Text('新的朋友')),
          const WeChatListTile(leading:Icon(CupertinoIcons.person_3_fill),title:Text('群聊')),
          const WeChatListTile(leading:Icon(CupertinoIcons.tag_fill),title:Text('标签')),
          for(final item in items) WeChatListTile(leading:const Icon(CupertinoIcons.person_crop_square),title:Text(item['username']?.toString()??''),subtitle:Text(item['user_id']?.toString()??'')),
        ]);
      },
    )),
  );
}
