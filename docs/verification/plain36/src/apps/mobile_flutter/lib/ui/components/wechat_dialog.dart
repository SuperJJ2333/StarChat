import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

final class WeChatDialogAction {
  const WeChatDialogAction({
    required this.label,
    required this.onPressed,
    this.isDestructive = false,
  });
  final String label;
  final VoidCallback onPressed;
  final bool isDestructive;
}

final class WeChatDialog extends StatelessWidget {
  const WeChatDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.semanticType = WeChatDialogSemanticType.confirmation,
  });
  final String title;
  final Widget content;
  final List<WeChatDialogAction> actions;
  final WeChatDialogSemanticType semanticType;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        label:
            semanticType == WeChatDialogSemanticType.error ? '错误提示' : '确认对话框',
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: WeChatColors.elevatedSurface(context),
            borderRadius: BorderRadius.circular(WeChatRadius.dialog),
          ),
          child: Padding(
            padding: const EdgeInsets.all(WeChatSpacing.lg),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: WeChatTypography.title2,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: WeChatSpacing.sm),
              content,
              const SizedBox(height: WeChatSpacing.lg),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                for (final action in actions)
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(
                        horizontal: WeChatSpacing.md),
                    onPressed: action.onPressed,
                    child: Text(action.label,
                        style: TextStyle(
                            color: action.isDestructive
                                ? WeChatColors.danger
                                : WeChatColors.brandPrimary)),
                  ),
              ]),
            ]),
          ),
        ),
      );
}

enum WeChatDialogSemanticType { confirmation, error, detail }
