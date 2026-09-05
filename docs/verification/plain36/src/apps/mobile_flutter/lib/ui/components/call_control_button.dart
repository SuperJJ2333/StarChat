import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

enum CallControlKind { normal, danger, accept }

final class CallControlButton extends StatelessWidget {
  const CallControlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.kind = CallControlKind.normal,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final CallControlKind kind;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final foreground = switch (kind) {
      CallControlKind.danger => WeChatColors.danger,
      CallControlKind.accept => CupertinoColors.white,
      CallControlKind.normal =>
        selected ? CupertinoColors.white : WeChatColors.brandPrimary,
    };
    final background = switch (kind) {
      CallControlKind.accept => WeChatColors.brandPrimary,
      CallControlKind.normal when selected => WeChatColors.brandPrimary,
      _ => CupertinoColors.white,
    };
    return Semantics(
      button: true,
      label: label,
      selected: selected,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: WeChatDimensions.callControl,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(WeChatDimensions.callControl),
          color: background,
          onPressed: onPressed,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: foreground, size: 22),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                style: TextStyle(color: foreground, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
