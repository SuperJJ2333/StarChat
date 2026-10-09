import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'maintenance_activity.dart';

/// Application-level decoded-image limits. Live images, codecs, native video
/// buffers and GPU memory still require separate measurement and lifecycle limits.
final class MediaResourcePolicy with WidgetsBindingObserver {
  MediaResourcePolicy({required this.clearEncoded});
  final VoidCallback clearEncoded;
  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    MaintenanceActivity.instance.install();
    PaintingBinding.instance.imageCache
      ..maximumSize = 512
      ..maximumSizeBytes = 64 * 1024 * 1024;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didHaveMemoryPressure() {
    clearEncoded();
    PaintingBinding.instance.imageCache.clear();
  }

  void dispose() {
    if (!_installed) return;
    _installed = false;
    WidgetsBinding.instance.removeObserver(this);
  }
}

/// ImageCache counts decoded pixels, while MemoryImage keys also own encoded
/// bytes. Small keys fit at most 512 * 64 KiB; larger payloads are retained only
/// by live consumers, then their keepAlive entry is removed without clearing
/// disk data or invalidating another widget still displaying the same image.
const maxRetainedEncodedImageBytes = 64 * 1024;

final class EncodedBudgetResizeImage extends ResizeImage {
  EncodedBudgetResizeImage(Uint8List bytes, {required int maxEdge})
      : _encodedBytes = bytes.length,
        super(MemoryImage(bytes),
            width: maxEdge, height: maxEdge, policy: ResizeImagePolicy.fit);
  final int _encodedBytes;
  @override
  ImageStreamCompleter loadImage(
      ResizeImageKey key, ImageDecoderCallback decode) {
    final completer = super.loadImage(key, decode);
    if (_encodedBytes > maxRetainedEncodedImageBytes) {
      completer.addOnLastListenerRemovedCallback(() {
        scheduleMicrotask(() {
          // A reattached consumer still owns the live completer. Only release
          // the cache's optional keepAlive handle, never its live entry.
          PaintingBinding.instance.imageCache.evict(key, includeLive: false);
        });
      });
    }
    return completer;
  }
}
