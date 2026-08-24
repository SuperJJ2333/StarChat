import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../contacts/contact_models.dart';
import '../contacts/contact_tag_models.dart';
import '../../ui/components/wechat_scaffold.dart';

final class MomentAudiencePickerPage extends StatefulWidget {
  const MomentAudiencePickerPage(
      {super.key,
      required this.api,
      required this.initialUsers,
      required this.initialTags});
  final BusinessApiClient api;
  final Set<String> initialUsers, initialTags;
  @override
  State<MomentAudiencePickerPage> createState() =>
      _MomentAudiencePickerPageState();
}

class _MomentAudiencePickerPageState extends State<MomentAudiencePickerPage> {
  late final users = {...widget.initialUsers};
  late final tags = {...widget.initialTags};
  String query = '';
  late Future<List<dynamic>> data =
      Future.wait([widget.api.listContacts(), widget.api.contactTags()]);
  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          middle: const Text('选择标签或者朋友'),
          trailing: CupertinoButton(
              onPressed: () => Navigator.pop(
                  context, {'users': users.toList(), 'tags': tags.toList()}),
              child: const Text('完成'))),
      child: FutureBuilder<List<dynamic>>(
          future: data,
          builder: (_, s) {
            if (!s.hasData) {
              return const Center(child: CupertinoActivityIndicator());
            }
            final contacts = (s.data![0] as List<ContactSummary>)
                .where((c) =>
                    c.displayName.toLowerCase().contains(query.toLowerCase()))
                .toList();
            final allTags =
                ((s.data![1] as Map<String, dynamic>)['items'] as List)
                    .map((value) => ContactTagSummary.fromJson(
                        Map<String, dynamic>.from(value as Map)))
                    .toList();
            return ListView(children: [
              CupertinoSearchTextField(
                  onChanged: (v) => setState(() => query = v)),
              const Padding(padding: EdgeInsets.all(12), child: Text('朋友')),
              for (final c in contacts)
                CupertinoListTile(
                    title: Text(c.displayName),
                    trailing: Icon(users.contains(c.userId)
                        ? CupertinoIcons.check_mark_circled_solid
                        : CupertinoIcons.circle),
                    onTap: () => setState(() => users.contains(c.userId)
                        ? users.remove(c.userId)
                        : users.add(c.userId))),
              const Padding(padding: EdgeInsets.all(12), child: Text('标签')),
              for (final t in allTags)
                CupertinoListTile(
                    title: Text(t.name),
                    additionalInfo: Text('${t.friendCount} 位朋友'),
                    trailing: Icon(tags.contains(t.id)
                        ? CupertinoIcons.check_mark_circled_solid
                        : CupertinoIcons.circle),
                    onTap: () => setState(() => tags.contains(t.id)
                        ? tags.remove(t.id)
                        : tags.add(t.id)))
            ]);
          }));
}
