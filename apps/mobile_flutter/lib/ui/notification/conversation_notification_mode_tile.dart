import 'package:flutter/cupertino.dart';

import '../components/wechat_list_tile.dart';
import '../foundation/wechat_tokens.dart';

/// 会话通知模式（PRD §44 第一版三态）。
enum ConversationNotificationMode { normal, muted, attention }

/// The same expandable notification settings in direct and group chats.
final class ConversationNotificationSection extends StatefulWidget {
  const ConversationNotificationSection(
      {super.key,
      required this.muted,
      required this.attention,
      required this.onChanged,
      this.mutedChildren = const <Widget>[]});
  final bool muted;
  final bool attention;
  final ValueChanged<ConversationNotificationMode> onChanged;

  /// 静音时嵌套展示的子选项（由宿主提供，保持控制器写入串行）。
  final List<Widget> mutedChildren;
  @override
  State<ConversationNotificationSection> createState() =>
      _NotificationSectionState();
}

final class _NotificationSectionState
    extends State<ConversationNotificationSection> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) => Column(children: [
        WeChatListTile(
          title: const Text('消息通知'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(
                widget.muted
                    ? '静音'
                    : widget.attention
                        ? '特别关注'
                        : '默认',
                style: const TextStyle(
                    fontSize: 14, color: WeChatColors.textSecondary)),
            const CupertinoListTileChevron(),
          ]),
          onTap: () => setState(() => expanded = !expanded),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: expanded
              ? ConversationNotificationModeTile(
                  muted: widget.muted,
                  attention: widget.attention,
                  mutedChildren: widget.mutedChildren,
                  onChanged: (mode) {
                    // 切到静音时保持展开，让用户直接看到嵌套的
                    // 折叠/仍通知子选项；切走时收起。
                    setState(() =>
                        expanded = mode == ConversationNotificationMode.muted);
                    widget.onChanged(mode);
                  })
              : const SizedBox(width: double.infinity),
        ),
      ]);
}

/// 会话级通知三态选择：默认 / 静音 / 特别关注（PRD §44）。
/// 静音时仍可在各自的例外设置里允许 @我（既有 MuteException 页）。
final class ConversationNotificationModeTile extends StatelessWidget {
  const ConversationNotificationModeTile({
    super.key,
    required this.muted,
    required this.attention,
    required this.onChanged,
    this.mutedChildren = const <Widget>[],
  });

  final bool muted;
  final bool attention;
  final ValueChanged<ConversationNotificationMode> onChanged;

  /// 静音选中时展示的子选项（折叠该聊天 / 以下消息仍通知），
  /// 缩进渲染在「静音」与「特别关注」之间——微信层级。
  final List<Widget> mutedChildren;

  ConversationNotificationMode get _mode {
    if (muted) return ConversationNotificationMode.muted;
    if (attention) return ConversationNotificationMode.attention;
    return ConversationNotificationMode.normal;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: WeChatColors.elevatedSurface(context),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(
            context,
            mode: ConversationNotificationMode.normal,
            title: '默认',
            subtitle: '接收该会话的消息提醒',
          ),
          _row(
            context,
            mode: ConversationNotificationMode.muted,
            title: '静音',
            subtitle: '不响铃不震动，未读仍计数',
          ),
          // 静音子选项（折叠/仍通知）——微信层级：嵌在静音与特别关注之间。
          if (muted && mutedChildren.isNotEmpty) ...mutedChildren,
          _row(
            context,
            mode: ConversationNotificationMode.attention,
            title: '特别关注',
            subtitle: '高优先级提醒，勿扰期间可选允许',
            isLast: true,
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required ConversationNotificationMode mode,
    required String title,
    required String subtitle,
    bool isLast = false,
  }) {
    final selected = _mode == mode;
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        WeChatListTile(
          key: Key('notification-mode-${mode.name}'),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: selected
              ? const Icon(CupertinoIcons.check_mark,
                  size: 18, color: WeChatColors.brandPrimary)
              : null,
          onTap: () => onChanged(mode),
        ),
        if (!isLast)
          Container(
            height: 1,
            margin: const EdgeInsets.only(left: 16),
            color: dark ? WeChatColors.darkDivider : WeChatColors.divider,
          ),
      ],
    );
  }
}
