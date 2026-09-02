import 'dart:math' as math;

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
  });

  final Set<MessageAction> actions;
  final ValueChanged<MessageAction> onSelected;

  static const _presentation = <MessageAction, (IconData, String)>{
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
    // 每行最多 4 项（微信式），超出换行。
    final rows = <List<MessageAction>>[];
    for (var i = 0; i < ordered.length; i += 4) {
      rows.add(ordered.sublist(i, (i + 4).clamp(0, ordered.length)));
    }
    return Container(
      key: const Key('message-bubble-menu'),
      // 底部小三角凸起允许溢出绘制，指向目标气泡。
      clipBehavior: Clip.none,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xE64C4C4C),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var r = 0; r < rows.length; r++) ...[
                if (r > 0)
                  Container(
                    height: .5,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    color: CupertinoColors.white.withValues(alpha: .24),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (var c = 0; c < rows[r].length; c++)
                      _MenuItem(
                        action: rows[r][c],
                        presentation: _presentation[rows[r][c]]!,
                        onPressed: () => onSelected(rows[r][c]),
                      ),
                  ],
                ),
                if (r < rows.length - 1) const SizedBox(height: 4),
              ],
            ],
          ),
          // 下边框中央的小三角凸起：指向对应的气泡（视觉引导）。
          Positioned(
            left: 0,
            right: 0,
            bottom: -5,
            child: Center(
              child: Transform.rotate(
                angle: math.pi / 4,
                child: Container(
                  width: 11,
                  height: 11,
                  color: const Color(0xE64C4C4C),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.action,
    required this.presentation,
    required this.onPressed,
  });

  final MessageAction action;
  final (IconData, String) presentation;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = presentation;
    return Semantics(
      button: true,
      label: label,
      child: CupertinoButton(
        key: Key('message-action-${action.name}'),
        // 最小宽度 32（原 64）：四项行宽约减半（需求 4a），
        // 实际宽度由图标/标签内容自然撑开。
        minimumSize: const Size(32, 44),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        onPressed: onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: CupertinoColors.white),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(
                  fontSize: 11, color: CupertinoColors.white),
            ),
          ],
        ),
      ),
    );
  }
}

/// 长按触觉反馈：微信式 mediumImpact，让用户明确感知长按已识别。
Future<void> messageLongPressHaptic() => HapticFeedback.mediumImpact();
