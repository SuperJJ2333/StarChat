import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/contact_models.dart';

/// Local-first global search. It searches authoritative contacts while the
/// caller may add encrypted room/message matches without exposing plaintext.
final class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({
    super.key,
    required this.api,
    this.contactsLoader,
    this.rooms = const [],
    this.messages = const [],
  });
  final BusinessApiClient api;
  final Future<List<ContactSummary>> Function()? contactsLoader;
  final List<String> rooms;
  final List<String> messages;

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

final class _GlobalSearchPageState extends State<GlobalSearchPage> {
  String query = '';
  Future<List<ContactSummary>>? contacts;

  @override
  void initState() {
    super.initState();
    contacts = widget.contactsLoader?.call() ?? widget.api.listContacts();
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('搜索'),
        ),
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoSearchTextField(
                autofocus: true,
                placeholder: '搜索朋友、群聊和聊天记录',
                onChanged: (value) => setState(() => query = value.trim()),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<ContactSummary>>(
                future: contacts,
                builder: (_, snapshot) {
                  final q = query.toLowerCase();
                  final friends = (snapshot.data ?? const <ContactSummary>[])
                      .where(
                          (item) => item.displayName.toLowerCase().contains(q))
                      .toList();
                  final rooms = widget.rooms
                      .where((item) => item.toLowerCase().contains(q));
                  final messages = widget.messages
                      .where((item) => item.toLowerCase().contains(q));
                  return ListView(children: [
                    if (query.isNotEmpty && friends.isNotEmpty)
                      const _Section('朋友'),
                    for (final item in friends)
                      WeChatListTile(
                          title: Text(item.displayName),
                          subtitle: Text('畅聊号：${item.username}')),
                    if (query.isNotEmpty && rooms.isNotEmpty)
                      const _Section('群聊'),
                    for (final room in rooms) WeChatListTile(title: Text(room)),
                    if (query.isNotEmpty && messages.isNotEmpty)
                      const _Section('聊天记录'),
                    for (final message in messages)
                      WeChatListTile(title: Text(message)),
                    if (query.isNotEmpty &&
                        friends.isEmpty &&
                        rooms.isEmpty &&
                        messages.isEmpty)
                      const Center(
                          child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text('无搜索结果'))),
                  ]);
                },
              ),
            ),
          ]),
        ),
      );
}

final class _Section extends StatelessWidget {
  const _Section(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(label,
            style: const TextStyle(color: WeChatColors.textSecondary)),
      );
}
