import 'package:flutter/cupertino.dart';

import 'moment_media_cache.dart';

/// 朋友圈图片全屏查看页：网络大图 + 双指缩放 + 左右切换 + 点击关闭。
final class MomentImageViewerPage extends StatefulWidget {
  const MomentImageViewerPage({
    super.key,
    required this.imageUrls,
    required this.initialIndex,
    this.imageCacheKeys = const [],
    this.mediaAccountKey,
    this.mediaOrigin,
    this.cacheNamespace = '',
  });

  final List<String> imageUrls;
  final List<String?> imageCacheKeys;
  final String? mediaAccountKey, mediaOrigin;
  final int initialIndex;
  final String cacheNamespace;

  @override
  State<MomentImageViewerPage> createState() => _MomentImageViewerPageState();
}

final class _MomentImageViewerPageState extends State<MomentImageViewerPage> {
  final _retries = <int, int>{};
  late int index = widget.initialIndex.clamp(0, widget.imageUrls.length - 1);
  late final controller = PageController(initialPage: index);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        backgroundColor: CupertinoColors.black,
        child: SafeArea(
          child: Stack(children: [
            PageView.builder(
              itemCount: widget.imageUrls.length,
              controller: controller,
              onPageChanged: (value) {
                if (mounted) setState(() => index = value);
              },
              itemBuilder: (context, i) => GestureDetector(
                onTap: () => Navigator.pop(context),
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Center(
                    child: Image(
                      key: ValueKey((
                        MomentMediaCache.imageIdentity(widget.imageUrls[i],
                            accountKey:
                                widget.mediaAccountKey ?? widget.cacheNamespace,
                            trustedOrigin: widget.mediaOrigin,
                            cacheKey: i < widget.imageCacheKeys.length
                                ? widget.imageCacheKeys[i]
                                : null),
                        _retries[i] ?? 0
                      )),
                      gaplessPlayback: true,
                      image: MomentMediaCache.imageProvider(widget.imageUrls[i],
                          accountKey:
                              widget.mediaAccountKey ?? widget.cacheNamespace,
                          trustedOrigin: widget.mediaOrigin,
                          cacheKey: i < widget.imageCacheKeys.length
                              ? widget.imageCacheKeys[i]
                              : null),
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Center(
                        child: CupertinoButton(
                          onPressed: () async {
                            await MomentMediaCache.retry(
                                MomentMediaCache.imageProvider(
                                    widget.imageUrls[i],
                                    accountKey: widget.mediaAccountKey ??
                                        widget.cacheNamespace,
                                    trustedOrigin: widget.mediaOrigin,
                                    cacheKey: i < widget.imageCacheKeys.length
                                        ? widget.imageCacheKeys[i]
                                        : null));
                            if (mounted) {
                              setState(
                                  () => _retries[i] = (_retries[i] ?? 0) + 1);
                            }
                          },
                          child: const Icon(CupertinoIcons.arrow_clockwise,
                              color: CupertinoColors.systemGrey,
                              semanticLabel: '重新加载图片'),
                        ),
                      ),
                      loadingBuilder: (_, child, progress) {
                        if (progress == null) return child;
                        return const Center(
                            child: CupertinoActivityIndicator());
                      },
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 16,
              child: Text(
                widget.imageUrls.length > 1
                    ? '${index + 1} / ${widget.imageUrls.length}'
                    : '',
                style: const TextStyle(
                    fontSize: 13, color: CupertinoColors.systemGrey),
              ),
            ),
          ]),
        ),
      );
}
