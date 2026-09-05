import 'package:flutter/cupertino.dart';

import '../components/wechat_list_tile.dart';
import '../foundation/wechat_tokens.dart';

/// 会话通知模式（PRD §44 第一版三态）。
enum ConversationNotificationMode { normal, muted, attention }

/// 会话级通知三态选择：默认 / 静音 / 特别关注（PRD §44）。
/// 静音时仍可在各自的例外设置里允许 @我（既有 MuteException 页）。
final class ConversationNotificationModeTile extends StatelessWidget {
  const ConversationNotificationModeTile({
    super.key,
    required this.muted,
    required this.attention,
    required this.onChanged,
  });

  final bool muted;
  final bool attention;
  final ValueChanged<ConversationNotificationMode> onChanged;

  ConversationNotificationMode get _mode {
    if (muted) return ConversationNotificationMode.muted;
    if (attention) return ConversationNotificationMode.attention;
    return ConversationNotificationMode.normal;
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return Container(
      color: WeChatColors.elevatedSurface(context),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Text(
              '消息通知',
              style: TextStyle(
                fontSize: 13,
                color: dark
                    ? CupertinoColors.systemGrey5
                    : CupertinoColors.systemGrey,
              ),
            ),
          ),
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
