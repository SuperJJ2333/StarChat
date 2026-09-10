import '../components/anchored_action_menu.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import 'message_action.dart';

/// 长按消息气泡后的**气泡锚定**快捷菜单（微信式）：
/// - 深色半透明圆角容器，出现在目标气泡正上方、与气泡侧对齐；
/// - 项横向排列：白色图标 + 白色小字标签，细白分隔线；
/// - “复制”固定第一位；超出宽度自动换行；
/// - 点击项回调后由宿主关闭；点击菜单外区域关闭。
///
/// 定位由宿主通过 `CompositedTransformFollower`（LayerLink）完成，
/// 本组件只负责渲染。
final class MessageBubbleMenu extends StatelessWidget {
  const MessageBubbleMenu({
    super.key,
    required this.actions,
    required this.onSelected,
    this.arrowAtTop = false,
    this.arrowX,
  });

  final Set<MessageAction> actions;
  final ValueChanged<MessageAction> onSelected;
  final bool arrowAtTop;
  final double? arrowX;

  static const _presentation = <MessageAction, (IconData, String)>{
    MessageAction.voiceEarpiece: (CupertinoIcons.phone, '听筒播放'),
    MessageAction.voiceSpeaker: (CupertinoIcons.speaker_2, '扬声器播放'),
    MessageAction.copy: (CupertinoIcons.doc_on_doc, '复制'),
    MessageAction.forward: (CupertinoIcons.arrowshape_turn_up_right, '转发'),
    MessageAction.addToEmoji: (CupertinoIcons.star, '收藏'),
    MessageAction.reply: (CupertinoIcons.reply, '引用'),
    MessageAction.reminder: (CupertinoIcons.alarm, '提醒'),
    MessageAction.recall: (CupertinoIcons.arrow_uturn_left, '撤回'),
    MessageAction.multiSelect: (CupertinoIcons.checkmark_square, '多选'),
    MessageAction.deleteLocal: (CupertinoIcons.trash, '删除'),
  };

  @override
  Widget build(BuildContext context) {
    final ordered = MessageActionPolicy.ordered(
      actions.where(_presentation.containsKey),
    );
    return WeChatAnchoredActionMenu<MessageAction>(
      key: const Key('message-bubble-menu'),
      items: [
        for (final action in ordered)
          AnchoredMenuItem(
              value: action,
              icon: _presentation[action]!.$1,
              label: _presentation[action]!.$2,
              key: Key('message-action-${action.name}'))
      ],
      onSelected: onSelected,
      arrowAtTop: arrowAtTop,
      arrowX: arrowX,
    );
  }
}

/// 长按触觉反馈：微信式 mediumImpact，让用户明确感知长按已识别。
Future<void> messageLongPressHaptic() => HapticFeedback.mediumImpact();
