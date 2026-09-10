import 'package:flutter/widgets.dart';

/// Application-level decoded-image limits. Live images, codecs, native video
/// buffers and GPU memory still require separate measurement and lifecycle limits.
final class MediaResourcePolicy with WidgetsBindingObserver {
  MediaResourcePolicy({required this.clearEncoded});
  final VoidCallback clearEncoded;
  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    PaintingBinding.instance.imageCache
      ..maximumSize = 512
      ..maximumSizeBytes = 64 * 1024 * 1024;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didHaveMemoryPressure() {
    clearEncoded();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  void dispose() {
    if (!_installed) return;
    _installed = false;
    WidgetsBinding.instance.removeObserver(this);
  }
}
