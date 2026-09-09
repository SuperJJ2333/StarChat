import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'anchored_action_menu.dart';

abstract final class TopMoreMenuTokens {
  static const width = 208.0;
  static const rowHeight = 52.0;
  static const divider = Color(0x3DFFFFFF);
}

/// The three main tabs share this fixed ordered, vertical action surface.
Future<void> showTopMoreMenu(
  BuildContext context, {
  required VoidCallback onCreateGroup,
  required VoidCallback onAddFriend,
  required VoidCallback onScan,
  required VoidCallback onAppearance,
  Rect? anchor,
  Key? appearanceKey,
}) async {
  final media = MediaQuery.of(context);
  final items = [
    AnchoredMenuItem(
        value: onCreateGroup,
        icon: CupertinoIcons.group_solid,
        label: '发起群聊',
        key: const Key('top-more-group')),
    AnchoredMenuItem(
        value: onAddFriend,
        icon: CupertinoIcons.person_add_solid,
        label: '添加朋友',
        key: const Key('top-more-add')),
    AnchoredMenuItem(
        value: onScan,
        icon: CupertinoIcons.qrcode_viewfinder,
        label: '扫一扫',
        key: const Key('top-more-scan')),
    AnchoredMenuItem(
        value: onAppearance,
        icon: CupertinoIcons.circle_lefthalf_fill,
        label: '外观',
        key: appearanceKey ?? const Key('top-more-appearance')),
  ];
  final selected = await showGeneralDialog<VoidCallback>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: const Color(0x1A000000),
    transitionDuration:
        media.disableAnimations ? Duration.zero : AnchoredMenuTokens.motion,
    transitionBuilder: (context, animation, _, child) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
            alignment: Alignment.topRight,
            scale: Tween<double>(begin: .96, end: 1).animate(animation),
            child: child)),
    pageBuilder: (menuContext, _, __) =>
        SafeArea(child: LayoutBuilder(builder: (context, constraints) {
      final top =
          ((anchor?.bottom ?? media.padding.top + 44) - media.padding.top + 8)
              .clamp(8.0, math.max(8.0, constraints.maxHeight - 64))
              .toDouble();
      return Stack(children: [
        Positioned(
            top: top,
            right: 12,
            width: math.min(TopMoreMenuTokens.width, constraints.maxWidth - 24),
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: math.max(
                        44,
                        constraints.maxHeight -
                            top -
                            12 -
                            media.viewInsets.bottom)),
                child: ClipRRect(
                    borderRadius:
                        BorderRadius.circular(AnchoredMenuTokens.radius),
                    child: ColoredBox(
                        key: const Key('top-more-menu'),
                        color: AnchoredMenuTokens.background,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              for (var i = 0; i < items.length; i++) ...[
                                if (i > 0)
                                  Container(
                                      key: Key('top-more-divider-${i - 1}'),
                                      height: .5,
                                      margin: const EdgeInsets.only(
                                          left: 48, right: 12),
                                      color: TopMoreMenuTokens.divider),
                                ConstrainedBox(
                                    constraints: const BoxConstraints(
                                        minHeight: TopMoreMenuTokens.rowHeight),
                                    child: CupertinoButton(
                                        key: items[i].key,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 12),
                                        onPressed: () => Navigator.pop(
                                            menuContext, items[i].value),
                                        child: Row(children: [
                                          Icon(items[i].icon,
                                              size: 20,
                                              color: CupertinoColors.white),
                                          const SizedBox(width: 12),
                                          Expanded(
                                              child: Text(items[i].label,
                                                  style: const TextStyle(
                                                      color:
                                                          CupertinoColors.white,
                                                      fontSize: 16))),
                                        ]))),
                              ],
                            ]))))))
      ]);
    })),
  );
  if (context.mounted) selected?.call();
}
