import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../components/wechat_scaffold.dart';
import 'moment_media_cache.dart';
import 'moment_image_prefetcher.dart';
import 'moment_viewer_source.dart';

final class WeChatMomentViewer extends StatefulWidget {
  const WeChatMomentViewer(
      {super.key,
      required this.urls,
      this.initialIndex = 0,
      this.imageCacheKeys = const [],
      this.mediaAccountKey,
      this.mediaOrigin});
  final List<String> urls;
  final List<String?> imageCacheKeys;
  final String? mediaAccountKey, mediaOrigin;
  final int initialIndex;
  @override
  State<WeChatMomentViewer> createState() => _WeChatMomentViewerState();
}

final class _WeChatMomentViewerState extends State<WeChatMomentViewer> {
  late PageController _controller = PageController(
      initialPage: _clamp(widget.initialIndex, widget.urls.length));
  late final MomentImagePrefetcher _prefetcher =
      MomentImagePrefetcher(_providerAt);
  late int _index = _clamp(widget.initialIndex, widget.urls.length);

  static int _clamp(int value, int length) =>
      length == 0 ? 0 : value.clamp(0, length - 1);

  ImageProvider _providerAt(int index) =>
      MomentMediaCache.imageProvider(widget.urls[index],
          accountKey: widget.mediaAccountKey,
          trustedOrigin: widget.mediaOrigin,
          cacheKey: index < widget.imageCacheKeys.length
              ? widget.imageCacheKeys[index]
              : null);

  void _prefetchCurrentWindow() => _prefetcher.update(
      currentIndex: _index,
      itemCount: widget.urls.length,
      identityAt: (index) => MomentViewerSource.identityAt(
          urls: widget.urls,
          cacheKeys: widget.imageCacheKeys,
          index: index,
          accountKey: widget.mediaAccountKey ?? '',
          trustedOrigin: widget.mediaOrigin));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetchCurrentWindow();
    });
  }

  @override
  void didUpdateWidget(covariant WeChatMomentViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentIndex = _controller.hasClients
        ? _controller.page?.round() ??
            _clamp(widget.initialIndex, oldWidget.urls.length)
        : _clamp(widget.initialIndex, oldWidget.urls.length);
    final matched = MomentViewerSource.matchingIndex(
      oldUrls: oldWidget.urls,
      oldCacheKeys: oldWidget.imageCacheKeys,
      newUrls: widget.urls,
      newCacheKeys: widget.imageCacheKeys,
      currentIndex: currentIndex,
      oldAccountKey: oldWidget.mediaAccountKey ?? '',
      newAccountKey: widget.mediaAccountKey ?? '',
      oldOrigin: oldWidget.mediaOrigin,
      newOrigin: widget.mediaOrigin,
    );
    final target = matched >= 0
        ? matched
        : _clamp(widget.initialIndex, widget.urls.length);
    if (!MomentViewerSource.same(
      oldUrls: oldWidget.urls,
      oldCacheKeys: oldWidget.imageCacheKeys,
      newUrls: widget.urls,
      newCacheKeys: widget.imageCacheKeys,
      oldAccountKey: oldWidget.mediaAccountKey ?? '',
      newAccountKey: widget.mediaAccountKey ?? '',
      oldOrigin: oldWidget.mediaOrigin,
      newOrigin: widget.mediaOrigin,
    )) {
      _controller.dispose();
      _controller = PageController(initialPage: target);
      _index = target;
      _prefetcher.dispose();
    }
    _prefetchCurrentWindow();
  }

  @override
  void dispose() {
    _prefetcher.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: const CupertinoNavigationBar(),
        child: widget.urls.isEmpty
            ? const Center(
                child: Icon(CupertinoIcons.photo,
                    key: Key('moment-image-viewer-empty'), size: 48))
            : KeyedSubtree(
                key: ValueKey((
                  'moment-image-viewer-account',
                  widget.mediaAccountKey,
                  widget.mediaOrigin
                )),
                child: PageView.builder(
                    key: const Key('moment-image-viewer'),
                    controller: _controller,
                    itemCount: widget.urls.length,
                    onPageChanged: (value) {
                      _index = value;
                      _prefetchCurrentWindow();
                    },
                    itemBuilder: (_, index) => InteractiveViewer(
                        child: Center(
                            child: Image(
                                key: ValueKey(MomentMediaCache.imageIdentity(
                                    widget.urls[index],
                                    accountKey: widget.mediaAccountKey,
                                    trustedOrigin: widget.mediaOrigin,
                                    cacheKey: index < widget.imageCacheKeys.length
                                        ? widget.imageCacheKeys[index]
                                        : null)),
                                gaplessPlayback: true,
                                image: MomentMediaCache.imageProvider(
                                    widget.urls[index],
                                    accountKey: widget.mediaAccountKey,
                                    trustedOrigin: widget.mediaOrigin,
                                    cacheKey:
                                        index < widget.imageCacheKeys.length
                                            ? widget.imageCacheKeys[index]
                                            : null),
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => const Icon(
                                    CupertinoIcons.photo,
                                    size: 48))))),
              ),
      );
}

final class WeChatMomentCoverViewer extends StatefulWidget {
  const WeChatMomentCoverViewer({
    super.key,
    required this.url,
    required this.onChangeCover,
    this.cacheKey,
    this.cacheKeyForUrl,
    this.mediaAccountKey,
    this.mediaOrigin,
  });

  final String? url;
  final String? cacheKey;
  final String? mediaAccountKey, mediaOrigin;
  final String? Function(String url)? cacheKeyForUrl;
  final Future<String?> Function(ValueChanged<Uint8List> onPreview)
      onChangeCover;

  @override
  State<WeChatMomentCoverViewer> createState() =>
      _WeChatMomentCoverViewerState();
}

final class _WeChatMomentCoverViewerState
    extends State<WeChatMomentCoverViewer> {
  String? _url;
  String? _cacheKey;
  String? _error;
  Uint8List? _localPreview;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _url = widget.url;
    _cacheKey = widget.cacheKey;
  }

  Future<void> _changeCover() async {
    if (_uploading) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final value = await widget.onChangeCover((bytes) {
        if (mounted) setState(() => _localPreview = bytes);
      });
      if (mounted && value != null) {
        setState(() {
          _url = value;
          _cacheKey = widget.cacheKeyForUrl?.call(value);
          _localPreview = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: const CupertinoNavigationBar(
          middle: Text('朋友圈封面'),
        ),
        child: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: CupertinoColors.black,
                child: InteractiveViewer(
                  child: Center(
                    child: _localPreview != null
                        ? Image.memory(
                            _localPreview!,
                            key: const Key('moment-cover-local-preview'),
                            fit: BoxFit.contain,
                          )
                        : _url == null
                            ? const Icon(CupertinoIcons.photo,
                                color: CupertinoColors.white, size: 56)
                            : Image(
                                key: ValueKey(MomentMediaCache.imageIdentity(
                                    _url!,
                                    accountKey: widget.mediaAccountKey,
                                    trustedOrigin: widget.mediaOrigin,
                                    cacheKey: _cacheKey)),
                                gaplessPlayback: true,
                                image: MomentMediaCache.imageProvider(_url!,
                                    cacheKey: _cacheKey,
                                    accountKey: widget.mediaAccountKey,
                                    trustedOrigin: widget.mediaOrigin),
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => const Icon(
                                  CupertinoIcons.exclamationmark_triangle,
                                  color: CupertinoColors.white,
                                  size: 48,
                                ),
                              ),
                  ),
                ),
              ),
              Positioned(
                right: 16,
                bottom: 16,
                child: CupertinoButton.filled(
                  key: const Key('moment-change-cover'),
                  onPressed: _uploading ? null : _changeCover,
                  child: _uploading
                      ? const CupertinoActivityIndicator()
                      : const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(CupertinoIcons.camera, size: 18),
                            SizedBox(width: 6),
                            Text('换封面'),
                          ],
                        ),
                ),
              ),
              if (_error != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 80,
                  child: Text(
                    _error!,
                    key: const Key('moment-cover-error'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: CupertinoColors.systemRed),
                  ),
                ),
            ],
          ),
        ),
      );
}
