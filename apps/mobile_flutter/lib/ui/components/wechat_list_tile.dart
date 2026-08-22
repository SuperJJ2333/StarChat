import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

final class WeChatListTile extends StatefulWidget {
  const WeChatListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  State<WeChatListTile> createState() => _WeChatListTileState();
}

final class _WeChatListTileState extends State<WeChatListTile> {
  bool pressed = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown:
            widget.onTap == null ? null : (_) => setState(() => pressed = true),
        onTapUp: widget.onTap == null
            ? null
            : (_) => setState(() => pressed = false),
        onTapCancel:
            widget.onTap == null ? null : () => setState(() => pressed = false),
        onTap: widget.onTap,
        child: ColoredBox(
          key: const Key('wechat-list-elevated-surface'),
          color: pressed
              ? WeChatColors.elevatedSurface(context).withValues(alpha: .72)
              : WeChatColors.elevatedSurface(context),
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.lg),
            child: CupertinoListTile(
              padding: EdgeInsets.zero,
              title: widget.title,
              subtitle: widget.subtitle,
              leading: widget.leading,
              trailing: widget.trailing,
              onTap: null,
            ),
          ),
        ),
      );
}
