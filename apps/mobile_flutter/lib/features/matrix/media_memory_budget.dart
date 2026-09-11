import 'dart:typed_data';

final class _ContentBytes {
  _ContentBytes(this.bytes);
  final Uint8List bytes;
  int references = 0;
}

final class _BudgetReference {
  _BudgetReference(this.content, this.evict);
  final (Object, String) content;
  final void Function() evict;
}

/// One LRU budget for encoded bytes across room previews, images and videos.
/// Content is interned only inside the same account namespace, after callers
/// verify its digest and own an immutable byte view.
final class MediaMemoryBudget {
  MediaMemoryBudget({this.maxBytes = 32 * 1024 * 1024, this.maxEntries = 512}) {
    if (maxBytes < 0 || maxEntries < 0) {
      throw ArgumentError('Invalid cache budget');
    }
  }
  final int maxBytes, maxEntries;
  final _entries = <(Object, String), _BudgetReference>{};
  final _objects = <(Object, String), _ContentBytes>{};
  final _owners = <Object, void Function()>{};
  int _bytes = 0;
  int get totalBytes => _bytes;
  int get entryCount => _entries.length;

  void register(Object owner, void Function() invalidate) =>
      _owners[owner] = invalidate;
  void unregister(Object owner) => _owners.remove(owner);

  Uint8List? find(Object namespace, String verifiedDigest) =>
      _objects[(namespace, verifiedDigest)]?.bytes;

  void retain(Object owner, String key, Object namespace, String verifiedDigest,
      Uint8List bytes, void Function() evict) {
    forget(owner, key);
    final identity = (namespace, verifiedDigest);
    final object = _objects.putIfAbsent(identity, () {
      _bytes += bytes.length;
      return _ContentBytes(bytes);
    });
    object.references++;
    _entries[(owner, key)] = _BudgetReference(identity, evict);
    while (_entries.isNotEmpty &&
        (_bytes > maxBytes || _entries.length > maxEntries)) {
      final oldest = _entries.keys.first;
      final callback = _entries[oldest]!.evict;
      forget(oldest.$1, oldest.$2);
      callback();
    }
  }

  void touch(Object owner, String key) {
    final entry = _entries.remove((owner, key));
    if (entry != null) _entries[(owner, key)] = entry;
  }

  void forget(Object owner, String key) {
    final entry = _entries.remove((owner, key));
    if (entry == null) return;
    final object = _objects[entry.content]!;
    if (--object.references == 0) {
      _objects.remove(entry.content);
      _bytes -= object.bytes.length;
    }
  }

  void clear() {
    // Include owners with only pending loads, so a clear cannot be undone by
    // a late completion that had not registered a resident entry yet.
    for (final invalidate in _owners.values.toList()) {
      invalidate();
    }
    final callbacks = _entries.values.map((entry) => entry.evict).toList();
    _entries.clear();
    _objects.clear();
    _bytes = 0;
    for (final evict in callbacks) {
      evict();
    }
  }
}

final sharedMediaMemoryBudget = MediaMemoryBudget();
