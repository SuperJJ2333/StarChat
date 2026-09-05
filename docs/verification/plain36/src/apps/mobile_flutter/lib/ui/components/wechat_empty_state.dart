import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

final class WeChatEmptyState extends StatelessWidget {
  const WeChatEmptyState(
      {super.key,
      required this.title,
      this.description,
      this.actionLabel,
      this.onAction,
      this.icon = CupertinoIcons.tray});
  final String title;
  final String? description;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        label: title,
        child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: WeChatDimensions.callControl,
              color: WeChatColors.textTertiary),
          const SizedBox(height: WeChatSpacing.md),
          Text(title,
              style: const TextStyle(
                  fontSize: WeChatTypography.callout,
                  fontWeight: FontWeight.w600)),
          if (description case final value?) ...[
            const SizedBox(height: WeChatSpacing.xs),
            Text(value,
                style: const TextStyle(
                    color: WeChatColors.textSecondary,
                    fontSize: WeChatTypography.subhead)),
          ],
          if (actionLabel != null && onAction != null)
            CupertinoButton(onPressed: onAction, child: Text(actionLabel!)),
        ])),
      );
}
