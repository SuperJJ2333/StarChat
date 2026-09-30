import 'dart:collection';

typedef DecryptedPreviewKey = (String?, String, String);

/// A disposable presentation cache, never the authoritative message store.
/// The weight budgets Dart JSON/string retention conservatively; it is not RSS.
final class DecryptedPreviewCache
    extends MapBase<DecryptedPreviewKey, Map<String, dynamic>> {
  DecryptedPreviewCache({
    this.maximumEntries = 1024,
    this.maximumEntriesPerRoom = 32,
    this.maximumWeight = 4 * 1024 * 1024,
  }) : assert(maximumEntries > 0 &&
            maximumEntriesPerRoom > 0 &&
            maximumWeight > 0);

  final int maximumEntries;
  final int maximumEntriesPerRoom;
  final int maximumWeight;
  final _entries = <DecryptedPreviewKey, Map<String, dynamic>>{};
  final _weights = <DecryptedPreviewKey, int>{};
  final _heads = <DecryptedPreviewKey>{};
  int retainedWeight = 0;

  @override
  Iterable<DecryptedPreviewKey> get keys => _entries.keys;

  @override
  Map<String, dynamic>? operator [](Object? key) => _entries[key];

  @override
  void operator []=(DecryptedPreviewKey key, Map<String, dynamic> value) {
    remember(key, value);
  }

  void remember(DecryptedPreviewKey key, Map<String, dynamic> value,
      {String? headEventId}) {
    final wasHead = _heads.contains(key);
    remove(key);
    final weight = _weight(value) +
        _weight(key.$1) +
        _weight(key.$2) +
        _weight(key.$3) +
        64;
    // Oversized events still reach the SDK and consumers, without pinning an
    // additional full-event copy for a one-line conversation preview.
    if (weight > maximumWeight) return;
    _entries[key] = value;
    _weights[key] = weight;
    retainedWeight += weight;
    if (headEventId != null) {
      _heads.removeWhere((other) => other.$1 == key.$1 && other.$2 == key.$2);
      final head = (key.$1, key.$2, headEventId);
      if (_entries.containsKey(head)) _heads.add(head);
    } else if (wasHead) {
      _heads.add(key);
    }
    final roomKeys = _entries.keys
        .where((other) => other.$1 == key.$1 && other.$2 == key.$2)
        .toList(growable: false);
    final victims = roomKeys.where((other) => !_heads.contains(other)).toList();
    for (var i = 0; i < roomKeys.length - maximumEntriesPerRoom; i++) {
      remove(victims[i]);
    }
    while (_entries.length > maximumEntries || retainedWeight > maximumWeight) {
      remove(_entries.keys.firstWhere((other) => !_heads.contains(other),
          orElse: () => _entries.keys.first));
    }
  }

  @override
  Map<String, dynamic>? remove(Object? key) {
    _heads.remove(key);
    retainedWeight -= _weights.remove(key) ?? 0;
    return _entries.remove(key);
  }

  @override
  void clear() {
    _entries.clear();
    _weights.clear();
    _heads.clear();
    retainedWeight = 0;
  }

  static int _weight(Object? value) {
    if (value is String) return 32 + value.length * 2;
    if (value is Map) {
      var weight = 64;
      for (final entry in value.entries) {
        weight += 48 + _weight(entry.key) + _weight(entry.value);
      }
      return weight;
    }
    if (value is List) {
      return 32 + value.fold<int>(0, (sum, item) => sum + 8 + _weight(item));
    }
    return 16;
  }
}
