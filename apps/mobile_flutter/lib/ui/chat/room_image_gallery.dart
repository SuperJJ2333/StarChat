import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'encrypted_media_view.dart';

class RoomGalleryImage {
  const RoomGalleryImage({
    required this.id,
    required this.loadPreview,
    required this.loadOriginal,
    required this.onForward,
    this.originalSize,
  });
  final String id;
  final Future<Uint8List> Function() loadPreview, loadOriginal;
  final Future<void> Function() onForward;
  final int? originalSize;
}

/// Room-scoped chronological gallery. History loads metadata, never eagerly
/// downloads all images; a failed history fetch leaves current pages intact.
class RoomImageGalleryPage extends StatefulWidget {
  const RoomImageGalleryPage({
    super.key,
    required this.images,
    required this.initialId,
    required this.loadEarlier,
    required this.onForwardEdited,
    required this.onFavorite,
  });
  final List<RoomGalleryImage> images;
  final String initialId;
  final Future<List<RoomGalleryImage>> Function() loadEarlier;
  final Future<bool> Function(Uint8List) onForwardEdited;
  final Future<void> Function(Uint8List) onFavorite;
  @override
  State<RoomImageGalleryPage> createState() => _RoomImageGalleryPageState();
}

class _RoomImageGalleryPageState extends State<RoomImageGalleryPage> {
  late List<RoomGalleryImage> _images = List.of(widget.images);
  late int _index = _images.isEmpty
      ? 0
      : _images
          .indexWhere((image) => image.id == widget.initialId)
          .clamp(0, _images.length - 1);
  late final PageController _pages = PageController(initialPage: _index);
  final _previews = <String, Future<Uint8List>>{};
  bool _loading = false,
      _exhausted = false,
      _zoomed = false,
      _anchoring = false;
  String? _error;
  void _trimPreviews() {
    final keep = <String>{
      for (var i = _index - 1; i <= _index + 1; i++)
        if (i >= 0 && i < _images.length) _images[i].id,
    };
    _previews.removeWhere((id, _) => !keep.contains(id));
  }
  @override
  void initState() {
    super.initState();
    if (_index == 0)
      WidgetsBinding.instance.addPostFrameCallback((_) => _earlier());
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _earlier() async {
    if (_loading || _exhausted || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final earlier = await widget.loadEarlier();
      if (!mounted) return;
      // The user may have paged while the history request was in flight.
      final current = _images.isEmpty ? null : _images[_index].id;
      final ids = _images.map((image) => image.id).toSet();
      final added = earlier.where((image) => ids.add(image.id)).toList();
      setState(() {
        _exhausted = added.isEmpty;
        _images = [...added, ..._images];
        _index = current == null
            ? 0
            : _images.indexWhere((image) => image.id == current);
        _anchoring = added.isNotEmpty;
      });
      if (added.isNotEmpty) {
        // Wait until the new page count/layout exists before moving the offset.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_pages.hasClients) _pages.jumpToPage(_index);
          setState(() => _anchoring = false);
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '历史图片加载失败，点击重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => _images.isEmpty
      ? CupertinoPageScaffold(
          backgroundColor: CupertinoColors.black,
          navigationBar: CupertinoNavigationBar(
            backgroundColor: CupertinoColors.black,
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ),
          child: Center(
            child: _loading
                ? const CupertinoActivityIndicator()
                : CupertinoButton(
                    onPressed: _error == null ? null : _earlier,
                    child: Text(_error ?? '暂无可查看的图片'),
                  ),
          ),
        )
      : Stack(
          children: [
            NotificationListener<OverscrollNotification>(
              onNotification: (event) {
                if (event.overscroll < 0 && _index == 0) _earlier();
                return false;
              },
              child: PageView.builder(
                controller: _pages,
                physics: _zoomed || _anchoring
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(),
                itemCount: _images.length,
                findChildIndexCallback: (key) {
                  if (key is! ValueKey<String>) return null;
                  final index = _images.indexWhere(
                    (image) => image.id == key.value,
                  );
                  return index < 0 ? null : index;
                },
                onPageChanged: (index) {
                  if (_anchoring) return;
                  setState(() {
                    _index = index;
                    _zoomed = false;
                    _trimPreviews();
                  });
                  if (index == 0) _earlier();
                },
                itemBuilder: (context, index) {
                  final image = _images[index];
                  return FutureBuilder<Uint8List>(
                    key: ValueKey(image.id),
                    future: _previews.putIfAbsent(image.id, image.loadPreview),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData)
                        return CupertinoPageScaffold(
                          backgroundColor: CupertinoColors.black,
                          navigationBar: CupertinoNavigationBar(
                            backgroundColor: CupertinoColors.black,
                            transitionBetweenRoutes: false,
                            leading: CupertinoButton(
                              padding: EdgeInsets.zero,
                              onPressed: () => Navigator.pop(context),
                              child: const Text('关闭'),
                            ),
                          ),
                          child: Center(
                            child: snapshot.hasError
                                ? CupertinoButton(
                                    onPressed: () => setState(
                                      () => _previews.remove(image.id),
                                    ),
                                    child: const Text('图片加载失败，点击重试'),
                                  )
                                : const CupertinoActivityIndicator(),
                          ),
                        );
                      return ImageViewerPage(
                        key: ValueKey('viewer-${image.id}'),
                        previewBytes: snapshot.data!,
                        loadOriginal: image.loadOriginal,
                        originalSizeHint: image.originalSize,
                        onForward: image.onForward,
                        onForwardEdited: widget.onForwardEdited,
                        onFavorite: widget.onFavorite,
                        onZoomChanged: (value) {
                          if (mounted &&
                              _images[_index].id == image.id &&
                              _zoomed != value) {
                            setState(() => _zoomed = value);
                          }
                        },
                      );
                    },
                  );
                },
              ),
            ),
            Positioned(
              top: MediaQuery.paddingOf(context).top + 12,
              left: 90,
              right: 90,
              child: IgnorePointer(
                child: Text(
                  '${_index + 1} / ${_images.length}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 15,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
            if (_loading || _error != null)
              Positioned(
                left: 16,
                right: 16,
                top: MediaQuery.paddingOf(context).top + 56,
                child: Center(
                  child: _loading
                      ? const CupertinoActivityIndicator()
                      : CupertinoButton(
                          onPressed: _earlier,
                          child: Text(_error!),
                        ),
                ),
              ),
          ],
        );
}
