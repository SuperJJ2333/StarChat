import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

/// A compact contextual menu, constrained to the safe visible screen.
Future<void> showMomentActionMenu(
  BuildContext context, {
  required Offset position,
  required String text,
  VoidCallback? onDelete,
}) async {
  final media = MediaQuery.of(context);
  final width = onDelete == null ? 88.0 : 176.0;
  const height = 68.0;
  final left =
      (position.dx - width / 2).clamp(12.0, media.size.width - width - 12.0);
  final preferredTop = position.dy - height - 12;
  final top =
      (preferredTop < media.padding.top + 8 ? position.dy + 12 : preferredTop)
          .clamp(media.padding.top + 8,
              media.size.height - media.padding.bottom - height - 8);
  final action = await showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭操作菜单',
    barrierColor: const Color(0x11000000),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (menuContext, _, __) => Stack(children: [
      Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
                color: const Color(0xff333333),
                borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              _Action(
                  label: '复制',
                  icon: CupertinoIcons.doc_on_doc,
                  onTap: () => Navigator.pop(menuContext, 'copy')),
              if (onDelete != null)
                _Action(
                    label: '删除',
                    icon: CupertinoIcons.delete,
                    onTap: () => Navigator.pop(menuContext, 'delete')),
            ]),
          )),
    ]),
  );
  if (!context.mounted) return;
  if (action == 'delete') onDelete?.call();
  if (action == 'copy') {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      if (!context.mounted) return;
      await showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
                title: const Text('复制失败'),
                content: const Text('请重试'),
                actions: [
                  CupertinoDialogAction(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('好'))
                ],
              ));
    }
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.label, required this.icon, required this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Expanded(
          child: CupertinoButton(
        padding: const EdgeInsets.symmetric(vertical: 9),
        onPressed: onTap,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: CupertinoColors.white, size: 22),
          const SizedBox(height: 4),
          Text(label,
              style:
                  const TextStyle(color: CupertinoColors.white, fontSize: 13)),
        ]),
      ));
}
