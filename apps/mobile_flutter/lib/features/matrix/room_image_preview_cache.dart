import 'dart:typed_data';
import 'dart:convert';
import 'emoji_preview_cache.dart';
import 'media_cache.dart';
import 'content_addressed_media.dart' show verifyMediaContent;
import 'media_consumer_scope.dart';
import 'media_memory_budget.dart';

const int roomImagePrewarmMaxBytes = 512 * 1024;

/// A local-only original probe. The caller owns event/lease authorization;
/// cache presence alone is never an authorization grant. No network fallback,
/// retained original map, or in-flight map is created by this reader.
Future<Uint8List?> readCachedImageOriginal({
  required MediaCacheKey key,
  required bool Function() isCurrent,
}) async {
  final scope = MediaConsumerScope.current;
  final generation = MediaCache.accountGeneration(key.accountId);
  bool current() =>
      isCurrent() &&
      (scope == null || scope.isActive) &&
      generation == MediaCache.accountGeneration(key.accountId);
  if (!current()) return null;
  final file = await MediaCache.cached(key.roomId, key.eventId,
      accountId: key.accountId, contentSha256: key.contentSha256);
  if (file == null || !current()) return null;
  final bytes = await file.readAsBytes();
  if (!current()) return null;
  // Verify the actual read, including legacy objects whose hash is in the
  // content-addressed filename rather than the event metadata.
  verifyMediaContent(
      bytes, key.contentSha256 ?? file.uri.pathSegments.last.split('.').first);
  return bytes;
}

/// A legacy preview key may contain the full original. Only a declared,
/// static thumbnail may be probed ahead of the visible bubble, and its local
/// reader must check the file length before decoding it into memory.
Future<Uint8List?> prewarmDeclaredImagePreview({
  required bool hasDeclaredThumbnail,
  required bool animated,
  required Future<Uint8List?> Function(int maxBytes) readCached,
}) async {
  if (!hasDeclaredThumbnail || animated) return null;
  final bytes = await readCached(roomImagePrewarmMaxBytes);
  return bytes != null && bytes.length <= roomImagePrewarmMaxBytes
      ? bytes
      : null;
}

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

  /// Counts actual cache probes and source invocations, never joined flights.
  int memoryHits = 0;
  int diskHits = 0;
  int sourceLoads = 0;
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
    final bytes =
        _memory?.get(key) ?? _completedSessionMemory?.get(_sessionKey(eventId));
    if (bytes != null) memoryHits++;
    return bytes;
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
    if (memory != null) {
      memoryHits++;
      return Future<Uint8List?>.value(memory);
    }
    final completed = _completedSessionMemory?.get(_sessionKey(eventId));
    if (completed != null) {
      memoryHits++;
      return Future<Uint8List?>.value(completed);
    }
    return _cachedReads[readKey] ??= () async {
      try {
        final bytes = await _read(key);
        if (_disposed || cache.generation != generation) return null;
        final seeded = _memory!.get(key);
        if (seeded != null) return seeded;
        if (bytes != null && bytes.isNotEmpty) {
          final retained = _memory!.put(key, bytes);
          _completedSessionMemory?.put(_sessionKey(eventId), retained);
          diskHits++;
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
        sourceLoads++;
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
