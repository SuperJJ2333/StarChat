import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../components/wechat_scaffold.dart';
import 'moment_media_cache.dart';

final class WeChatMomentViewer extends StatelessWidget {
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
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: const CupertinoNavigationBar(),
        child: PageView.builder(
            key: const Key('moment-image-viewer'),
            controller: PageController(initialPage: initialIndex),
            itemCount: urls.length,
            itemBuilder: (_, index) => InteractiveViewer(
                child: Center(
                    child: Image(
                        key: ValueKey(urls[index]),
                        image: MomentMediaCache.imageProvider(urls[index],
                            accountKey: mediaAccountKey,
                            trustedOrigin: mediaOrigin,
                            cacheKey: index < imageCacheKeys.length
                                ? imageCacheKeys[index]
                                : null),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) =>
                            const Icon(CupertinoIcons.photo, size: 48))))),
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
                                key: ValueKey(_url),
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
