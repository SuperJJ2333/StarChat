import 'package:flutter/cupertino.dart';

import 'moment_media_cache.dart';
import 'moment_image_prefetcher.dart';
import 'moment_viewer_source.dart';

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
  late int index = _clamp(widget.initialIndex, widget.imageUrls.length);
  late PageController controller = PageController(initialPage: index);
  late final MomentImagePrefetcher _prefetcher =
      MomentImagePrefetcher(_providerAt);

  static int _clamp(int value, int length) =>
      length == 0 ? 0 : value.clamp(0, length - 1);

  String get _accountKey => widget.mediaAccountKey ?? widget.cacheNamespace;

  ImageProvider _providerAt(int itemIndex) =>
      MomentMediaCache.imageProvider(widget.imageUrls[itemIndex],
          accountKey: _accountKey,
          trustedOrigin: widget.mediaOrigin,
          cacheKey: itemIndex < widget.imageCacheKeys.length
              ? widget.imageCacheKeys[itemIndex]
              : null);

  @override
  void didUpdateWidget(covariant MomentImageViewerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final accountChanged =
        oldWidget.mediaAccountKey != widget.mediaAccountKey ||
            oldWidget.cacheNamespace != widget.cacheNamespace;
    final nextIndex = MomentViewerSource.matchingIndex(
      oldUrls: oldWidget.imageUrls,
      oldCacheKeys: oldWidget.imageCacheKeys,
      newUrls: widget.imageUrls,
      newCacheKeys: widget.imageCacheKeys,
      currentIndex: index,
      oldAccountKey: oldWidget.mediaAccountKey ?? oldWidget.cacheNamespace,
      newAccountKey: _accountKey,
      oldOrigin: oldWidget.mediaOrigin,
      newOrigin: widget.mediaOrigin,
    );
    final target = nextIndex >= 0
        ? nextIndex
        : _clamp(widget.initialIndex, widget.imageUrls.length);
    final sourceChanged = !MomentViewerSource.same(
      oldUrls: oldWidget.imageUrls,
      oldCacheKeys: oldWidget.imageCacheKeys,
      newUrls: widget.imageUrls,
      newCacheKeys: widget.imageCacheKeys,
      oldAccountKey: oldWidget.mediaAccountKey ?? oldWidget.cacheNamespace,
      newAccountKey: _accountKey,
      oldOrigin: oldWidget.mediaOrigin,
      newOrigin: widget.mediaOrigin,
    );
    if (sourceChanged || target != index || accountChanged) {
      controller.dispose();
      index = target;
      controller = PageController(initialPage: index);
    }
    if (sourceChanged) {
      _prefetcher.dispose();
    }
    _prefetchCurrentWindow();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _prefetchCurrentWindow();
      }
    });
  }

  void _prefetchCurrentWindow() {
    _prefetcher.update(
      currentIndex: index,
      itemCount: widget.imageUrls.length,
      identityAt: (itemIndex) => MomentViewerSource.identityAt(
          urls: widget.imageUrls,
          cacheKeys: widget.imageCacheKeys,
          index: itemIndex,
          accountKey: _accountKey,
          trustedOrigin: widget.mediaOrigin),
    );
  }

  @override
  void dispose() {
    _prefetcher.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        backgroundColor: CupertinoColors.black,
        child: SafeArea(
          child: Stack(children: [
            if (widget.imageUrls.isEmpty)
              const Center(
                  child: Icon(CupertinoIcons.photo,
                      key: Key('moment-image-viewer-empty'),
                      color: CupertinoColors.systemGrey,
                      size: 48))
            else
              PageView.builder(
                key: ValueKey(('moment-image-viewer-pages', _accountKey)),
                itemCount: widget.imageUrls.length,
                controller: controller,
                onPageChanged: (value) {
                  if (mounted) {
                    setState(() {
                      index = value;
                      _prefetchCurrentWindow();
                    });
                  }
                },
                itemBuilder: (context, i) => GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: InteractiveViewer(
                    maxScale: 4,
                    child: Center(
                      child: Image(
                        key: ValueKey((
                          MomentMediaCache.imageIdentity(widget.imageUrls[i],
                              accountKey: widget.mediaAccountKey ??
                                  widget.cacheNamespace,
                              trustedOrigin: widget.mediaOrigin,
                              cacheKey: i < widget.imageCacheKeys.length
                                  ? widget.imageCacheKeys[i]
                                  : null),
                          _retries[i] ?? 0
                        )),
                        gaplessPlayback: true,
                        image: MomentMediaCache.imageProvider(
                            widget.imageUrls[i],
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
