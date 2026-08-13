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
          const WeChatListTile(leading: Icon(CupertinoIcons.tag_fill), title: Text('标签')),
          for (final item in items) WeChatListTile(leading: const Icon(CupertinoIcons.person_crop_square), title: Text(item['username']?.toString() ?? ''), subtitle: Text(item['user_id']?.toString() ?? '')),
        ]);
      },
    )),
  );
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
