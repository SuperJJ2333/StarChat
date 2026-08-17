import 'package:flutter/cupertino.dart';

import '../foundation/changliao_icons.dart';
import '../foundation/wechat_tokens.dart';

enum ChatMoreAction { image, camera, voiceCall, videoCall, redPacket, file }

final class ChatMorePanel extends StatelessWidget {
  const ChatMorePanel({super.key, required this.onSelected});

  final ValueChanged<ChatMoreAction> onSelected;

  static const _items = <(ChatMoreAction, IconData, String)>[
    (ChatMoreAction.image, CupertinoIcons.photo, '图片'),
    (ChatMoreAction.camera, ChangliaoIcons.camera, '拍摄'),
    (ChatMoreAction.voiceCall, ChangliaoIcons.voiceCall, '语音通话'),
    (ChatMoreAction.videoCall, ChangliaoIcons.videoCall, '视频通话'),
    (ChatMoreAction.redPacket, ChangliaoIcons.gift, '红包'),
    (ChatMoreAction.file, CupertinoIcons.doc, '文件'),
  ];

  @override
  Widget build(BuildContext context) => SizedBox(
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
          itemCount: _items.length,
          itemBuilder: (context, index) {
            final (action, icon, label) = _items[index];
            return Semantics(
              button: true,
              label: label,
              child: CupertinoButton(
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
                        color:
                            CupertinoTheme.of(context).scaffoldBackgroundColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, size: 25),
                    ),
                    const SizedBox(height: 6),
                    Text(label, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            );
          },
        ),
      );
}
