import 'package:flutter/widgets.dart';

/// Keeps only immediate off-screen image requests alive until their first frame.
final class MomentImagePrefetcher {
  MomentImagePrefetcher(this._providerFor);

  final ImageProvider Function(int index) _providerFor;
  final _leases = <Object, _ImagePrefetchLease>{};
  final _completed = <Object>{};

  void update({
    required int currentIndex,
    required int itemCount,
    required Object Function(int index) identityAt,
  }) {
    final wanted = <Object, int>{
      for (final index in [currentIndex - 1, currentIndex + 1])
        if (index >= 0 && index < itemCount) identityAt(index): index,
    };
    for (final identity in _leases.keys.toList()) {
      if (!wanted.containsKey(identity)) {
        _leases.remove(identity)!.dispose();
      }
    }
    _completed.removeWhere((identity) => !wanted.containsKey(identity));
    for (final entry in wanted.entries) {
      final identity = entry.key;
      final index = entry.value;
      if (_leases.containsKey(identity) || _completed.contains(identity)) {
        continue;
      }
      final stream = _providerFor(index).resolve(ImageConfiguration.empty);
      late final ImageStreamListener listener;
      listener = ImageStreamListener((image, _) {
        stream.removeListener(listener);
        _leases.remove(identity);
        _completed.add(identity);
        image.dispose();
      }, onError: (_, __) {
        stream.removeListener(listener);
        _leases.remove(identity);
      });
      _leases[identity] = _ImagePrefetchLease(stream, listener);
      stream.addListener(listener);
    }
  }

  void dispose() {
    for (final lease in _leases.values) {
      lease.dispose();
    }
    _leases.clear();
    _completed.clear();
  }
}

final class _ImagePrefetchLease {
  const _ImagePrefetchLease(this.stream, this.listener);
  final ImageStream stream;
  final ImageStreamListener listener;
  void dispose() => stream.removeListener(listener);
}
