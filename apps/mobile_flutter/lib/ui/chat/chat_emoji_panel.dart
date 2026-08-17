import 'dart:typed_data';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/cupertino.dart';

enum ChatEmojiTab { recent, all, custom }

final class CustomEmojiItem {
  const CustomEmojiItem({
    required this.id,
    required this.bytes,
    required this.isAnimated,
  });

  final String id;
  final Uint8List bytes;
  final bool isAnimated;
}

final class ChatEmojiPanel extends StatefulWidget {
  const ChatEmojiPanel({
    super.key,
    required this.onEmojiSelected,
    required this.customItems,
    required this.onCustomSelected,
    this.initialTab = ChatEmojiTab.recent,
  });

  final ValueChanged<String> onEmojiSelected;
  final List<CustomEmojiItem> customItems;
  final ValueChanged<CustomEmojiItem> onCustomSelected;
  final ChatEmojiTab initialTab;

  @override
  State<ChatEmojiPanel> createState() => _ChatEmojiPanelState();
}

final class _ChatEmojiPanelState extends State<ChatEmojiPanel> {
  late ChatEmojiTab tab = widget.initialTab;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<ChatEmojiTab>(
                groupValue: tab,
                children: const {
                  ChatEmojiTab.recent: Text('最近'),
                  ChatEmojiTab.all: Text('全部'),
                  ChatEmojiTab.custom: Text('我的表情'),
                },
                onValueChanged: (value) {
                  if (value != null) setState(() => tab = value);
                },
              ),
            ),
          ),
          Expanded(
            child: tab == ChatEmojiTab.custom
                ? _CustomEmojiGrid(
                    items: widget.customItems,
                    onSelected: widget.onCustomSelected,
                  )
                : EmojiPicker(
                    onEmojiSelected: (_, emoji) =>
                        widget.onEmojiSelected(emoji.emoji),
                    config: const Config(
                      height: null,
                      checkPlatformCompatibility: true,
                      viewOrderConfig: ViewOrderConfig(),
                      skinToneConfig: SkinToneConfig(
                        rememberSkinTone: true,
                      ),
                      categoryViewConfig: CategoryViewConfig(),
                      bottomActionBarConfig: BottomActionBarConfig(),
                      searchViewConfig: SearchViewConfig(),
                    ),
                  ),
          ),
        ],
      );
}

final class _CustomEmojiGrid extends StatelessWidget {
  const _CustomEmojiGrid({required this.items, required this.onSelected});

  final List<CustomEmojiItem> items;
  final ValueChanged<CustomEmojiItem> onSelected;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Text('长按聊天中的图片或 GIF 添加表情'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return CupertinoButton(
          key: Key('custom-button-${item.id}'),
          padding: EdgeInsets.zero,
          onPressed: () => onSelected(item),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              item.bytes,
              key: Key('custom-${item.id}'),
              fit: BoxFit.cover,
              gaplessPlayback: item.isAnimated,
            ),
          ),
        );
      },
    );
  }
}
