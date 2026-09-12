import 'package:flutter/cupertino.dart';

import 'moment_media_cache.dart';
import 'moment_image_prefetcher.dart';
import 'moment_viewer_source.dart';
import '../components/network_status_capsule.dart';
import '../components/operation_failure_dialog.dart';

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
  final _retrying = <Object>{};
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

  Future<void> _retryFromImageError(int itemIndex, Object error) async {
    if (itemIndex >= widget.imageUrls.length) return;
    final url = widget.imageUrls[itemIndex];
    final accountKey = _accountKey;
    final origin = widget.mediaOrigin;
    final cacheKey = itemIndex < widget.imageCacheKeys.length
        ? widget.imageCacheKeys[itemIndex]
        : null;
    final identity = (url, accountKey, origin, cacheKey);
    if (!_retrying.add(identity)) return;
    try {
      // A signed-url expiry and an image decode error retain the original
      // one-tap reload behavior. Transport and 5xx failures first give the
      // user a cancellable choice, based on the actual image load error.
      if (classifyOperationFailure(error) != OperationFailureKind.other) {
        final confirmed = await showRetryableOperationFailure(context, error);
        if (!confirmed) return;
      }
      // The page may have been rebuilt for another account, image order, or
      // source while the dialog was visible. Never evict/reload that new item.
      final currentCacheKey = itemIndex < widget.imageCacheKeys.length
          ? widget.imageCacheKeys[itemIndex]
          : null;
      if (!mounted ||
          _accountKey != accountKey ||
          widget.mediaOrigin != origin ||
          itemIndex >= widget.imageUrls.length ||
          widget.imageUrls[itemIndex] != url ||
          currentCacheKey != cacheKey) {
        return;
      }
      await MomentMediaCache.retry(MomentMediaCache.imageProvider(url,
          accountKey: accountKey, trustedOrigin: origin, cacheKey: cacheKey));
      if (mounted) {
        setState(() => _retries[itemIndex] = (_retries[itemIndex] ?? 0) + 1);
      }
    } catch (_) {
      // The image's error builder remains the visible recovery surface.
    } finally {
      _retrying.remove(identity);
    }
  }

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
                        errorBuilder: (_, error, ___) => Center(
                          child: CupertinoButton(
                            onPressed: () => _retryFromImageError(i, error),
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
              top: 48,
              left: 16,
              right: 16,
              child: Center(child: WeChatNetworkStatusCapsule()),
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
