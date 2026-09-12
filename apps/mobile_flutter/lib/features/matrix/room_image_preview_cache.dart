import 'dart:typed_data';
import 'dart:convert';
import 'emoji_preview_cache.dart';
import 'media_cache.dart';
import 'media_memory_budget.dart';

/// Account-scoped chat previews. The existing authenticated encrypted store
/// owns persistent bytes and its disk quota; GIF originals are never flattened.
/// Keep one instance for a room/account lifetime and dispose on account change.
final class RoomImagePreviewCache {
  RoomImagePreviewCache(
      {required String accountId,
      required String roomId,
      String? memoryNamespace,
      int maxEntries = 256,
      int maxBytes = 64 * 1024 * 1024,
      Future<Uint8List?> Function(String)? read,
      Future<void> Function(String, Uint8List)? write,
      MediaMemoryCache? completedSessionMemory,
      String? sessionMemoryNamespace})
      : _accountId = accountId,
        _roomId = roomId,
        _memory = MediaMemoryCache(
            maxEntries: maxEntries,
            maxBytes: maxBytes,
            budget: sharedMediaMemoryBudget,
            accountNamespace: memoryNamespace ?? accountId),
        _completedSessionMemory = completedSessionMemory,
        _sessionMemoryNamespace =
            sessionMemoryNamespace ?? memoryNamespace ?? accountId {
    // A separate secure-storage namespace avoids sharing preview keys with
    // emoji media. No Matrix keys, plaintext files or network URLs are stored.
    final store = EncryptedEmojiPreviewStore('room-image-v1:$accountId');
    _read = read ?? store.read;
    _write = write ?? store.write;
  }
  final String _accountId;
  final String _roomId;
  MediaMemoryCache? _memory;
  final MediaMemoryCache? _completedSessionMemory;
  final String _sessionMemoryNamespace;
  late final Future<Uint8List?> Function(String) _read;
  late final Future<void> Function(String, Uint8List) _write;
  bool _disposed = false;
  // The existing store initializes a secure-storage key on first write. Keep
  // different room instances from racing key creation or quota sweeps. Reads
  // and source requests remain independent; only durable writes are serialized.
  static Future<void> _writes = Future<void>.value();
  static final _sessionMemory = MediaMemoryCache(
      maxEntries: 256,
      maxBytes: 32 * 1024 * 1024,
      budget: sharedMediaMemoryBudget);
  static bool _sessionClearerRegistered = false;

  /// Reuses only completed, bounded encoded bytes. Each page retains its own
  /// in-flight work, so disposing one page cannot poison a later reentry.
  factory RoomImagePreviewCache.forRoomSession({
    required String accountId,
    required String roomId,
    String? memoryNamespace,
    Future<Uint8List?> Function(String)? read,
    Future<void> Function(String, Uint8List)? write,
  }) {
    if (!_sessionClearerRegistered) {
      registerDecodedMediaCacheClearer(clearSessionMemory);
      _sessionClearerRegistered = true;
    }
    return RoomImagePreviewCache(
        accountId: accountId,
        roomId: roomId,
        memoryNamespace: memoryNamespace,
        read: read,
        write: write,
        completedSessionMemory: _sessionMemory,
        sessionMemoryNamespace: memoryNamespace);
  }

  /// Used by logout and resource-pressure clearing.
  static void clearSessionMemory() {
    _sessionMemory.clear();
  }

  Future<void> _persist(String key, Uint8List bytes, int generation) {
    // The shared encrypted store retains its newest file during eviction.
    // Include the AES-GCM nonce/tag overhead so one legacy original cannot
    // exceed the entire quota by itself.
    if (bytes.length > 64 * 1024 * 1024 - 28) return Future<void>.value();
    final work = _writes.then((_) async {
      if (!_disposed && _memory?.generation == generation) {
        await _write(key, bytes);
      }
    });
    _writes = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return work;
  }

  String _key(String eventId) =>
      jsonEncode([_accountId, _roomId, eventId, 'preview-v1']);
  String _sessionKey(String eventId) => jsonEncode(
      [_sessionMemoryNamespace, _roomId, _accountId, eventId, 'preview-v1']);
  Uint8List? get(String eventId) {
    if (_disposed) return null;
    final key = _key(eventId);
    return _memory?.get(key) ??
        _completedSessionMemory?.get(_sessionKey(eventId));
  }

  final _cachedReads = <String, Future<Uint8List?>>{};

  /// Local-only probe, safe during scrolling. A miss never invokes a source.
  Future<Uint8List?> readCached(String eventId) {
    if (_disposed) return Future<Uint8List?>.value();
    final key = _key(eventId);
    final cache = _memory!;
    final generation = cache.generation;
    final readKey = '$generation:$key';
    final memory = cache.get(key);
    if (memory != null) return Future<Uint8List?>.value(memory);
    final completed = _completedSessionMemory?.get(_sessionKey(eventId));
    if (completed != null) return Future<Uint8List?>.value(completed);
    return _cachedReads[readKey] ??= () async {
      try {
        final bytes = await _read(key);
        if (_disposed || cache.generation != generation) return null;
        final seeded = _memory!.get(key);
        if (seeded != null) return seeded;
        if (bytes != null && bytes.isNotEmpty) {
          final retained = _memory!.put(key, bytes);
          _completedSessionMemory?.put(_sessionKey(eventId), retained);
          return retained;
        }
        return null;
      } catch (_) {
        return null;
      }
    }()
        .whenComplete(() {
      _cachedReads.remove(readKey);
    });
  }

  /// Paint outgoing local bytes immediately, without per-message disk copies.
  /// The encrypted send gateway persists the canonical content object before
  /// upload. Transaction IDs are transient UI aliases, not durable content IDs;
  /// authoritative received/legacy previews still use load() persistence.
  void seed(String eventId, Uint8List bytes) {
    if (_disposed) return;
    final key = _key(eventId);
    final retained = _memory!.put(key, bytes);
    _completedSessionMemory?.put(_sessionKey(eventId), retained);
  }

  Future<Uint8List> load(String eventId, Future<Uint8List> Function() source) {
    final memory = _memory;
    if (memory == null) return Future.error(StateError('Image cache disposed'));
    final key = _key(eventId);
    final generation = memory.generation;
    return memory.putIfAbsent(key, () async {
      Uint8List? bytes = await readCached(eventId);
      if (_disposed || memory.generation != generation) {
        throw StateError('Image cache cleared');
      }
      if (bytes == null || bytes.isEmpty) {
        bytes = await source();
        if (_disposed || memory.generation != generation) {
          throw StateError('Image cache cleared');
        }
        try {
          await _persist(key, bytes, generation);
        } catch (_) {/* retain memory hit */}
      }
      if (_disposed || memory.generation != generation) {
        throw StateError('Image cache cleared');
      }
      _completedSessionMemory?.put(_sessionKey(eventId), bytes);
      return bytes;
    });
  }

  void dispose() {
    _disposed = true;
    _memory?.dispose();
    _memory = null;
    _cachedReads.clear();
  }
}
