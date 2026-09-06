import 'package:flutter/cupertino.dart';

import '../../features/matrix/unread_mention_tracker.dart';
import '../foundation/wechat_tokens.dart';

/// 规格 #2 UI：会话摘要的 [有人@你] 红色前缀（独立文本片段，不替换/
/// 覆盖原摘要）+ 群聊右上角固定的 ↑有人@你 提示标签。
///
/// 用法：
/// - 会话列表摘要行：`ConversationSummaryWithMention(...)`；
/// - 群聊页导航栏：`MentionBannerButton(onTap: ...)` 固定右上角。

/// 会话摘要行：红色 `[有人@你]` + 原摘要（可正常省略截断）。
final class ConversationSummaryWithMention extends StatelessWidget {
  const ConversationSummaryWithMention({
    super.key,
    required this.hasPendingMention,
    required this.summary,
    this.maxLines = 1,
    this.style,
  });

  final bool hasPendingMention;
  final String summary;
  final int maxLines;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (!hasPendingMention) {
      return Text(summary,
          key: const Key('conversation-summary-plain'),
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: style);
    }
    final (prefix, rest) = mentionPrefixForSummary(
      hasPendingMention: true,
      originalSummary: summary,
    );
    return Text.rich(
      key: const Key('conversation-summary-mention'),
      TextSpan(
        children: [
          // 独立红色片段（#FF0000），规格明确色值。
          TextSpan(
            text: prefix,
            style: (style ?? const TextStyle())
                .copyWith(color: const Color(0xFFFF0000)),
          ),
          TextSpan(text: rest, style: style),
        ],
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 群聊页右上角固定提示标签：↑ 有人@你（导航按钮之下、安全区之内）。
final class MentionBannerButton extends StatelessWidget {
  const MentionBannerButton({
    super.key,
    required this.onTap,
    this.isLoading = false,
  });

  /// 点击 → 逐条跳转最新的未查看提及。
  final VoidCallback onTap;

  /// 历史提及正在解析时显示加载状态（不能提前判定清空——规格 #2）。
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      key: const Key('mention-banner-button'),
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
            if (isLoading)
              const CupertinoActivityIndicator(radius: 6)
            else
              const Icon(CupertinoIcons.arrow_up, size: 12,
                  color: WeChatColors.brandPrimary),
            const SizedBox(width: 3),
            const Text('有人@你',
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

/// 定位失败提示（跳转不消费记录——规格 #2）。
void showMentionJumpFailedToast(BuildContext context) {
  // 轻提示：不阻断页面；记录保留供重试。
  // 用 Overlay 展示 2 秒自动消失的浮层。
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      bottom: 120,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text('定位失败，请重试',
              style: TextStyle(fontSize: 13, color: CupertinoColors.white)),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future<void>.delayed(const Duration(seconds: 2))
      .then((_) => entry.remove())
      .catchError((_) {});
}
