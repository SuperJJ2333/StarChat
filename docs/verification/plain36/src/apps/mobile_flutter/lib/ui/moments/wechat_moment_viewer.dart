import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../components/wechat_scaffold.dart';

final class WeChatMomentViewer extends StatelessWidget {
  const WeChatMomentViewer(
      {super.key, required this.urls, this.initialIndex = 0});
  final List<String> urls;
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
                    child: Image.network(urls[index],
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
  });

  final String? url;
  final Future<String?> Function(ValueChanged<Uint8List> onPreview)
      onChangeCover;

  @override
  State<WeChatMomentCoverViewer> createState() =>
      _WeChatMomentCoverViewerState();
}

final class _WeChatMomentCoverViewerState
    extends State<WeChatMomentCoverViewer> {
  String? _url;
  String? _error;
  Uint8List? _localPreview;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _url = widget.url;
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
                            : Image.network(
                                _url!,
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
