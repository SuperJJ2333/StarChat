import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Decodes enough pixels to cover a square tile without enlarging the source.
/// Originals, authorization and disk caching remain owned by [imageProvider].
final class MomentThumbnailProvider
    extends ImageProvider<MomentThumbnailProvider> {
  const MomentThumbnailProvider(this.imageProvider, {required this.extent})
      : assert(extent > 0);

  final CachedNetworkImageProvider imageProvider;
  final int extent;
  static const maximumPixels = 1024 * 1024;
  static const maximumEdge = 4096;

  @override
  Future<MomentThumbnailProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      MomentThumbnailProvider key, ImageDecoderCallback decode) {
    final original = key.imageProvider;
    final completer = original.loadImage(original, (buffer, {getTargetSize}) {
      assert(getTargetSize == null);
      return decode(buffer, getTargetSize: (width, height) {
        final coverScale = key.extent / math.min(width, height);
        final pixelScale = math.sqrt(maximumPixels / (width * height));
        final edgeScale = maximumEdge / math.max(width, height);
        final scale = math.min(
            1.0, math.min(coverScale, math.min(pixelScale, edgeScale)));
        return ui.TargetImageSize(
            width: math.max(1, (width * scale).floor()),
            height: math.max(1, (height * scale).floor()));
      });
    });
    // The delegated provider only knows its original key. A failed thumbnail
    // must also leave the resized cache so a later resolve can load again.
    completer.addEphemeralErrorListener((_, __) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }

  @override
  bool operator ==(Object other) =>
      other is MomentThumbnailProvider &&
      imageProvider == other.imageProvider &&
      extent == other.extent;

  @override
  int get hashCode =>
      Object.hash(MomentThumbnailProvider, imageProvider, extent);
}
