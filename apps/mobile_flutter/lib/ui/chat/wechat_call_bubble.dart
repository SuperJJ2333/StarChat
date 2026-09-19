import 'package:flutter/cupertino.dart';

import '../../features/matrix/call_controller.dart' show formatCallDuration;
import '../../ui/foundation/changliao_icons.dart';
import 'wechat_message_bubble.dart';

/// 通话摘要气泡：会话内“通话时长 mm:ss / 已取消”行（微信式，电话 icon）。
/// 外层气泡底衬由 WeChatMessageBubble 提供。
///
/// BUG-14：①图标与文案必须区分语音/视频通话；②点击气泡直接按原类型
/// 再次拨打（[onRedial] 由会话页按对端与类型注入；群聊等无固定对端时
/// 为 null，点击不动作）。
final class WeChatCallBubble extends StatelessWidget {
  const WeChatCallBubble({
    super.key,
    required this.video,
    required this.connected,
    required this.duration,
    this.onRedial,
  });

  final bool video;
  final bool connected;
  final Duration duration;
  final VoidCallback? onRedial;

  @override
  Widget build(BuildContext context) {
    final kind = video ? '视频通话' : '语音通话';
    final label = connected ? '$kind时长 ${formatCallDuration(duration)}' : '$kind已取消';
    final inheritedForeground = DefaultTextStyle.of(context).style.color;
    final foreground =
        context.findAncestorWidgetOfExactType<WeChatMessageBubble>() != null
            ? inheritedForeground ?? WeChatMessageBubble.foregroundOf(context)
            : WeChatMessageBubble.foregroundOf(context);
    // BUG-14 真机回归修订：改用 CupertinoButton 提供按压透明动效，
    // 让用户明确感知点击已生效（纯 GestureDetector 无任何视觉反馈）。
    return CupertinoButton(
      key: const Key('call-summary-redial'),
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      pressedOpacity: 0.5,
      onPressed: onRedial,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            video ? ChangliaoIcons.videoCallFilled : ChangliaoIcons.voiceCallFilled,
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
      ),
    );
  }
}
