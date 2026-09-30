import 'dart:async';
import '../../core/native_media_download.dart';
import '../../ui/moments/moment_media_cache.dart';
import '../matrix/incoming_media_prefetch.dart';
import '../matrix/media_cache.dart';
import '../matrix/media_index.dart';

/// Reads the already-authorized latest feed without consuming display/unread
/// state. This source lives with AppHome, independently of MomentsPage.
final class MomentsMediaPrefetchSource implements IncomingMediaSource {
  MomentsMediaPrefetchSource(
      {required this.accountId,
      required this.trustedOrigin,
      required this.load,
      this.interval = const Duration(minutes: 1),
      NativeMediaDownloadSession? downloads})
      : _downloads = downloads ?? NativeMediaDownloadSession(accountId);
  final String accountId, trustedOrigin;
  final Future<Map<String, dynamic>> Function() load;
  final Duration interval;
  final NativeMediaDownloadSession _downloads;
  final _events = StreamController<IncomingMediaCandidate>.broadcast();
  Timer? _timer;
  Future<void>? _refreshing;
  bool _closed = false;
  @override
  Stream<IncomingMediaCandidate> get candidates => _events.stream;
  @override
  Future<void> start() async {
    if (_closed) return;
    _timer ??= Timer.periodic(interval, (_) => unawaited(refresh()));
    await refresh();
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    if (_closed) return;
    try {
      final response = await load();
      if (_closed) return;
      for (final raw in (response['items'] as List? ?? const []).take(30)) {
        if (raw is! Map || raw['kind'] == 'AD') continue;
        for (final pair in const [
          ('image_urls', 'image_cache_keys', false),
          ('video_urls', 'video_cache_keys', true)
        ]) {
          final urls = raw[pair.$1];
          final keys = raw[pair.$2];
          if (urls is! List || keys is! List) continue;
          for (var i = 0; i < urls.length && i < keys.length && i < 9; i++) {
            if (urls[i] is! String || keys[i] is! String) continue;
            _emit(urls[i] as String, keys[i] as String, pair.$3);
          }
        }
      }
    } catch (_) {
      /* A later refresh retries permission, transport and offline errors. */
    }
  }

  void _emit(String url, String digest, bool video) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      // Validate before constructing providers or enqueuing any native work.
      final probe = NativeMediaRequest(
          id: digest,
          url: uri,
          trustedOrigin: trustedOrigin,
          kind: 'moments',
          mediaType: video ? 'video' : 'image',
          maxBytes: video ? 20 * 1024 * 1024 : 8 * 1024 * 1024);
      final provider = MomentMediaCache.imageProvider(url,
          cacheKey: digest,
          accountKey: 'matrix:$accountId',
          trustedOrigin: trustedOrigin);
      final key = MediaCacheKey(
          accountId: accountId,
          roomId: 'moments',
          eventId: provider.cacheKey!,
          variant: video ? MediaVariantKind.video : MediaVariantKind.body);
      final request = NativeMediaRequest(
          id: key.identity,
          url: probe.url,
          trustedOrigin: trustedOrigin,
          kind: 'moments',
          mediaType: video ? 'video' : 'image',
          maxBytes: probe.maxBytes);
      final owner = Object();
      final generation = MediaCache.accountGeneration(accountId);
      void check() {
        if (_closed || generation != MediaCache.accountGeneration(accountId)) {
          throw StateError('Moments media account revoked');
        }
      }

      _events.add(IncomingMediaCandidate(
          originalKey: key,
          isVideo: video,
          isAnimated: false,
          prepare: () async {
            check();
            final cached = await MediaCache.cached('moments', key.eventId,
                accountId: accountId);
            check();
            if (cached == null) await _downloads.prepare(request, owner: owner);
          },
          release: () => _downloads.release(request, owner: owner),
          download: (_) async {
            check();
            final bytes = await _downloads.download(request);
            check();
            return bytes;
          }));
    } on ArgumentError {/* Untrusted sources never reach native networking. */}
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    _timer?.cancel();
    await _downloads.dispose();
    await _events.close();
  }
}
