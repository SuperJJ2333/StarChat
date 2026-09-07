import 'package:flutter/cupertino.dart';

import '../../features/matrix/call_controller.dart' show formatCallDuration;
import '../../ui/foundation/changliao_icons.dart';
import 'wechat_message_bubble.dart';

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
    final label = connected ? '通话时长 ${formatCallDuration(duration)}' : '已取消';
    final inheritedForeground = DefaultTextStyle.of(context).style.color;
    final foreground =
        context.findAncestorWidgetOfExactType<WeChatMessageBubble>() != null
            ? inheritedForeground ?? WeChatMessageBubble.foregroundOf(context)
            : WeChatMessageBubble.foregroundOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          ChangliaoIcons.voiceCallFilled,
          size: 18,
          color: foreground,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          key: const Key('call-summary-label'),
          style: TextStyle(
            fontSize: 15,
            color: foreground,
          ),
        ),
      ],
    );
  }
}
