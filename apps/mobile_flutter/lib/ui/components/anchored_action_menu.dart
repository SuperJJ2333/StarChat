import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import '../chat/message_menu_placement.dart';

final class AnchoredMenuItem<T> {
  const AnchoredMenuItem(
      {required this.value, required this.icon, required this.label, this.key});
  final T value;
  final IconData icon;
  final String label;
  final Key? key;
}

abstract final class AnchoredMenuTokens {
  static const width = 272.0;
  static const radius = 8.0;
  static const background = Color(0xE64C4C4C);
  static const motion = Duration(milliseconds: 120);
}

final class WeChatAnchoredActionMenu<T> extends StatelessWidget {
  const WeChatAnchoredActionMenu(
      {super.key,
      required this.items,
      required this.onSelected,
      this.arrowAtTop = false,
      this.arrowX});
  final List<AnchoredMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final bool arrowAtTop;
  final double? arrowX;
  @override
  Widget build(BuildContext context) {
    final ordered = items;
    // 每行最多 4 项（微信式），超出换行。
    final rows = <List<AnchoredMenuItem<T>>>[];
    for (var i = 0; i < ordered.length; i += 4) {
      rows.add(ordered.sublist(i, (i + 4).clamp(0, ordered.length)));
    }
    return Container(
      width: AnchoredMenuTokens.width,
      key: const Key('anchored-action-menu'),
      // 底部小三角凸起允许溢出绘制，指向目标气泡。
      clipBehavior: Clip.none,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: AnchoredMenuTokens.background,
        borderRadius: BorderRadius.circular(AnchoredMenuTokens.radius),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var r = 0; r < rows.length; r++) ...[
                if (r > 0)
                  Container(
                    height: .5,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    color: CupertinoColors.white.withValues(alpha: .24),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (var c = 0; c < 4; c++)
                      Expanded(
                          child: c >= rows[r].length
                              ? const SizedBox()
                              : _MenuItem(
                                  item: rows[r][c],
                                  onPressed: () => onSelected(rows[r][c].value),
                                )),
                  ],
                ),
                if (r < rows.length - 1) const SizedBox(height: 4),
              ],
            ],
          ),
          // 下边框中央的小三角凸起：指向对应的气泡（视觉引导）。
          Positioned(
            left: arrowX == null ? 0 : arrowX! - 11,
            right: arrowX == null ? 0 : null,
            top: arrowAtTop ? -9 : null,
            bottom: arrowAtTop ? null : -5,
            child: Center(
              child: Transform.rotate(
                angle: math.pi / 4,
                child: Container(
                  width: 11,
                  height: 11,
                  color: AnchoredMenuTokens.background,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _MenuItem<T> extends StatelessWidget {
  const _MenuItem({
    required this.item,
    required this.onPressed,
  });

  final AnchoredMenuItem<T> item;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final icon = item.icon;
    final label = item.label;
    return Semantics(
      button: true,
      label: label,
      child: CupertinoButton(
        key: item.key,
        // 最小宽度 32（原 64）：四项行宽约减半（需求 4a），
        // 实际宽度由图标/标签内容自然撑开。
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        onPressed: onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: CupertinoColors.white),
            const SizedBox(height: 3),
            Text(
              label,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 11, color: CupertinoColors.white),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared anchored presentation, including the original message-menu motion.
Future<T?> showAnchoredActionMenu<T>(
  BuildContext context, {
  required List<AnchoredMenuItem<T>> items,
  Rect? anchor,
}) {
  if (items.isEmpty) return Future.value();
  final media = MediaQuery.of(context);
  final target =
      anchor ?? Rect.fromLTWH(media.size.width - 52, media.padding.top, 44, 44);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: const Color(0x1A000000),
    transitionDuration:
        media.disableAnimations ? Duration.zero : AnchoredMenuTokens.motion,
    transitionBuilder: (_, __, ___, child) => child,
    pageBuilder: (menuContext, _, __) =>
        LayoutBuilder(builder: (context, constraints) {
      final viewport = Rect.fromLTRB(
          8,
          media.padding.top + 8,
          constraints.maxWidth - 8,
          constraints.maxHeight -
              math.max(media.padding.bottom, media.viewInsets.bottom) -
              8);
      final width = math.min(AnchoredMenuTokens.width, viewport.width);
      double height = 20;
      for (var i = 0; i < items.length; i += 4) {
        double rowHeight = 44;
        for (final item in items.skip(i).take(4)) {
          final painter = TextPainter(
              text: TextSpan(
                  text: item.label, style: const TextStyle(fontSize: 11)),
              textDirection: Directionality.of(context),
              textScaler: media.textScaler)
            ..layout(maxWidth: math.max(1, (width - 12) / 4 - 8));
          rowHeight = math.max(rowHeight, painter.height + 31);
        }
        height += rowHeight + (i == 0 ? 0 : 4.5);
      }
      final placement = MessageMenuPlacement.calculate(
          anchor: target,
          viewport: viewport,
          menuSize: Size(width, height),
          outgoing: true);
      return Stack(children: [
        Positioned.fromRect(
            rect: placement.rect,
            child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: media.disableAnimations
                    ? Duration.zero
                    : AnchoredMenuTokens.motion,
                builder: (_, value, child) => Opacity(
                    opacity: value,
                    child: Transform.scale(
                        scale: .96 + .04 * value, child: child)),
                child: SingleChildScrollView(
                    child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: WeChatAnchoredActionMenu<T>(
                            items: items,
                            arrowAtTop: placement.arrowAtTop,
                            arrowX: placement.arrowX,
                            onSelected: (value) =>
                                Navigator.pop(menuContext, value))))))
      ]);
    }),
  );
}

Future<void> showAnchoredCallbackMenu(
  BuildContext context, {
  required List<AnchoredMenuItem<VoidCallback>> items,
  Rect? anchor,
}) async {
  final action = await showAnchoredActionMenu<VoidCallback>(context,
      items: items, anchor: anchor);
  if (context.mounted) action?.call();
}
