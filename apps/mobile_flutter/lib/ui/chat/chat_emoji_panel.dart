import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../features/emoji/fluent_emoji_catalog.dart';
import '../../features/emoji/fluent_vector_emoji_catalog.dart';
import '../foundation/wechat_tokens.dart';

enum ChatEmojiTab { smiley, superEmoji, custom }

final class CustomEmojiItem {
  const CustomEmojiItem({
    required this.id,
    required this.bytes,
    required this.isAnimated,
    this.mimeType = 'image/png',
  });

  final String id;
  final Uint8List bytes;
  final bool isAnimated;
  final String mimeType;
}

/// 表情面板：顶部三栏**图标**切换（无文字标签）——
/// - “表情”（笑脸图标）：fluentui-emoji 矢量静态表情（SVG，按 DPR 栅格化，
///   高 DPI 锐利），插入 Unicode 字符；
/// - “超级表情”（动态/特效图标）：打包内置的 Animated Fluent Emojis
///   （256px animated WebP），插入 Unicode 字符，发送路径与普通文本一致；
/// - “我的表情”（收藏/心形图标）：E2EE 表情仓库的图片/GIF 媒体消息。
/// 三栏切换完整展示对应类别内容，选中态由分段控件保持同步。
final class ChatEmojiPanel extends StatefulWidget {
  const ChatEmojiPanel({
    super.key,
    required this.onEmojiSelected,
    required this.customItems,
    required this.onCustomSelected,
    this.initialTab = ChatEmojiTab.superEmoji,
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
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final panelColor =
        dark ? WeChatColors.darkSurface : WeChatColors.lightSurface;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<ChatEmojiTab>(
              groupValue: tab,
              children: {
                ChatEmojiTab.smiley: _tabIcon(
                  key: const Key('emoji-tab-smiley'),
                  icon: CupertinoIcons.smiley,
                  semanticLabel: '表情',
                  selected: tab == ChatEmojiTab.smiley,
                ),
                ChatEmojiTab.superEmoji: _tabIcon(
                  key: const Key('emoji-tab-super'),
                  icon: CupertinoIcons.sparkles,
                  semanticLabel: '超级表情',
                  selected: tab == ChatEmojiTab.superEmoji,
                ),
                ChatEmojiTab.custom: _tabIcon(
                  key: const Key('emoji-tab-custom'),
                  icon: CupertinoIcons.heart_fill,
                  semanticLabel: '我的表情',
                  selected: tab == ChatEmojiTab.custom,
                ),
              },
              onValueChanged: (value) {
                if (value != null) setState(() => tab = value);
              },
            ),
          ),
        ),
        Expanded(
          child: switch (tab) {
            ChatEmojiTab.custom => _CustomEmojiGrid(
                items: widget.customItems,
                onSelected: widget.onCustomSelected,
              ),
            ChatEmojiTab.smiley => _VectorEmojiGrid(
                onSelected: widget.onEmojiSelected,
              ),
            ChatEmojiTab.superEmoji => Container(
                color: panelColor,
                child: GridView.builder(
                  key: const Key('fluent-emoji-grid'),
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 8,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                  ),
                  itemCount: fluentEmojis.length,
                  itemBuilder: (context, index) {
                    final emoji = fluentEmojis[index];
                    return CupertinoButton(
                      key: Key('fluent-emoji-${emoji.name}'),
                      padding: EdgeInsets.zero,
                      onPressed: () => widget.onEmojiSelected(emoji.char),
                      child: Image.asset(
                        emoji.asset,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.high,
                      ),
                    );
                  },
                ),
              ),
          },
        ),
      ],
    );
  }
}

/// 矢量静态表情网格：GridView 惰性构建可见项；SvgPicture 解析结果由
/// flutter_svg 全局缓存复用，同表情多处出现不重复解析，滑动无卡顿。
/// 三栏图标标签：笑脸=表情、动态/特效=超级表情、心形=我的表情。
Widget _tabIcon({
  required Key key,
  required IconData icon,
  required String semanticLabel,
  required bool selected,
}) =>
    Semantics(
      label: semanticLabel,
      button: true,
      child: Icon(
        icon,
        key: key,
        size: 22,
        color: selected
            ? WeChatColors.brandPrimary
            : WeChatColors.textSecondary,
      ),
    );

final class _VectorEmojiGrid extends StatelessWidget {
  const _VectorEmojiGrid({required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final panelColor =
        dark ? WeChatColors.darkSurface : WeChatColors.lightSurface;
    return Container(
      color: panelColor,
      child: GridView.builder(
        key: const Key('vector-emoji-grid'),
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 8,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
        ),
        itemCount: vectorEmojis.length,
        itemBuilder: (context, index) {
          final emoji = vectorEmojis[index];
          return CupertinoButton(
            key: Key('vector-emoji-${emoji.name}'),
            padding: EdgeInsets.zero,
            onPressed: () => onSelected(emoji.char),
            child: SvgPicture.asset(
              emoji.asset,
              fit: BoxFit.contain,
            ),
          );
        },
      ),
    );
  }
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
