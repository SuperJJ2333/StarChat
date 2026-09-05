import 'package:flutter/cupertino.dart';

import '../../features/matrix/call_controller.dart'
    show formatCallDuration;
import '../../ui/foundation/changliao_icons.dart';

/// 通话摘要气泡：会话内“通话时长 mm:ss / 已取消”行（微信式，电话 icon）。
/// 外层气泡底衬由 WeChatMessageBubble 提供。
final class WeChatCallBubble extends StatelessWidget {
  const WeChatCallBubble({
    super.key,
    required this.video,
    required this.connected,
    required this.duration,
  });

  final bool video;
  final bool connected;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final label =
        connected ? '通话时长 ${formatCallDuration(duration)}' : '已取消';
    // 文字/图标用黑色（#000000），与普通文字消息气泡一致（气泡底色为
    // 浅绿/白色，白字对比度不足且与文字消息不统一）。
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          ChangliaoIcons.voiceCallFilled,
          size: 18,
          color: CupertinoColors.black,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          key: const Key('call-summary-label'),
          style: const TextStyle(
            fontSize: 15,
            color: CupertinoColors.black,
          ),
        ),
      ],
    );
  }
}
