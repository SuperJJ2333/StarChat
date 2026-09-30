import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'media_cache.dart';
import 'media_consumer_scope.dart';
import 'media_load_scheduler.dart';
import 'room_image_preview_cache.dart';
import 'video_poster_pipeline.dart';
import 'video_poster_session_cache.dart';

/// Optional capability: older/test AppHome capabilities remain compatible.
abstract interface class MatrixIncomingMediaCapability {
  IncomingMediaSource createIncomingMediaSource();
}

abstract interface class IncomingMediaSource {
  Stream<IncomingMediaCandidate> get candidates;
  Future<void> start();
  Future<void> dispose();
}

final class IncomingMediaCandidate {
  const IncomingMediaCandidate(
      {required this.originalKey,
      this.thumbnailKey,
      this.previewAccountId,
      this.release,
      required this.isVideo,
      required this.isAnimated,
      required this.prepare,
      required this.download});
  final MediaCacheKey originalKey;
  final MediaCacheKey? thumbnailKey;
  final String? previewAccountId;
  final bool isVideo, isAnimated;

  /// Register transfers before waiting for decoding/cache work. The OS can
  /// continue these transfers while Dart is suspended.
  final Future<void> Function() prepare;
  final Future<void> Function()? release;
  final Future<Uint8List> Function(bool thumbnail) download;
}

/// OS transfers register independently of the single background cache worker.
/// A foreground cache miss retains two scheduler slots and can join a shared
/// content flight. Queue bounds also bound native transfer staging.
final class IncomingMediaPrefetchService {
  IncomingMediaPrefetchService(this.source,
      {this.maxPending = 128,
      this.retryDelay = const Duration(seconds: 30),
      Future<void> Function(IncomingMediaCandidate)? persist})
      : _persistOverride = persist;
  final IncomingMediaSource source;
  final int maxPending;
  final Duration retryDelay;
  final Future<void> Function(IncomingMediaCandidate)? _persistOverride;
  final _pending = <String, IncomingMediaCandidate>{};
  final _done = <String>{};
  final _retryAt = <String, DateTime>{};
  final _attempts = <String, int>{};
  final _preparing = <String, Future<void>>{};
  final _previews = <String, RoomImagePreviewCache>{};
  VideoPosterSessionCache? _videoPreviews;
  final _scope = MediaConsumerScope(priority: MediaLoadPriority.background);
  StreamSubscription<IncomingMediaCandidate>? _subscription;
  Timer? _timer;
  bool _closed = false, _running = false;
  int get pendingCount => _pending.length;
  int get completedCount => _done.length;
  Future<void> start() async {
    if (_closed || _subscription != null) return;
    _subscription = source.candidates.listen(_add);
    _timer = Timer.periodic(retryDelay, (_) => retry());
    await source.start();
  }

  String _key(IncomingMediaCandidate item) => jsonEncode([
        item.originalKey.accountId,
        item.originalKey.roomId,
        item.originalKey.eventId,
        item.originalKey.identity,
        item.thumbnailKey?.identity,
        item.previewAccountId
      ]);
  void _add(IncomingMediaCandidate item) {
    if (_closed) return;
    final key = _key(item);
    if (_done.contains(key) ||
        _pending.containsKey(key) ||
        _pending.length >= maxPending) {
      return;
    }
    _pending[key] = item;
    _prepare(key, item);
    unawaited(_pump());
  }

  void _prepare(String key, IncomingMediaCandidate item) {
    if (_preparing.containsKey(key)) return;
    // Handle failure immediately even if another cache worker is waiting.
    _preparing[key] = item.prepare().catchError((Object _) {
      if (!_closed) _failed(key);
    });
  }

  void _failed(String key) {
    final attempts = (_attempts[key] ?? 0) + 1;
    if (attempts >= 5) {
      // Retain transient/offline work across several attempts, but never let
      // permanent failures reserve all queue slots for the session lifetime.
      final retired = _pending.remove(key);
      if (retired?.release != null) {
        unawaited(retired!.release!().catchError((Object _) {
          // Session revocation and native expiry remain the final cleanup.
        }));
      }
      _preparing.remove(key);
      _retryAt.remove(key);
      _attempts.remove(key);
      return;
    }
    _attempts[key] = attempts;
    _retryAt[key] =
        DateTime.now().add(retryDelay * (1 << (attempts - 1).clamp(0, 5)));
  }

  void retry() {
    if (_closed) return;
    for (final entry in _pending.entries.toList()) {
      final at = _retryAt[entry.key];
      if (at != null && !at.isAfter(DateTime.now())) {
        _retryAt.remove(entry.key);
        _preparing.remove(entry.key);
        _prepare(entry.key, entry.value);
      }
    }
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_closed || _running) return;
    _running = true;
    try {
      while (!_closed) {
        final ready =
            _pending.entries.where((entry) => !_retryAt.containsKey(entry.key));
        if (ready.isEmpty) break;
        final entry = ready.first;
        try {
          await _preparing[entry.key];
          if (_closed) break;
          if (!_pending.containsKey(entry.key) ||
              _retryAt.containsKey(entry.key)) {
            continue;
          }
          await _scope.run(() =>
              _persistOverride?.call(entry.value) ?? _persist(entry.value));
          if (_closed) break;
          await entry.value.release?.call();
          if (_closed) break;
          _pending.remove(entry.key);
          _preparing.remove(entry.key);
          _attempts.remove(entry.key);
          _done.add(entry.key);
          if (_done.length > 512) _done.remove(_done.first);
        } catch (_) {
          if (!_closed) _failed(entry.key);
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _persist(IncomingMediaCandidate item) async {
    final thumbnail = item.thumbnailKey;
    if (thumbnail != null) {
      final bytes =
          await loadMediaWithCache(thumbnail, () => item.download(true));
      if (_closed) return;
      if (item.isVideo) {
        // Match RoomPage's synchronous pipeline key and existing small-poster
        // budget; no video decoding or network request is needed here.
        if (bytes.isNotEmpty && bytes.length <= 512 * 1024) {
          await MediaCache.store(thumbnail.roomId,
              videoPosterCacheRefId(item.originalKey.eventId), bytes,
              accountId: thumbnail.accountId);
          if (_closed) return;
          final key = VideoPosterSessionCache.keyFor(
              accountId: thumbnail.accountId,
              roomId: thumbnail.roomId,
              mediaId: item.originalKey.eventId,
              mediaVersion: item.originalKey.eventId,
              spec: chatVideoPosterSpec);
          await (_videoPreviews ??= VideoPosterSessionCache.forRoomSession())
              .load(key, () async => bytes);
        }
      } else if (!item.isAnimated) {
        final previewAccount = item.previewAccountId ?? thumbnail.accountId;
        final key = jsonEncode([previewAccount, thumbnail.roomId]);
        final preview = _previews.putIfAbsent(
            key,
            () => RoomImagePreviewCache.forRoomSession(
                accountId: previewAccount,
                memoryNamespace: thumbnail.accountId,
                roomId: thumbnail.roomId));
        await preview.load(item.originalKey.eventId, () async => bytes);
        if (_previews.length > 32) {
          _previews.remove(_previews.keys.first)?.dispose();
        }
      }
    }
    await withMediaLoadPriority(MediaLoadPriority.background,
        () => loadMediaWithCache(item.originalKey, () => item.download(false)),
        isVideo: item.isVideo);
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _scope.cancel();
    _pending.clear();
    _preparing.clear();
    for (final preview in _previews.values) {
      preview.dispose();
    }
    _previews.clear();
    _videoPreviews?.disposeRoomSession();
    _videoPreviews = null;
    // Source timers and native authority must revoke synchronously, before an
    // asynchronous stream cancellation yields to widget disposal.
    final closingSource = source.dispose();
    await _subscription?.cancel();
    await closingSource;
  }
}
