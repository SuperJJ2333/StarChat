import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

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

/// A-Z grouping identical to the contacts page: entries sort by the first
/// character of their primary (remark-first) name; non-Latin initials share
/// the trailing `#` bucket because the project carries no pinyin dependency.
int _initialBucket(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 26;
  final codeUnit = trimmed.characters.first.toUpperCase().codeUnitAt(0);
  if (codeUnit >= 0x41 && codeUnit <= 0x5A) return codeUnit - 0x41;
  return 26; // '#' bucket, sorted after Z.
}

String _initialLetter(String name) {
  final bucket = _initialBucket(name);
  return bucket == 26 ? '#' : String.fromCharCode(0x41 + bucket);
}

/// Sorts A-Z by the remark/nickname initial, `#` bucket last, then by name.
List<MentionOption> sortMentionOptions(List<MentionOption> options) {
  final sorted = [...options]..sort((a, b) {
      final bucket = _initialBucket(a.primaryName) - _initialBucket(b.primaryName);
      if (bucket != 0) return bucket;
      return a.primaryName.toLowerCase().compareTo(b.primaryName.toLowerCase());
    });
  return sorted;
}

/// Filters by the remark/nickname primary name AND the plain nickname.
List<MentionOption> filterMentionOptions(
  List<MentionOption> options,
  String query,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return options;
  return options
      .where((option) =>
          option.primaryName.toLowerCase().contains(needle) ||
          option.nickname.toLowerCase().contains(needle))
      .toList(growable: false);
}

String mentionSectionLetter(MentionOption option) =>
    _initialLetter(option.primaryName);

/// WeChat-style 「选择提醒的人」 panel shown while typing "@" in a group.
final class WeChatMentionPanel extends StatefulWidget {
  const WeChatMentionPanel({
    super.key,
    required this.options,
    required this.canMentionAll,
    required this.onSelect,
    this.height = 264,
  });

  final List<MentionOption> options;
  final bool canMentionAll;
  final ValueChanged<MentionOption> onSelect;
  final double height;

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
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: WeChatColors.avatarFallbackBlue,
              shape: BoxShape.circle,
            ),
            child: Text(
              option.primaryName.isEmpty
                  ? '?'
                  : option.primaryName.characters.first,
              style: const TextStyle(fontSize: 14),
            ),
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
