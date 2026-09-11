import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import '../../features/matrix/media_consumer_scope.dart';
import '../../features/matrix/media_load_scheduler.dart';
import 'encrypted_media_view.dart';

class RoomGalleryImage {
  const RoomGalleryImage({
    required this.id,
    required this.loadPreview,
    required this.loadOriginal,
    required this.onForward,
    Object? sourceIdentity,
    this.originalSize,
  }) : sourceIdentity = sourceIdentity ?? id;
  final String id;
  final Object sourceIdentity;
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
    this.sourceScope,
  });
  final List<RoomGalleryImage> images;
  final String initialId;
  final Future<List<RoomGalleryImage>> Function() loadEarlier;
  final Future<bool> Function(Uint8List) onForwardEdited;
  final Future<void> Function(Uint8List) onFavorite;
  final Object? sourceScope;
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
  final _previews = <String, _GalleryPreview>{};
  final _historyIds = <String>{};
  int _epoch = 0;
  int _anchorRevision = 0;
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
    for (final entry in _previews.entries.toList()) {
      if (!keep.contains(entry.key)) {
        _previews.remove(entry.key);
        entry.value.scope.cancel();
      }
    }
  }

  Future<Uint8List> _previewFor(int index, MediaLoadPriority priority) {
    final image = _images[index];
    final existing = _previews[image.id];
    if (existing != null) {
      existing.scope.promote(priority);
      return existing.future;
    }
    final scope = MediaConsumerScope(priority: priority);
    final future = scope.run(image.loadPreview);
    _previews[image.id] = _GalleryPreview(scope, future, image.sourceIdentity);
    // initState starts the current image before FutureBuilder subscribes; a
    // side handler also keeps unseen neighbor failures from becoming uncaught.
    unawaited(future.catchError((_) => Uint8List(0)));
    return future;
  }

  void _warmPreviewWindow() {
    for (var index = _index - 1; index <= _index + 1; index++) {
      if (index < 0 || index >= _images.length) continue;
      _previewFor(
          index,
          index == _index
              ? MediaLoadPriority.interactive
              : MediaLoadPriority.prefetch);
    }
  }

  @override
  void initState() {
    super.initState();
    _warmPreviewWindow();
    if (_index == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _earlier());
    }
  }

  @override
  void didUpdateWidget(covariant RoomImageGalleryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final scopeChanged = oldWidget.sourceScope != widget.sourceScope;
    final initialChanged = oldWidget.initialId != widget.initialId;
    final currentId = _images.isEmpty ? null : _images[_index].id;
    final currentImage = _images.isEmpty ? null : _images[_index];
    final oldIndex = _index;
    late final List<RoomGalleryImage> updated;
    if (scopeChanged) {
      updated = List<RoomGalleryImage>.of(widget.images);
      _historyIds.clear();
    } else {
      final incomingIds = widget.images.map((image) => image.id).toSet();
      // Parent metadata is authoritative for its original window. Keep only
      // pages that this gallery appended from loadEarlier on the same source.
      updated = [
        for (final image in _images)
          if (_historyIds.contains(image.id) && !incomingIds.contains(image.id))
            image,
        ...widget.images,
      ];
      _historyIds.retainAll(updated.map((image) => image.id));
      _historyIds.removeAll(incomingIds);
    }
    final byId = {for (final image in updated) image.id: image};
    final currentReplacement = currentId == null ? null : byId[currentId];
    final currentSourceChanged = currentImage != null &&
        (currentReplacement == null ||
            currentReplacement.sourceIdentity != currentImage.sourceIdentity);
    if (scopeChanged) {
      _epoch++;
      _anchorRevision++;
      _anchoring = false;
      for (final preview in _previews.values) {
        preview.scope.cancel();
      }
      _previews.clear();
      _loading = false;
      _exhausted = false;
      _error = null;
    } else {
      for (final entry in _previews.entries.toList()) {
        final replacement = byId[entry.key];
        if (replacement == null ||
            replacement.sourceIdentity != entry.value.sourceIdentity) {
          _previews.remove(entry.key);
          entry.value.scope.cancel();
        }
      }
    }
    if (scopeChanged || initialChanged || currentSourceChanged) _zoomed = false;
    _images = updated;
    final preferredId =
        scopeChanged || initialChanged ? widget.initialId : currentId;
    final nextIndex = _images.indexWhere((image) => image.id == preferredId);
    final resolvedIndex = _images.isEmpty ? 0 : (nextIndex < 0 ? 0 : nextIndex);
    final changedIndex = resolvedIndex != oldIndex;
    _index = resolvedIndex;
    if (changedIndex) {
      _anchoring = true;
      final anchorRevision = ++_anchorRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || anchorRevision != _anchorRevision) return;
        if (_pages.hasClients) _pages.jumpToPage(_index);
        setState(() => _anchoring = false);
      });
    }
    _trimPreviews();
    _warmPreviewWindow();
    if (scopeChanged && _index == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _earlier());
    }
  }

  @override
  void dispose() {
    for (final preview in _previews.values) {
      preview.scope.cancel();
    }
    _previews.clear();
    _pages.dispose();
    super.dispose();
  }

  Future<void> _earlier() async {
    if (_loading || _exhausted || !mounted) return;
    final epoch = _epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final earlier = await widget.loadEarlier();
      if (!mounted || epoch != _epoch) return;
      // The user may have paged while the history request was in flight.
      final current = _images.isEmpty ? null : _images[_index].id;
      final ids = _images.map((image) => image.id).toSet();
      final added = earlier.where((image) => ids.add(image.id)).toList();
      setState(() {
        _exhausted = added.isEmpty;
        _images = [...added, ..._images];
        _historyIds.addAll(added.map((image) => image.id));
        _index = current == null
            ? 0
            : _images.indexWhere((image) => image.id == current);
        _anchoring = added.isNotEmpty;
      });
      _trimPreviews();
      _warmPreviewWindow();
      if (added.isNotEmpty) {
        // Wait until the new page count/layout exists before moving the offset.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || epoch != _epoch) return;
          if (_pages.hasClients) _pages.jumpToPage(_index);
          setState(() => _anchoring = false);
        });
      }
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() => _error = '历史图片加载失败，点击重试');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
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
                  _warmPreviewWindow();
                  if (index == 0) _earlier();
                },
                itemBuilder: (context, index) {
                  final image = _images[index];
                  final preview = _previews[image.id];
                  return KeyedSubtree(
                    key: ValueKey(image.id),
                    child: preview == null
                        ? const SizedBox.expand()
                        : FutureBuilder<Uint8List>(
                            key: ValueKey((
                              widget.sourceScope,
                              image.id,
                              image.sourceIdentity,
                            )),
                            future: preview.future,
                            builder: (context, snapshot) {
                              if (!snapshot.hasData) {
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
                                            onPressed: () => setState(() {
                                              _previews
                                                  .remove(image.id)
                                                  ?.scope
                                                  .cancel();
                                              _warmPreviewWindow();
                                            }),
                                            child: const Text('图片加载失败，点击重试'),
                                          )
                                        : const CupertinoActivityIndicator(),
                                  ),
                                );
                              }
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
                          ),
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

final class _GalleryPreview {
  const _GalleryPreview(this.scope, this.future, this.sourceIdentity);
  final MediaConsumerScope scope;
  final Future<Uint8List> future;
  final Object sourceIdentity;
}
