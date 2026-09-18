import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

/// 通讯录右侧字母索引（★ A-Z #）。
///
/// 设计契约：`frontend/src/styles/components.css` 的 `.c-contact-index`
/// 宽度固定 20pt、每个字母固定 18pt 高并整体垂直居中，字母**不随可视高度
/// 拉伸**。旧实现用 `Expanded` 把 28 个字母撑满整列，字母间距随屏幕变大，
/// 顶部字母贴到导航栏下方、底部贴到底栏，与微信布局不符（BUG-03）。
///
/// 本组件自身不产生任何滚动/定位副作用：外层的 Stack + Transform 由调用方
/// 负责（保持下拉回弹时索引跟随列表表面的既有行为）。
final class WeChatContactIndex extends StatefulWidget {
  const WeChatContactIndex(
      {super.key, required this.labels, required this.onSelected});
  final List<String> labels;
  final ValueChanged<String> onSelected;

  @override
  State<WeChatContactIndex> createState() => _WeChatContactIndexState();
}

/// 索引块上下留白：确保永远不贴住导航栏 / 底部安全区。
const _verticalBreathing = 12.0;

final class _WeChatContactIndexState extends State<WeChatContactIndex> {
  String? selected;

  void _select(String label) {
    setState(() => selected = label);
    widget.onSelected(label);
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => selected = null);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final labels = widget.labels;
          if (labels.isEmpty) return const SizedBox.shrink();
          final available = constraints.hasBoundedHeight
              ? math.max(0.0, constraints.maxHeight - _verticalBreathing * 2)
              : labels.length * WeChatDimensions.contactIndexLetterHeight;
          // 正常屏幕上就是设计值 18pt；只有极小窗口（横屏/分屏）才按可用
          // 高度等比压缩，避免溢出，且不会把字母拉大到超出设计。
          final letterHeight = math.min(
              WeChatDimensions.contactIndexLetterHeight,
              available / labels.length);
          return Stack(
            alignment: Alignment.center,
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: _verticalBreathing),
                  child: SizedBox(
                    width: WeChatDimensions.contactIndexWidth,
                    child: ColoredBox(
                      key: const Key('contact-index'),
                      color: WeChatColors.elevatedSurface(context),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final label in labels)
                            SizedBox(
                                height: letterHeight, child: _letter(label)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (selected case final label?)
                DecoratedBox(
                  key: const Key('contact-index-feedback'),
                  decoration: BoxDecoration(
                    color: WeChatColors.darkSurface,
                    borderRadius: BorderRadius.circular(WeChatRadius.dialog),
                  ),
                  child: SizedBox.square(
                    dimension: WeChatDimensions.contactIndexFeedback,
                    child: Center(
                      child: Text(label,
                          style: const TextStyle(
                              color: WeChatColors.darkTextPrimary,
                              fontSize: WeChatTypography.title1)),
                    ),
                  ),
                ),
            ],
          );
        },
      );

  Widget _letter(String label) => CupertinoButton(
        minimumSize: Size.zero,
        padding: EdgeInsets.zero,
        onPressed: () => _select(label),
        child: Text(label,
            style: const TextStyle(
                color: WeChatColors.textSecondary,
                fontSize: WeChatTypography.badge)),
      );
}
