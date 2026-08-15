import 'package:flutter/cupertino.dart';

enum ModernActionKind { primary, secondary, danger }

final class ModernActionButton extends StatefulWidget {
  const ModernActionButton({super.key, required this.icon, required this.label, required this.onPressed, this.kind = ModernActionKind.primary, this.loading = false});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final ModernActionKind kind;
  final bool loading;
  @override State<ModernActionButton> createState() => _ModernActionButtonState();
}

final class _ModernActionButtonState extends State<ModernActionButton> {
  bool pressed = false;
  @override Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final danger = widget.kind == ModernActionKind.danger;
    final foreground = danger ? CupertinoColors.systemRed : const Color(0xff07c160);
    final background = widget.kind == ModernActionKind.secondary ? CupertinoColors.transparent : CupertinoColors.white;
    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        onTapDown: widget.onPressed == null ? null : (_) => setState(() => pressed = true),
        onTapCancel: () => setState(() => pressed = false),
        onTapUp: widget.onPressed == null ? null : (_) { setState(() => pressed = false); widget.onPressed!(); },
        child: AnimatedScale(
          scale: reduced || !pressed ? 1 : .98,
          duration: reduced ? Duration.zero : const Duration(milliseconds: 100),
          curve: Curves.easeOut,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xffd9d9d9), width: 1),
              boxShadow: widget.kind == ModernActionKind.secondary ? null : const [BoxShadow(color: Color(0x1f000000), blurRadius: 8, offset: Offset(0, 2))],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              if (widget.loading) CupertinoActivityIndicator(color: foreground) else Icon(widget.icon, color: foreground, size: 20),
              const SizedBox(width: 8),
              Text(widget.label, style: TextStyle(color: danger ? foreground : const Color(0xff191919), fontSize: 16)),
            ]),
          ),
        ),
      ),
    );
  }
}
