import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

/// “回到引用位置”弹窗（规格 #4）：跳转到被引用消息后出现在屏幕右下方，
/// 点击返回发起引用的消息并高亮。
///
/// 样式与“@提醒弹窗”（conversation_mention_banner.dart 的
/// [MentionBannerButton]）完全一致：同尺寸、圆角 12、背景
/// brandPrimary 12% 透明度、同图标/字号/字重/边距；仅方向箭头按
/// 返回语义取向下，文字为“回到引用位置”。
final class QuoteReturnBannerButton extends StatelessWidget {
  const QuoteReturnBannerButton({
    super.key,
    required this.onTap,
  });

  /// 点击 → 返回引用发起消息的位置并高亮，弹窗随即消失。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      key: const Key('quote-return-banner'),
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: WeChatColors.brandPrimary.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(CupertinoIcons.arrow_down,
                size: 12, color: WeChatColors.brandPrimary),
            const SizedBox(width: 3),
            const Text('回到引用位置',
                style: TextStyle(
                    fontSize: 12,
                    color: WeChatColors.brandPrimary,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
