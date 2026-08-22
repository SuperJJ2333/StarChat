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
            ? CupertinoColors.systemRed
            : WeChatColors.brandPrimary;
    final labelColor = !enabled
        ? WeChatColors.textTertiary
        : danger
            ? foreground
            : const Color(0xff191919);
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
          scale: reduced || !pressed ? 1 : .98,
          duration: reduced ? Duration.zero : const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xffd9d9d9), width: 1),
              boxShadow: widget.kind == ModernActionKind.secondary
                  ? null
                  : const [
                      BoxShadow(
                          color: Color(0x1f000000),
                          blurRadius: 8,
                          offset: Offset(0, 2))
                    ],
            ),
            child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.loading)
                    CupertinoActivityIndicator(color: foreground)
                  else
                    Icon(widget.icon, color: foreground, size: 20),
                  const SizedBox(width: 8),
                  Text(widget.label,
                      style: TextStyle(color: labelColor, fontSize: 16)),
                ]),
          ),
        ),
      ),
    );
  }
}
