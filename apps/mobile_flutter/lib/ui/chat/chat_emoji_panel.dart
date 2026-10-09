import 'dart:async';

import '../../features/emoji/static_emoji_recent_store.dart';
import '../../core/maintenance_activity.dart';
import 'emoji_resource_glyph.dart';
import 'shared_emoji_player.dart';
import '../../features/emoji/emoji_resource_store.dart';
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
    Uint8List? bytes,
    required this.isAnimated,
    this.mimeType = 'image/png',
    this.loadPreview,
  }) : _bytes = bytes;

  final String id;
  final Uint8List? _bytes;
  Uint8List get bytes => _bytes ?? Uint8List(0);
  final Future<Uint8List> Function()? loadPreview;
  final bool isAnimated;
  final String mimeType;
}

/// 表情面板：顶部三栏**图标**切换（无文字标签）——
/// - “表情”（笑脸图标）：fluentui-emoji 矢量静态表情（SVG，按 DPR 栅格化，
///   高 DPI 锐利），插入 Unicode 字符；
/// - “超级表情”（动态/特效图标）：独立资源缓存中的 Animated Fluent Emojis
///   （256px animated WebP），独立发送一个 Unicode 字符；
/// - “我的表情”（收藏/心形图标）：E2EE 表情仓库的图片/GIF 媒体消息。
/// 三栏切换完整展示对应类别内容，选中态由分段控件保持同步。
final class ChatEmojiPanel extends StatefulWidget {
  const ChatEmojiPanel({
    super.key,
    required this.onEmojiSelected,
    required this.onDynamicEmojiSelected,
    this.allowDynamicEmojis = true,
    this.resourceStore,
    this.playbackPool,
    required this.customItems,
    required this.onCustomSelected,
    this.initialTab = ChatEmojiTab.smiley,
    this.accountId,
    this.onCustomRemoved,
    this.customEmptyState,
  });

  final ValueChanged<String> onEmojiSelected;
  final ValueChanged<String> onDynamicEmojiSelected;
  final bool allowDynamicEmojis;
  final EmojiResourceStore? resourceStore;
  final SharedEmojiPlayerPool? playbackPool;
  final List<CustomEmojiItem> customItems;
  final ValueChanged<CustomEmojiItem> onCustomSelected;
  final ChatEmojiTab initialTab;
  final String? accountId;
  final Future<void> Function(CustomEmojiItem)? onCustomRemoved;
  final Widget? customEmptyState;

  @override
  State<ChatEmojiPanel> createState() => _ChatEmojiPanelState();
}

final class _ChatEmojiPanelState extends State<ChatEmojiPanel> {
  late ChatEmojiTab tab =
      !widget.allowDynamicEmojis && widget.initialTab == ChatEmojiTab.superEmoji
          ? ChatEmojiTab.smiley
          : widget.initialTab;

  List<String> _recents = const [];
  StaticEmojiRecentStore? _recentStore;
  int _recentRevision = 0;

  @override
  void initState() {
    super.initState();
    _loadRecents();
  }

  @override
  void didUpdateWidget(covariant ChatEmojiPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId) {
      _recents = const [];
      _recentRevision++;
      _loadRecents();
    }
  }

  void _loadRecents() {
    final accountId = widget.accountId;
    final store = accountId == null || accountId.isEmpty
        ? null
        : StaticEmojiRecentStore(accountId: accountId);
    _recentStore = store;
    if (store == null) return;
    final revision = _recentRevision;
    unawaited(store.load().then((values) {
      if (!mounted || _recentStore != store) return;
      setState(() {
        _recents = _recentRevision == revision
            ? values
            : StaticEmojiRecentStore.normalize([..._recents, ...values]);
      });
    }).catchError((Object _) {
      // Preference availability must not block the composer.
    }));
  }

  void _selectStatic(String char) {
    _recentRevision++;
    setState(
        () => _recents = StaticEmojiRecentStore.normalize([char, ..._recents]));
    final store = _recentStore;
    if (store != null) {
      unawaited(store.record(char).catchError((Object _) {}));
    }
    widget.onEmojiSelected(char);
  }

  void _clearScrollInteraction() => MaintenanceActivity.instance
      .setInteractive('emoji-panel-${identityHashCode(this)}', false);

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final panelColor =
        dark ? WeChatColors.darkSurface : WeChatColors.lightSurface;
    return NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          final reason = 'emoji-panel-${identityHashCode(this)}';
          if (notification is ScrollStartNotification) {
            MaintenanceActivity.instance.setInteractive(reason, true);
          }
          if (notification is ScrollEndNotification) {
            MaintenanceActivity.instance.setInteractive(reason, false);
          }
          return false;
        },
        child: Column(
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
                    if (widget.allowDynamicEmojis)
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
                    if (value != null && value != tab) {
                      _clearScrollInteraction();
                      setState(() => tab = value);
                    }
                  },
                ),
              ),
            ),
            Expanded(
              child: switch (tab) {
                ChatEmojiTab.custom => _CustomEmojiGrid(
                    emptyState: widget.customEmptyState,
                    items: widget.customItems,
                    onSelected: widget.onCustomSelected,
                    onRemoved: widget.onCustomRemoved,
                  ),
                ChatEmojiTab.smiley => _VectorEmojiGrid(
                    onSelected: _selectStatic,
                    recents: _recents,
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
                          onPressed: () =>
                              widget.onDynamicEmojiSelected(emoji.char),
                          child: LayoutBuilder(
                              builder: (context, constraints) =>
                                  EmojiResourceGlyph(
                                    asset: emoji.asset,
                                    store: widget.resourceStore,
                                    pool: widget.playbackPool,
                                    size: constraints.maxWidth,
                                  )),
                        );
                      },
                    ),
                  ),
              },
            ),
          ],
        ));
  }

  @override
  void dispose() {
    _clearScrollInteraction();
    super.dispose();
  }
}

/// 矢量静态表情网格：GridView 惰性构建可见项；SvgPicture 解析结果由
/// flutter_svg 全局缓存复用，同表情多处出现时复用解析缓存。
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
        color:
            selected ? WeChatColors.brandPrimary : WeChatColors.textSecondary,
      ),
    );

final class _VectorEmojiGrid extends StatelessWidget {
  const _VectorEmojiGrid({required this.onSelected, required this.recents});

  final ValueChanged<String> onSelected;
  final List<String> recents;

  static const _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 8, mainAxisSpacing: 6, crossAxisSpacing: 6);

  Widget _button(VectorEmoji emoji, {bool recent = false}) => CupertinoButton(
        key: Key(
            '${recent ? 'recent-static-emoji' : 'vector-emoji'}-${emoji.name}'),
        padding: EdgeInsets.zero,
        onPressed: () => onSelected(emoji.char),
        child: SvgPicture.asset(emoji.asset, fit: BoxFit.contain),
      );

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final panelColor =
        dark ? WeChatColors.darkSurface : WeChatColors.lightSurface;
    return Container(
      color: panelColor,
      child: CustomScrollView(
        key: const Key('vector-emoji-grid'),
        slivers: [
          if (recents.isNotEmpty) ...[
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Text('最近',
                    style: TextStyle(
                        fontSize: 12, color: WeChatColors.textSecondary)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(12),
              sliver: SliverGrid(
                key: const Key('recent-static-emoji-grid'),
                gridDelegate: _gridDelegate,
                delegate: SliverChildBuilderDelegate((context, index) {
                  final emoji = vectorEmojis
                      .firstWhere((emoji) => emoji.char == recents[index]);
                  return _button(emoji, recent: true);
                }, childCount: recents.length),
              ),
            ),
          ],
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: _gridDelegate,
              delegate: SliverChildBuilderDelegate(
                  (context, index) => _button(vectorEmojis[index]),
                  childCount: vectorEmojis.length),
            ),
          ),
        ],
      ),
    );
  }
}

final class _CustomEmojiGrid extends StatefulWidget {
  const _CustomEmojiGrid(
      {required this.items,
      required this.onSelected,
      this.onRemoved,
      this.emptyState});

  final List<CustomEmojiItem> items;
  final ValueChanged<CustomEmojiItem> onSelected;
  final Future<void> Function(CustomEmojiItem)? onRemoved;
  final Widget? emptyState;

  @override
  State<_CustomEmojiGrid> createState() => _CustomEmojiGridState();
}

final class _CustomEmojiGridState extends State<_CustomEmojiGrid> {
  final _removed = <String>{};
  final _deleting = <String>{};

  Future<void> _delete(CustomEmojiItem item) async {
    if (_deleting.contains(item.id)) return;
    final confirmed = await showCupertinoModalPopup<bool>(
        context: context,
        builder: (context) => CupertinoActionSheet(
                actions: [
                  CupertinoActionSheetAction(
                      isDestructiveAction: true,
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除')),
                ],
                cancelButton: CupertinoActionSheetAction(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'))));
    if (confirmed != true || !mounted || !_deleting.add(item.id)) return;
    try {
      await widget.onRemoved?.call(item);
      if (mounted) setState(() => _removed.add(item.id));
    } catch (_) {
      if (mounted) {
        await showCupertinoDialog<void>(
            context: context,
            builder: (context) =>
                CupertinoAlertDialog(content: const Text('删除失败，请重试'), actions: [
                  CupertinoDialogAction(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('知道了'))
                ]));
      }
    } finally {
      _deleting.remove(item.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items =
        widget.items.where((item) => !_removed.contains(item.id)).toList();
    if (items.isEmpty) {
      return widget.emptyState ??
          const Center(child: Text('长按聊天中的图片或 GIF 添加表情'));
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
        return GestureDetector(
          onLongPress: widget.onRemoved == null ? null : () => _delete(item),
          child: CupertinoButton(
            key: Key('custom-button-${item.id}'),
            padding: EdgeInsets.zero,
            onPressed: () => widget.onSelected(item),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _CustomEmojiPreview(key: ValueKey(item.id), item: item),
            ),
          ),
        );
      },
    );
  }
}

final class _CustomEmojiPreview extends StatefulWidget {
  const _CustomEmojiPreview({super.key, required this.item});
  final CustomEmojiItem item;
  @override
  State<_CustomEmojiPreview> createState() => _CustomEmojiPreviewState();
}

final class _CustomEmojiPreviewState extends State<_CustomEmojiPreview> {
  late final Future<Uint8List> _preview =
      widget.item.loadPreview?.call() ?? Future.value(widget.item.bytes);
  @override
  Widget build(BuildContext context) =>
      Stack(alignment: Alignment.bottomRight, children: [
        FutureBuilder<Uint8List>(
            future: _preview,
            builder: (context, snapshot) {
              if (snapshot.hasError) return const Icon(CupertinoIcons.photo);
              final bytes = snapshot.data;
              if (bytes == null) {
                return const Center(child: CupertinoActivityIndicator());
              }
              return Image.memory(bytes,
                  key: Key('custom-${widget.item.id}'),
                  fit: BoxFit.contain,
                  cacheWidth: 160,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) =>
                      const Icon(CupertinoIcons.photo));
            }),
        if (widget.item.isAnimated)
          const DecoratedBox(
              decoration: BoxDecoration(color: CupertinoColors.systemGrey),
              child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 3),
                  child: Text('GIF',
                      style: TextStyle(
                          fontSize: 10, color: CupertinoColors.white)))),
      ]);
}
