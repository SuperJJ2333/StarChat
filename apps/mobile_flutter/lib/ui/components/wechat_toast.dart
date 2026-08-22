import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

enum WeChatToastSemanticType { success, error, info }

final class WeChatToast extends StatelessWidget {
  const WeChatToast(
      {super.key,
      required this.message,
      this.semanticType = WeChatToastSemanticType.info});
  final String message;
  final WeChatToastSemanticType semanticType;

  @override
  Widget build(BuildContext context) {
    final icon = switch (semanticType) {
      WeChatToastSemanticType.success => CupertinoIcons.check_mark_circled,
      WeChatToastSemanticType.error => CupertinoIcons.exclamationmark_circle,
      WeChatToastSemanticType.info => CupertinoIcons.info_circle,
    };
    return Semantics(
      liveRegion: true,
      label: message,
      child: DecoratedBox(
        decoration: BoxDecoration(
            color: WeChatColors.darkSurface,
            borderRadius: BorderRadius.circular(WeChatRadius.dialog)),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: WeChatSpacing.lg, vertical: WeChatSpacing.md),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                color: WeChatColors.darkTextPrimary,
                size: WeChatTypography.callout),
            const SizedBox(width: WeChatSpacing.sm),
            Text(message,
                style: const TextStyle(
                    color: WeChatColors.darkTextPrimary,
                    fontSize: WeChatTypography.subhead)),
          ]),
        ),
      ),
    );
  }
}
