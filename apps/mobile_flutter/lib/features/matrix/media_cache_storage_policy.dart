import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Apply the native fixed-directory policy once. Failure preserves files and is
/// retried on the next foreground lifecycle, never on each media write.
final class MediaCacheStoragePolicy with WidgetsBindingObserver {
  static final shared = MediaCacheStoragePolicy();
  static const _channel = MethodChannel('chatflow/media_storage');
  bool _registered = false;
  bool _attempted = false;
  bool _running = false;
  bool _applied = false;

  void ensureScheduled() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    if (!_registered) {
      WidgetsBinding.instance.addObserver(this);
      _registered = true;
    }
    if (!_attempted) unawaited(_apply());
  }

  Future<void> _apply() async {
    if (_running || _applied) return;
    _attempted = true;
    _running = true;
    try {
      final result = await _channel
          .invokeMapMethod<String, Object?>(
            'documentsChatMediaPolicy',
          )
          .timeout(const Duration(seconds: 5));
      _applied =
          result?['protected'] == true && result?['backupExcluded'] == true;
    } on Exception {
      // Native policy unavailable: preserve the existing offline cache.
    } finally {
      _running = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_applied) unawaited(_apply());
  }

  void dispose() {
    if (_registered) WidgetsBinding.instance.removeObserver(this);
    _registered = false;
  }
}
