import 'package:flutter/cupertino.dart';

import 'theme_controller.dart';

Future<void> showThemePickerSheet(
  BuildContext context,
  ThemeController controller,
) {
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (context) => ThemePickerSheet(controller: controller),
  );
}

final class ThemePickerSheet extends StatelessWidget {
  const ThemePickerSheet({super.key, required this.controller});

  final ThemeController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => CupertinoActionSheet(
          title: const Text('外观'),
          message: const Text('主题设置仅保存在当前设备'),
          actions: [
            _option(context, ThemePreference.system, '跟随系统'),
            _option(context, ThemePreference.light, '浅色模式'),
            _option(context, ThemePreference.dark, '深色模式'),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
      );

  Widget _option(
    BuildContext context,
    ThemePreference preference,
    String label,
  ) {
    final selected = controller.preference == preference;
    return CupertinoActionSheetAction(
      key: ValueKey<String>('theme-${preference.name}'),
      onPressed: () async {
        await controller.setPreference(preference);
        if (!context.mounted) return;
        if (controller.errorMessage == null) {
          Navigator.pop(context);
          return;
        }
        final message = controller.errorMessage!;
        controller.clearError();
        await showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('无法保存主题'),
            content: Text(message),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label),
          const SizedBox(width: 8),
          SizedBox(
            width: 18,
            child: selected
                ? const Icon(CupertinoIcons.check_mark, size: 18)
                : null,
          ),
        ],
      ),
    );
  }
}
