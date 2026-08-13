import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/wechat_list_tile.dart';

final class ContactsPage extends StatelessWidget {
  const ContactsPage({super.key, required this.api});
  final BusinessApiClient api;
  @override Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(middle: const Text('通讯录'), trailing: CupertinoButton(padding: EdgeInsets.zero, onPressed: () => Navigator.push(context, CupertinoPageRoute(builder: (_) => AddFriendPage(api: api))), child: const Icon(CupertinoIcons.person_add))),
    child: SafeArea(child: FutureBuilder<Map<String,dynamic>>(
      future: api.friends(),
      builder: (_, snapshot) {
        final items = (snapshot.data?['items'] as List?) ?? const [];
        return ListView(children: [
          WeChatListTile(leading: const Icon(CupertinoIcons.person_add_solid), title: const Text('新的朋友'), onTap: () => Navigator.push(context, CupertinoPageRoute(builder: (_) => FriendRequestsPage(api: api)))),
          const WeChatListTile(leading: Icon(CupertinoIcons.person_3_fill), title: Text('群聊')),
          WeChatListTile(leading: const Icon(CupertinoIcons.tag_fill), title: const Text('标签'), onTap: () => Navigator.push(context, CupertinoPageRoute(builder: (_) => ContactTagsPage(api: api)))),
          for (final item in items) WeChatListTile(leading: const Icon(CupertinoIcons.person_crop_square), title: Text(item['username']?.toString() ?? ''), subtitle: Text(item['user_id']?.toString() ?? ''),onTap:()=>Navigator.push(context,CupertinoPageRoute(builder:(_)=>ContactDetailPage(api:api,userId:item['user_id'].toString(),username:item['username'].toString())))),
        ]);
      },
    )),
  );
}

final class ContactDetailPage extends StatefulWidget{const ContactDetailPage({super.key,required this.api,required this.userId,required this.username});final BusinessApiClient api;final String userId,username;@override State<ContactDetailPage> createState()=>_ContactDetailPageState();}
final class _ContactDetailPageState extends State<ContactDetailPage>{final remark=TextEditingController();final tags=TextEditingController();String permission='DEFAULT';String? result;@override void dispose(){remark.dispose();tags.dispose();super.dispose();}@override Widget build(BuildContext context)=>CupertinoPageScaffold(navigationBar:CupertinoNavigationBar(middle:Text(widget.username)),child:SafeArea(child:ListView(children:[CupertinoListSection.insetGrouped(children:[CupertinoTextField(controller:remark,placeholder:'备注名',padding:const EdgeInsets.all(12)),CupertinoTextField(controller:tags,placeholder:'标签（逗号分隔）',padding:const EdgeInsets.all(12))]),CupertinoListSection.insetGrouped(header:const Text('朋友圈权限'),children:[for(final p in const{'DEFAULT':'默认','HIDE_MINE':'不让他看我','HIDE_THEIRS':'不看他','MUTUAL_HIDE':'互相不可见'}.entries)CupertinoListTile(title:Text(p.value),trailing:permission==p.key?const Icon(CupertinoIcons.check_mark):null,onTap:()=>setState(()=>permission=p.key))]),CupertinoButton.filled(onPressed:()async{await widget.api.updateContact(widget.userId,remark:remark.text.trim().isEmpty?null:remark.text.trim(),tags:tags.text.split(',').map((e)=>e.trim()).where((e)=>e.isNotEmpty).toList(),momentsPermission:permission);if(mounted)setState(()=>result='已保存');},child:const Text('保存')),CupertinoButton(onPressed:()async{await widget.api.blockUser(widget.userId);if(mounted)setState(()=>result='已加入黑名单');},child:const Text('加入黑名单',style:TextStyle(color:CupertinoColors.systemRed))),if(result!=null)Center(child:Text(result!))])));}

final class ContactTagsPage extends StatefulWidget { const ContactTagsPage({super.key, required this.api}); final BusinessApiClient api; @override State<ContactTagsPage> createState()=>_ContactTagsPageState(); }
final class _ContactTagsPageState extends State<ContactTagsPage> {
  final name=TextEditingController();
  @override void dispose(){name.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>CupertinoPageScaffold(navigationBar: const CupertinoNavigationBar(middle:Text('标签')),child:SafeArea(child:FutureBuilder<Map<String,dynamic>>(future:widget.api.contactTags(),builder:(_,snapshot){final items=(snapshot.data?['items'] as List?)??const[];return ListView(children:[CupertinoListSection.insetGrouped(children:[CupertinoTextField(controller:name,placeholder:'新标签名称',padding:const EdgeInsets.all(12)),CupertinoButton(onPressed:()async{await widget.api.createContactTag(name.text.trim());if(mounted)setState((){});},child:const Text('创建标签'))]),for(final tag in items)WeChatListTile(leading:const Icon(CupertinoIcons.tag),title:Text(tag['name'].toString()))]);})));
}

final class AddFriendPage extends StatefulWidget { const AddFriendPage({super.key, required this.api}); final BusinessApiClient api; @override State<AddFriendPage> createState() => _AddFriendState(); }
final class _AddFriendState extends State<AddFriendPage> {
  final q = TextEditingController(); List items = [];
  @override void dispose(){q.dispose();super.dispose();}
  @override Widget build(BuildContext context) => CupertinoPageScaffold(navigationBar: const CupertinoNavigationBar(middle: Text('添加朋友')), child: SafeArea(child: ListView(children: [CupertinoSearchTextField(controller: q, onSubmitted: (v) async { final r=await widget.api.searchUsers(v); if(mounted)setState(()=>items=r['items'] as List); }), for(final u in items) WeChatListTile(title: Text(u['username'].toString()), trailing: CupertinoButton(onPressed: ()=>widget.api.requestFriend(u['id'].toString()), child: const Text('添加')))])));
}

final class FriendRequestsPage extends StatelessWidget {
  const FriendRequestsPage({super.key, required this.api}); final BusinessApiClient api;
  @override Widget build(BuildContext context) => CupertinoPageScaffold(navigationBar: const CupertinoNavigationBar(middle: Text('新的朋友')), child: SafeArea(child: FutureBuilder<Map<String,dynamic>>(
    future: api.friendRequests(), builder: (_, snapshot) {
      final items=(snapshot.data?['items'] as List?) ?? const [];
      return ListView(children: [for(final r in items) WeChatListTile(title: Text(r['requester_id']?.toString()??''), subtitle: Text(r['message']?.toString()??''), trailing: Row(mainAxisSize: MainAxisSize.min, children: [CupertinoButton(onPressed: ()=>api.rejectFriendRequest(r['id'].toString()), child: const Text('拒绝')), CupertinoButton(onPressed: ()=>api.acceptFriendRequest(r['id'].toString()), child: const Text('接受'))]))]);
    },
  )));
}
