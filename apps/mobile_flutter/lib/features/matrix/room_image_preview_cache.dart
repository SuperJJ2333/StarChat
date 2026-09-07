import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import 'emoji_preview_cache.dart';
import 'media_cache.dart';

/// Account-scoped chat previews. The existing authenticated encrypted store
/// owns persistent bytes and its disk quota; GIF originals are never flattened.
/// Keep one instance for a room/account lifetime and dispose on account change.
final class RoomImagePreviewCache {
  RoomImagePreviewCache(
      {required String accountId,
      required String roomId,
      int maxEntries = 256,
      int maxBytes = 64 * 1024 * 1024,
      Future<Uint8List?> Function(String)? read,
      Future<void> Function(String, Uint8List)? write})
      : _accountId = accountId,
        _roomId = roomId,
        _memory = MediaMemoryCache(maxEntries: maxEntries, maxBytes: maxBytes) {
    // A separate secure-storage namespace avoids sharing preview keys with
    // emoji media. No Matrix keys, plaintext files or network URLs are stored.
    final store = EncryptedEmojiPreviewStore('room-image-v1:$accountId');
    _read = read ?? store.read;
    _write = write ?? store.write;
  }
  final String _accountId;
  final String _roomId;
  MediaMemoryCache? _memory;
  late final Future<Uint8List?> Function(String) _read;
  late final Future<void> Function(String, Uint8List) _write;
  bool _disposed = false;
  // The existing store initializes a secure-storage key on first write. Keep
  // different room instances from racing key creation or quota sweeps. Reads
  // and source requests remain independent; only durable writes are serialized.
  static Future<void> _writes = Future<void>.value();

  Future<void> _persist(String key, Uint8List bytes) {
    // The shared encrypted store retains its newest file during eviction.
    // Include the AES-GCM nonce/tag overhead so one legacy original cannot
    // exceed the entire quota by itself.
    if (bytes.length > 64 * 1024 * 1024 - 28) return Future<void>.value();
    final work = _writes.then((_) async {
      if (!_disposed) await _write(key, bytes);
    });
    _writes = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return work;
  }

  String _key(String eventId) =>
      jsonEncode([_accountId, _roomId, eventId, 'preview-v1']);
  Uint8List? get(String eventId) => _memory?.get(_key(eventId));
  final _cachedReads = <String, Future<Uint8List?>>{};

  /// Local-only probe, safe during scrolling. A miss never invokes a source.
  Future<Uint8List?> readCached(String eventId) {
    if (_disposed) return Future<Uint8List?>.value();
    final key = _key(eventId);
    final memory = _memory!.get(key);
    if (memory != null) return Future<Uint8List?>.value(memory);
    return _cachedReads[key] ??= () async {
      try {
        final bytes = await _read(key);
        if (_disposed) return null;
        final seeded = _memory!.get(key);
        if (seeded != null) return seeded;
        if (bytes != null && bytes.isNotEmpty) {
          _memory!.put(key, bytes);
          return bytes;
        }
        return null;
      } catch (_) {
        return null;
      }
    }()
        .whenComplete(() {
      _cachedReads.remove(key);
    });
  }

  /// Paint outgoing local bytes in the same frame as the local message. Disk
  /// work is deferred and best effort, while source flights remain intact.
  void seed(String eventId, Uint8List bytes) {
    if (_disposed) return;
    final key = _key(eventId);
    _memory!.put(key, bytes);
    unawaited(_persist(key, bytes).catchError((Object _) {}));
  }

  Future<Uint8List> load(String eventId, Future<Uint8List> Function() source) {
    final memory = _memory;
    if (memory == null) return Future.error(StateError('Image cache disposed'));
    final key = _key(eventId);
    return memory.putIfAbsent(key, () async {
      Uint8List? bytes = await readCached(eventId);
      if (_disposed) throw StateError('Image cache disposed');
      if (bytes == null || bytes.isEmpty) {
        bytes = await source();
        if (_disposed) throw StateError('Image cache disposed');
        try {
          await _persist(key, bytes);
        } catch (_) {/* retain memory hit */}
      }
      if (_disposed) throw StateError('Image cache disposed');
      return bytes;
    });
  }

  void dispose() {
    _disposed = true;
    _memory = null;
    _cachedReads.clear();
  }
}
