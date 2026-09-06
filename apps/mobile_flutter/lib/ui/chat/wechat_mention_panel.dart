import 'package:flutter/cupertino.dart';

import '../../features/contacts/member_directory_service.dart';
import '../foundation/wechat_tokens.dart';
import '../components/user_avatar.dart';

/// One selectable row of the 「选择提醒的人」 panel.
///
/// [primaryName] is the remark when the viewer set one, otherwise the
/// nickname; [nickname] is the plain Matrix nickname shown on the small
/// secondary line whenever it differs from [primaryName].
final class MentionOption {
  const MentionOption({
    required this.id,
    required this.primaryName,
    required this.nickname,
    this.hasRemark = false,
  });

  static const all =
      MentionOption(id: '@all', primaryName: '所有人', nickname: '所有人');

  final String id;
  final String primaryName;
  final String nickname;

  /// True when [primaryName] is the viewer's own remark for this member;
  /// only then does the panel show the plain nickname on the second line.
  final bool hasRemark;

  bool get isAll => id == all.id;
}

/// 统一拼音排序服务适配（规格 #6：@选择器与成员列表共用同一排序，
/// 中文按拼音分组而非归入 #）。
List<MentionOption> sortMentionOptions(List<MentionOption> options) {
  final byId = <String, MentionOption>{
    for (final option in options) option.id: option,
  };
  final entries = [
    for (final option in options)
      if (!option.isAll)
        MemberDirectoryEntry(
          userId: option.id,
          nickname: option.nickname,
          remark: option.hasRemark ? option.primaryName : null,
        ),
  ];
  // 「所有人」固定在成员列表之外（规格 #6），由面板单独渲染置顶。
  return [
    for (final entry in sortMemberEntries(entries)) byId[entry.userId]!,
  ];
}

/// 过滤同步迁移：拼音全拼/首字母 + 中文子串 + 英文忽略大小写。
List<MentionOption> filterMentionOptions(
  List<MentionOption> options,
  String query,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return options;
  final entries = [
    for (final option in options)
      if (!option.isAll)
        MemberDirectoryEntry(
          userId: option.id,
          nickname: option.nickname,
          remark: option.hasRemark ? option.primaryName : null,
        ),
  ];
  final matched = {
    for (final entry in filterMemberEntries(entries, needle)) entry.userId,
  };
  return [
    for (final option in options)
      if (option.isAll || matched.contains(option.id)) option,
  ];
}

/// @选择器分组字母（拼音；数字/符号归 #）。
String mentionSectionLetter(MentionOption option) => option.isAll
    ? '#'
    : memberSectionLetter(MemberDirectoryEntry(
        userId: option.id,
        nickname: option.nickname,
        remark: option.hasRemark ? option.primaryName : null,
      ));

/// WeChat-style 「选择提醒的人」 panel shown while typing "@" in a group.
final class WeChatMentionPanel extends StatefulWidget {
  const WeChatMentionPanel({
    super.key,
    required this.options,
    required this.canMentionAll,
    required this.onSelect,
    this.height = 264,
    this.avatarBuilder,
  });

  final List<MentionOption> options;
  final bool canMentionAll;
  final ValueChanged<MentionOption> onSelect;
  final double height;
  final Widget Function(BuildContext, MentionOption)? avatarBuilder;

  @override
  State<WeChatMentionPanel> createState() => _WeChatMentionPanelState();
}

final class _WeChatMentionPanelState extends State<WeChatMentionPanel> {
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final members =
        sortMentionOptions(filterMentionOptions(widget.options, search.text));
    return Container(
      key: const Key('mention-panel'),
      height: widget.height,
      color: CupertinoTheme.of(context).barBackgroundColor,
      child: SafeArea(
        top: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: CupertinoTextField(
              key: const Key('mention-search'),
              controller: search,
              placeholder: '搜索',
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 14),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: WeChatColors.chatPageBackground,
                borderRadius: BorderRadius.circular(WeChatRadius.control),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (widget.canMentionAll)
                  _tile(
                    MentionOption.all,
                    key: const Key('mention-option-all'),
                  ),
                for (final option in members)
                  _tile(
                    option,
                    key: Key('mention-option-${option.id}'),
                  ),
                if (members.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        '未找到群成员',
                        style: TextStyle(
                          fontSize: 13,
                          color: WeChatColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _tile(MentionOption option, {required Key key}) {
    final showNickname = !option.isAll && option.hasRemark;
    return CupertinoButton(
      key: key,
      padding: EdgeInsets.zero,
      onPressed: () => widget.onSelect(option),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          if (option.isAll)
            const SizedBox(
                width: 36,
                height: 36,
                child: Icon(CupertinoIcons.person_2_fill,
                    color: WeChatColors.brandPrimary))
          else
            widget.avatarBuilder?.call(context, option) ??
                UserAvatar(
                  nickname: option.primaryName,
                  fallbackSeed: option.id,
                  diagnosticSource: 'mention-picker',
                  size: 36,
                ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  option.primaryName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    color: WeChatColors.resolveTextPrimary(context),
                  ),
                ),
                if (showNickname)
                  Text(
                    '昵称：${option.nickname}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: WeChatColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
