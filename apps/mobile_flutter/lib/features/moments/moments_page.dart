import 'package:flutter/cupertino.dart';

import '../../ui/components/wechat_scaffold.dart';

import '../../ui/foundation/wechat_tokens.dart';
import '../../core/business_api_client.dart';
import '../../ui/moments/wechat_moment_tile.dart';

final class MomentsPage extends StatefulWidget {
  const MomentsPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<MomentsPage> createState() => _MomentsPageState();
}

final class _MomentsPageState extends State<MomentsPage> {
  String mode = 'recommended';
  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.chatNavigationBackground,
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: const Text('朋友圈'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.push(
                      context,
                      CupertinoPageRoute(
                          builder: (_) =>
                              MomentsSettingsPage(api: widget.api))),
                  child: const Icon(CupertinoIcons.settings)),
              CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.push(
                      context,
                      CupertinoPageRoute(
                          builder: (_) => MomentComposerPage(api: widget.api))),
                  child: const Icon(CupertinoIcons.camera))
            ])),
        child: SafeArea(
            child: FutureBuilder<Map<String, dynamic>>(
                future: widget.api.momentsFeed(mode: mode),
                builder: (_, snapshot) {
                  final items = (snapshot.data?['items'] as List?) ?? const [];
                  return ListView(children: [
                    SizedBox(
                        height: 200,
                        child: Container(
                            color: const Color(0xff4c4c4c),
                            alignment: Alignment.bottomRight,
                            padding: const EdgeInsets.all(16),
                            child: const Text('畅聊朋友圈',
                                style: TextStyle(
                                    color: CupertinoColors.white,
                                    fontSize: 22)))),
                    CupertinoSlidingSegmentedControl<String>(
                        groupValue: mode,
                        children: const {
                          'recommended': Text('推荐'),
                          'latest': Text('最新')
                        },
                        onValueChanged: (v) => setState(() => mode = v!)),
                    for (final m in items)
                      WeChatMomentTile(
                          author: m['author_id'].toString(),
                          text: m['text'].toString(),
                          images:
                              List<String>.from(m['image_urls'] ?? const []),
                          onLike: () =>
                              widget.api.likeMoment(m['id'].toString())),
                  ]);
                })),
      );
}

final class MomentComposerPage extends StatefulWidget {
  const MomentComposerPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<MomentComposerPage> createState() => _ComposerState();
}

final class _ComposerState extends State<MomentComposerPage> {
  final text = TextEditingController();
  final users = TextEditingController();
  String visibility = 'PUBLIC';
  @override
  void dispose() {
    text.dispose();
    users.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('发表'),
          trailing: CupertinoButton(
              onPressed: () async {
                final ids = users.text
                    .split(',')
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList();
                await widget.api.publishMoment(
                    text: text.text,
                    visibility: visibility,
                    includeUserIds: visibility == 'INCLUDE' ? ids : const [],
                    excludeUserIds: visibility == 'EXCLUDE' ? ids : const []);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('发表'))),
      child: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
        CupertinoTextField(
            controller: text,
            minLines: 5,
            maxLines: 10,
            placeholder: '这一刻的想法…'),
        const SizedBox(height: 16),
        CupertinoSlidingSegmentedControl<String>(
            groupValue: visibility,
            children: const {
              'PUBLIC': Text('公开'),
              'FRIENDS': Text('好友'),
              'SELF': Text('私密')
            },
            onValueChanged: (v) => setState(() => visibility = v!)),
        CupertinoListSection.insetGrouped(
            header: const Text('更多可见范围'),
            children: [
              CupertinoListTile(
                  title: const Text('部分可见'),
                  trailing: visibility == 'INCLUDE'
                      ? const Icon(CupertinoIcons.check_mark)
                      : null,
                  onTap: () => setState(() => visibility = 'INCLUDE')),
              CupertinoListTile(
                  title: const Text('不给谁看'),
                  trailing: visibility == 'EXCLUDE'
                      ? const Icon(CupertinoIcons.check_mark)
                      : null,
                  onTap: () => setState(() => visibility = 'EXCLUDE'))
            ]),
        if (visibility == 'INCLUDE' || visibility == 'EXCLUDE')
          CupertinoTextField(controller: users, placeholder: '输入用户 ID，多个用逗号分隔'),
        const SizedBox(height: 16),
        const Text('首版支持最多9张图片，不支持视频。公开图片内容会进入平台审核。')
      ])));
}

final class MomentsSettingsPage extends StatefulWidget {
  const MomentsSettingsPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<MomentsSettingsPage> createState() => _MomentsSettingsState();
}

final class _MomentsSettingsState extends State<MomentsSettingsPage> {
  String range = 'ALL';
  bool personalized = true;
  @override
  void initState() {
    super.initState();
    widget.api.momentsPreferences().then((r) {
      if (mounted) {
        setState(() {
          range = r['history_range'];
          personalized = r['personalized_recommendations'];
        });
      }
    });
  }

  Future<void> save() async {
    await widget.api.updateMomentsPreferences(
        historyRange: range, personalized: personalized);
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text('朋友圈权限')),
      child: SafeArea(
          child: ListView(children: [
        CupertinoListSection.insetGrouped(
            header: const Text('允许朋友查看朋友圈的范围'),
            children: [
              for (final item in const {
                'ALL': '全部',
                'SIX_MONTHS': '最近半年',
                'ONE_MONTH': '最近一个月',
                'THREE_DAYS': '最近三天'
              }.entries)
                CupertinoListTile(
                    title: Text(item.value),
                    trailing: range == item.key
                        ? const Icon(CupertinoIcons.check_mark,
                            color: Color(0xff07c160))
                        : null,
                    onTap: () {
                      setState(() => range = item.key);
                      save();
                    })
            ]),
        CupertinoListSection.insetGrouped(children: [
          CupertinoListTile(
              title: const Text('个性化推荐'),
              trailing: CupertinoSwitch(
                  value: personalized,
                  onChanged: (v) {
                    setState(() => personalized = v);
                    save();
                  }))
        ])
      ])));
}
