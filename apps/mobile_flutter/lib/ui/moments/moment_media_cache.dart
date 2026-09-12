import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../../features/matrix/media_cache.dart';
import '../foundation/retained_image_cache_manager.dart';

/// Shared by feed thumbnails and the full-screen viewer. Flutter retains decoded
/// frames in its bounded image cache; originals are also reusable from disk.
class _MomentImageProvider extends CachedNetworkImageProvider {
  const _MomentImageProvider(super.url, {super.cacheKey, this.source});
  final _MomentMediaSource? source;

  // Comparing identities must not initialize platform disk storage.
  @override
  BaseCacheManager get cacheManager {
    final source = this.source;
    if (source != null) MomentMediaCache._rememberSource(source);
    return MomentMediaCache.manager;
  }
}

abstract final class MomentMediaCache {
  /// Called only after a failed decode/load. Remove a damaged disk entry as
  /// well as the failed decoded frame so the explicit retry can recover.
  static Future<void> retry(CachedNetworkImageProvider provider) async {
    final key = provider.cacheKey ?? provider.url;
    final source = _sources[key];
    if (source != null) {
      await MediaCache.removeReference('moments', key,
          accountId: source.accountKey);
    }
    await manager.removeFile(key);
    await provider.evict();
  }

  static Object imageIdentity(String url,
          {String? cacheKey, String? accountKey, String? trustedOrigin}) =>
      (
        accountKey,
        trustedOrigin,
        imageProvider(url,
                    cacheKey: cacheKey,
                    accountKey: accountKey,
                    trustedOrigin: trustedOrigin)
                .cacheKey ??
            url,
      );
  static const diskTtl = Duration(days: 7);
  static const maximumDiskEntries = 200;
  static const maximumConcurrentDownloads = 3;
  static final _sources = <String, _MomentMediaSource>{};
  static bool _registeredAccountClearer = false;

  static final CacheManager manager = _MomentMediaCacheManager(Config(
    'changliao-moments-media-v1',
    stalePeriod: diskTtl,
    maxNrOfCacheObjects: maximumDiskEntries,
    fileService: HttpFileService()
      ..concurrentFetches = maximumConcurrentDownloads,
  ));

  static CachedNetworkImageProvider imageProvider(
    String url, {
    String? cacheKey,
    String? accountKey,
    String? trustedOrigin,
  }) {
    final uri = Uri.tryParse(url);
    final validKey =
        cacheKey != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(cacheKey);
    final trusted = uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        uri.origin == trustedOrigin &&
        RegExp(r'^/api/v1/(?:profile/avatar|moments/media)/content/[^/]+$')
            .hasMatch(uri.path);
    // Read-only server digests are not authorization. Require the verified
    // account and exact API origin, never decode tokens or strip URL parts.
    final scoped = validKey &&
            trusted &&
            accountKey != null &&
            accountKey.isNotEmpty
        ? 'moments-origin-account-v1:${sha256.convert(utf8.encode(jsonEncode([
                uri.origin,
                accountKey,
                cacheKey
              ])))}'
        : accountKey != null && accountKey.isNotEmpty
            ? 'moments-url-account-v1:${sha256.convert(utf8.encode(jsonEncode([
                    accountKey,
                    url,
                  ])))}'
            : null;
    final mediaAccount =
        accountKey == null ? null : _rawMatrixAccount(accountKey);
    _MomentMediaSource? source;
    if (scoped != null &&
        validKey &&
        trusted &&
        mediaAccount != null &&
        RegExp(r'^/api/v1/moments/media/content/[^/]+$').hasMatch(uri.path)) {
      source = _MomentMediaSource(
          mediaAccount,
          scoped,
          _legacyUrlKey(accountKey!, url),
          MediaCache.accountGeneration(mediaAccount));
      _rememberSource(source);
      if (!_registeredAccountClearer) {
        registerAccountMediaCacheClearer(clearAccount);
        _registeredAccountClearer = true;
      }
    }
    return _MomentImageProvider(url, cacheKey: scoped, source: source);
  }

  static String? _rawMatrixAccount(String accountKey) {
    final raw = accountKey.startsWith('matrix:')
        ? accountKey.substring('matrix:'.length)
        : accountKey;
    return raw.isEmpty ? null : raw;
  }

  static String _legacyUrlKey(String accountKey, String url) =>
      'moments-url-account-v1:${sha256.convert(utf8.encode(jsonEncode([
            accountKey,
            url,
          ])))}';

  static void _rememberSource(_MomentMediaSource source) {
    final current = _sources[source.cacheKey];
    if (current != null && current.generation > source.generation) return;
    _sources.remove(source.cacheKey);
    _sources[source.cacheKey] = source;
    while (_sources.length > maximumDiskEntries) {
      _sources.remove(_sources.keys.first);
    }
  }

  static Future<void> clearAccount(String accountKey) async {
    final keys = <String>[];
    for (final entry in _sources.entries) {
      final key = entry.key;
      final source = entry.value;
      final matches = source.accountKey == accountKey;
      if (!matches) continue;
      source.revoke();
      keys.add(key);
    }
    for (final key in keys) {
      await manager.removeFile(key);
    }
  }
}

final class _MomentMediaSource {
  _MomentMediaSource(
      this.accountKey, this.cacheKey, this.legacyCacheKey, this.generation);
  final String accountKey;
  final String cacheKey;
  final String legacyCacheKey;
  final int generation;
  bool _revoked = false;

  void revoke() => _revoked = true;

  void ensureCurrent() {
    if (_revoked || generation != MediaCache.accountGeneration(accountKey)) {
      throw StateError('Moments media account was cleared');
    }
  }

  bool get isCurrent =>
      !_revoked && generation == MediaCache.accountGeneration(accountKey);
}

/// Moves an already-authorized Moments response into the same verified,
/// account-local object store as chat. The server reference hash remains only
/// an alias: MediaCache calculates the actual byte digest after download.
final class _MomentMediaCacheManager extends RetainedImageCacheManager {
  _MomentMediaCacheManager(super.config);
  static final _files = LocalFileSystem();

  @override
  Stream<FileResponse> getFileStream(String url,
      {String? key,
      Map<String, String>? headers,
      bool withProgress = false}) async* {
    final effectiveKey = key ?? url;
    final source = MomentMediaCache._sources[effectiveKey];
    if (source == null) {
      yield* super.getFileStream(url,
          key: effectiveKey, headers: headers, withProgress: withProgress);
      return;
    }
    source.ensureCurrent();
    final local = await MediaCache.cached('moments', source.cacheKey,
        accountId: source.accountKey);
    source.ensureCurrent();
    if (local != null) {
      yield FileInfo(_files.file(local.path), FileSource.Cache,
          DateTime.now().add(MomentMediaCache.diskTtl), url);
      return;
    }
    final legacy = await getFileFromCache(source.legacyCacheKey);
    source.ensureCurrent();
    if (legacy != null) {
      final migrated = await _migrateFile(url, source, legacy,
          removeKey: source.legacyCacheKey);
      if (migrated != null) {
        yield migrated;
        return;
      }
    }
    yield* _loadSource(url, effectiveKey, headers, withProgress, source);
  }

  Stream<FileResponse> _loadSource(
      String url,
      String effectiveKey,
      Map<String, String>? headers,
      bool withProgress,
      _MomentMediaSource source,
      {bool allowLegacyCache = true}) async* {
    await for (final response in super.getFileStream(url,
        key: effectiveKey, headers: headers, withProgress: withProgress)) {
      if (response is! FileInfo) {
        yield response;
        continue;
      }
      final migrated = await _migrateFile(url, source, response,
          removeKey: effectiveKey, allowLegacyCache: allowLegacyCache);
      if (migrated == null) {
        // A deleted stale cache entry must not require the user to tap retry:
        // the same authorized request now obtains fresh bytes.
        yield* _loadSource(url, effectiveKey, headers, withProgress, source,
            allowLegacyCache: false);
        return;
      }
      yield migrated;
    }
  }

  Future<FileInfo?> _migrateFile(
      String url, _MomentMediaSource source, FileInfo response,
      {required String removeKey, bool allowLegacyCache = true}) async {
    try {
      source.ensureCurrent();
      if (allowLegacyCache &&
          response.source == FileSource.Cache &&
          await MediaCache.legacyEntryPredatesAccountClear(
              source.accountKey, await response.file.lastModified())) {
        await removeFile(removeKey);
        source.ensureCurrent();
        return null;
      }
      final bytes = await response.file.readAsBytes();
      source.ensureCurrent();
      final object = await MediaCache.store('moments', source.cacheKey, bytes,
          accountId: source.accountKey,
          expectedAccountGeneration: source.generation);
      source.ensureCurrent();
      // Remove only this account-scoped legacy entry after migration; its
      // object may be shared with chat and must remain intact.
      await removeFile(removeKey);
      source.ensureCurrent();
      return FileInfo(
          _files.file(object.path), response.source, response.validTill, url,
          statusCode: response.statusCode);
    } catch (_) {
      // A response that raced account clearing was first written by the
      // legacy manager. Remove only this alias before it can be retried by a
      // fresh provider; normal network failures leave successful disk data.
      if (!source.isCurrent) await removeFile(removeKey);
      rethrow;
    }
  }
}
