import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';
import 'wechat_gradient_divider.dart';

/// 统一列表单元：`surfaceElevated` 背景 + 垂直居中的 leading / title / subtitle。
///
/// 实现说明：不再委托 `CupertinoListTile`。后者的 content `Column` 使用
/// `MainAxisAlignment.spaceBetween`，在固定高度的行里会把单行标题推到行顶、
/// 把 title/subtitle 分别顶到上下两边（通讯录入口「新的朋友 / 群聊 / 标签」
/// 与「新的朋友」请求行错位的根因），并且会用 28dp 的 leading 盒子压缩
/// 40dp 头像。这里改为显式 `Row` + `mainAxisSize.min` 的 `Column`，
/// 让任意行高下 leading 与文案都按同一垂直中心对齐。
final class WeChatListTile extends StatefulWidget {
  const WeChatListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.showDivider = false,
    this.leadingSize = 28,
    this.leadingToTitle = WeChatSpacing.lg,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 是否在行底部画共享渐隐分割线（与好友行全局统一）。默认关闭，
  /// 只有需要行间分隔的列表显式开启。
  final bool showDivider;

  /// leading 占位盒边长（默认 28，与 iOS 设置列表一致）。头像类 leading
  /// 传 `WeChatDimensions.contactAvatar`，避免被占位盒压扁。
  final double leadingSize;

  /// leading 与文案的水平间距。
  final double leadingToTitle;

  @override
  State<WeChatListTile> createState() => _WeChatListTileState();
}

final class _WeChatListTileState extends State<WeChatListTile> {
  bool pressed = false;

  @override
  Widget build(BuildContext context) {
    final surface = WeChatColors.elevatedSurface(context);
    final textStyle = CupertinoTheme.of(context).textTheme.textStyle;
    final subtitleStyle = textStyle.copyWith(
      color: CupertinoColors.secondaryLabel.resolveFrom(context),
      fontSize: WeChatTypography.caption,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown:
          widget.onTap == null ? null : (_) => setState(() => pressed = true),
      onTapUp: widget.onTap == null
          ? null
          : (_) => setState(() => pressed = false),
      onTapCancel:
          widget.onTap == null ? null : () => setState(() => pressed = false),
      onTap: widget.onTap,
      child: ColoredBox(
        key: const Key('wechat-list-elevated-surface'),
        color: pressed ? surface.withValues(alpha: .72) : surface,
        // Stack 让行高完全由父级决定（通讯录入口行 56dp、请求行 68dp），
        // 内容始终垂直居中，分割线固定在行底且不额外占高。
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding:
                  const EdgeInsets.symmetric(horizontal: WeChatSpacing.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (widget.leading case final Widget leading) ...[
                    SizedBox.square(
                      dimension: widget.leadingSize,
                      child: Center(child: leading),
                    ),
                    SizedBox(width: widget.leadingToTitle),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DefaultTextStyle(
                          style: textStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          child: widget.title,
                        ),
                        if (widget.subtitle case final Widget subtitle) ...[
                          const SizedBox(height: WeChatSpacing.xs / 2),
                          DefaultTextStyle(
                            style: subtitleStyle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            child: subtitle,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (widget.trailing case final Widget trailing) ...[
                    const SizedBox(width: WeChatSpacing.sm),
                    trailing,
                  ],
                ],
              ),
            ),
            if (widget.showDivider)
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: WeChatGradientDivider(
                  key: Key('wechat-list-divider'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
