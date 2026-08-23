import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

enum ModernActionKind { primary, secondary, danger }

final class ModernActionButton extends StatefulWidget {
  const ModernActionButton(
      {super.key,
      required this.icon,
      required this.label,
      required this.onPressed,
      this.kind = ModernActionKind.primary,
      this.loading = false});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final ModernActionKind kind;
  final bool loading;
  @override
  State<ModernActionButton> createState() => _ModernActionButtonState();
}

final class _ModernActionButtonState extends State<ModernActionButton> {
  bool pressed = false;
  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final enabled = widget.onPressed != null && !widget.loading;
    final danger = widget.kind == ModernActionKind.danger;
    final foreground = !enabled
        ? WeChatColors.textTertiary
        : danger
            ? WeChatColors.danger
            : WeChatColors.brandPrimary;
    final labelColor = !enabled
        ? WeChatColors.textTertiary
        : danger
            ? foreground
            : WeChatColors.lightTextPrimary;
    final background = widget.kind == ModernActionKind.secondary
        ? CupertinoColors.transparent
        : CupertinoColors.white;
    return Semantics(
        button: true,
        enabled: enabled,
        label: widget.label,
        child: GestureDetector(
          onTapDown: !enabled ? null : (_) => setState(() => pressed = true),
          onTapCancel: () => setState(() => pressed = false),
          onTapUp: !enabled
              ? null
              : (_) {
                  setState(() => pressed = false);
                  widget.onPressed!();
                },
          child: AnimatedScale(
            scale: reduced || !pressed ? 1 : WeChatMotion.actionPressScale,
            duration:
                reduced ? Duration.zero : WeChatMotion.actionPressDuration,
            curve: Curves.easeOut,
            child: Container(
              constraints: const BoxConstraints(
                  minHeight: WeChatDimensions.minimumTouchTarget,
                  minWidth: WeChatDimensions.minimumTouchTarget),
              padding: const EdgeInsets.symmetric(
                  horizontal: WeChatSpacing.actionButtonHorizontal,
                  vertical: WeChatSpacing.actionButtonVertical),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(WeChatRadius.actionButton),
                border: Border.all(color: WeChatColors.controlBorder, width: 1),
                boxShadow: widget.kind == ModernActionKind.secondary
                    ? null
                    : WeChatEffects.actionButtonShadow,
              ),
              child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.loading)
                      CupertinoActivityIndicator(color: foreground)
                    else
                      Icon(
                        widget.icon,
                        color: foreground,
                        size: WeChatTypography.actionButtonIcon,
                      ),
                    const SizedBox(width: WeChatSpacing.actionButtonIconGap),
                    Text(widget.label,
                        style: TextStyle(
                            color: labelColor,
                            fontSize: WeChatTypography.callout)),
                  ]),
            ),
          ),
        ));
  }
}
