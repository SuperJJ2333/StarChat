import 'package:flutter/cupertino.dart';

import '../../features/emoji/fluent_emoji_catalog.dart';
import 'wechat_message_bubble.dart';

/// 超级表情消息（纯动效emoji）：复用 [WeChatMessageBubble] 的消息行布局，
/// 与普通消息一致地展示发送者头像与昵称/备注；表情本体保持微信式无气泡渲染。
///
/// 资产为源分辨率（256px）animated WebP，8-bit 平滑 alpha；渲染尺寸不大于
/// 源分辨率并使用 cubic 采样，任何 DPR 下不再放大位图，避免边缘毛刺。
final class SuperEmojiMessage extends StatelessWidget {
  const SuperEmojiMessage({
    super.key,
    required this.emojis,
    required this.direction,
    this.state = MessageDeliveryState.sent,
    this.avatar,
    this.senderName,
    this.onLongPress,
    this.onAvatarTap,
    this.onAvatarDoubleTap,
    this.onAvatarLongPress,
  });

  /// 单枚表情的展示边长（逻辑像素），与微信大表情尺寸习惯一致。
  static const singleEmojiEdge = 96.0;

  /// 多枚连发表情的展示边长（逻辑像素）。
  static const multiEmojiEdge = 64.0;

  final List<FluentEmoji> emojis;
  final MessageDirection direction;
  final MessageDeliveryState state;
  final Widget? avatar;
  final String? senderName;
  final VoidCallback? onLongPress;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onAvatarDoubleTap;
  final VoidCallback? onAvatarLongPress;

  @override
  Widget build(BuildContext context) {
    final edge =
        emojis.length == 1 ? singleEmojiEdge : multiEmojiEdge;
    return WeChatMessageBubble(
      direction: direction,
      state: state,
      decorateContent: false,
      avatar: avatar,
      senderName: senderName,
      onAvatarTap: onAvatarTap,
      onAvatarDoubleTap: onAvatarDoubleTap,
      onAvatarLongPress: onAvatarLongPress,
      onLongPress: onLongPress,
      content: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final emoji in emojis)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Image.asset(
                  emoji.asset,
                  width: edge,
                  height: edge,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.high,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
