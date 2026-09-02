import 'package:flutter/cupertino.dart';

import '../foundation/changliao_icons.dart';
import '../foundation/wechat_tokens.dart';

enum ChatMoreAction { image, camera, voiceCall, videoCall, redPacket, transfer, file }

final class ChatMorePanel extends StatelessWidget {
  const ChatMorePanel({
    super.key,
    required this.onSelected,
    this.onCameraLongPress,
    this.showTransfer = true,
    this.onTools,
  });

  final ValueChanged<ChatMoreAction> onSelected;

  /// 「拍摄」长按：进入录像模式（短按仍为拍照）。
  final VoidCallback? onCameraLongPress;
  final bool showTransfer;

  /// “工具”入口回调：展开工具面板（可扩展注册接口见 ChatToolRegistry）。
  final VoidCallback? onTools;

  static const _items = <(ChatMoreAction, IconData, String)>[
    (ChatMoreAction.image, CupertinoIcons.photo, '图片'),
    (ChatMoreAction.camera, ChangliaoIcons.camera, '拍摄'),
    (ChatMoreAction.voiceCall, ChangliaoIcons.voiceCall, '语音通话'),
    (ChatMoreAction.videoCall, ChangliaoIcons.videoCall, '视频通话'),
    (ChatMoreAction.redPacket, ChangliaoIcons.gift, '红包'),
    (ChatMoreAction.transfer, ChangliaoIcons.transfer, '转账'),
    (ChatMoreAction.file, CupertinoIcons.doc, '文件'),
  ];

  static const _adjustedItems = <(ChatMoreAction, IconData, String)>[
    (ChatMoreAction.image, CupertinoIcons.photo, '图片'),
    (ChatMoreAction.camera, ChangliaoIcons.camera, '拍摄'),
    (ChatMoreAction.voiceCall, ChangliaoIcons.voiceCall, '语音通话'),
    (ChatMoreAction.videoCall, ChangliaoIcons.videoCall, '视频通话'),
    (ChatMoreAction.redPacket, ChangliaoIcons.gift, '红包'),
    (ChatMoreAction.file, CupertinoIcons.doc, '文件'),
  ];

  @override
  Widget build(BuildContext context) {
    final items = showTransfer ? _items : _adjustedItems;
    return SizedBox(
      key: const Key('chat-more-panel'),
      height: 232,
      child: GridView.builder(
        padding: const EdgeInsets.symmetric(
          horizontal: WeChatSpacing.lg,
          vertical: WeChatSpacing.md,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: WeChatSpacing.md,
          crossAxisSpacing: WeChatSpacing.md,
          mainAxisExtent: 82,
        ),
        itemCount: items.length + 1,
        itemBuilder: (context, index) {
          // 末位固定为“工具”入口：展开可扩展的工具面板。
          if (index == items.length) {
            return Semantics(
              button: true,
              label: '工具',
              child: CupertinoButton(
                key: const Key('chat-more-tools'),
                minimumSize: const Size.square(
                  WeChatDimensions.minimumTouchTarget,
                ),
                padding: EdgeInsets.zero,
                onPressed: onTools,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color:
                            CupertinoTheme.of(context).scaffoldBackgroundColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(CupertinoIcons.wrench, size: 25),
                    ),
                    const SizedBox(height: 6),
                    const Text('工具', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            );
          }
          final (action, icon, label) = items[index];
          final button = CupertinoButton(
            key: Key('chat-more-${action.name}'),
            minimumSize: const Size.square(
              WeChatDimensions.minimumTouchTarget,
            ),
            padding: EdgeInsets.zero,
            onPressed: () => onSelected(action),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: CupertinoTheme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 25),
                ),
                const SizedBox(height: 6),
                Text(label, style: const TextStyle(fontSize: 12)),
              ],
            ),
          );
          // 「拍摄」：短按拍照、长按录像（长按在手势竞技场中优先于点击）。
          final wrapped =
              action == ChatMoreAction.camera && onCameraLongPress != null
                  ? GestureDetector(
                      onLongPress: onCameraLongPress,
                      child: button,
                    )
                  : button;
          return Semantics(
            button: true,
            label: label,
            child: wrapped,
          );
        },
      ),
    );
  }
}
