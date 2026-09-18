import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

/// 共享渐变分割线：列表行之间、列表与卡片之间，以及卡片内部相邻区块之间的
/// 水平 1 逻辑像素分隔线（规范见 `UI_DESIGN.md` §19）。
///
/// 全仓只有这一份实现（朋友圈时间线、朋友圈互动面板、朋友圈可见范围页、好友
/// 列表、通讯录入口行、请求行等共用）：同高、同宽、同色源
/// `WeChatColors.divider`，两端通过 [LinearGradient] 渐隐到完全透明，中段
/// alpha 0.5，让列表单元之间只保留极轻的分隔感。
///
/// 深浅色在 build 时由 [WeChatColors.resolve] 解析（浅色 `#D9D9D9`、
/// 深色 `#2C2C2C`），组件内没有任何硬编码颜色。业务页面必须通过本组件画
/// 列表/卡片分割线，不得自行拼 `Container` + `Border(bottom:)` 或
/// `ColoredBox(height: 1)`。
final class WeChatGradientDivider extends StatelessWidget {
  const WeChatGradientDivider({
    super.key,
    this.height = WeChatDividerTokens.hairline,
    this.indent = 0,
    this.endIndent = 0,
  });

  /// 分割线高度，默认 1 逻辑像素。
  final double height;

  /// 左缩进；默认 0（整行宽，与朋友圈分割线一致）。
  final double indent;

  /// 右缩进；默认 0。
  final double endIndent;

  @override
  Widget build(BuildContext context) {
    final base = WeChatColors.resolve(context, WeChatColors.divider);
    final core = base.withValues(alpha: WeChatDividerTokens.centerAlpha);
    final edge = base.withValues(alpha: WeChatDividerTokens.edgeAlpha);
    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent, end: endIndent),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [edge, core, core, edge],
            stops: const [
              WeChatDividerTokens.edgeStartStop,
              WeChatDividerTokens.coreStart,
              WeChatDividerTokens.coreEnd,
              WeChatDividerTokens.edgeEndStop,
            ],
          ),
        ),
        child: SizedBox(height: height, width: double.infinity),
      ),
    );
  }
}
