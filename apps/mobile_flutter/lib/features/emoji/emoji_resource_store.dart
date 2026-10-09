import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../core/maintenance_activity.dart';

final class EmojiResourceEntry {
  const EmojiResourceEntry(this.id, this.path, this.sha, this.bytes);
  final String id, path, sha;
  final int bytes;
}

final class EmojiResourceManifest {
  EmojiResourceManifest._(this.revision, this.entries);
  final String revision;
  final Map<String, EmojiResourceEntry> entries;
  static EmojiResourceManifest parse(String data,
      {required String expectedDigest}) {
    if (utf8.encode(data).length > 64 * 1024 ||
        sha256.convert(utf8.encode(data)).toString() != expectedDigest) {
      throw const FormatException('Untrusted emoji manifest');
    }
    final json = jsonDecode(data) as Map<String, dynamic>;
    final revision = json['revision'];
    if (json['version'] != 1 ||
        revision is! String ||
        !RegExp(r'^[a-f0-9]{24}$').hasMatch(revision)) {
      throw const FormatException('Unsupported emoji revision');
    }
    final rows = json['entries'];
    if (rows is! List || rows.length > 56) {
      throw const FormatException('Invalid resource count');
    }
    final entries = <String, EmojiResourceEntry>{};
    for (final row in rows) {
      if (row is! Map) throw const FormatException('Invalid resource entry');
      final id = row['id'],
          path = row['path'],
          sha = row['sha256'],
          bytes = row['bytes'];
      if (id is! String ||
          !RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(id) ||
          path != '$id.webp' ||
          sha is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha) ||
          bytes is! int ||
          bytes < 12 ||
          bytes > 1024 * 1024 ||
          row['type'] != 'image/webp' ||
          entries.containsKey(id)) {
        throw const FormatException('Invalid resource entry');
      }
      entries[id] = EmojiResourceEntry(id, path as String, sha, bytes);
    }
    return EmojiResourceManifest._(revision, Map.unmodifiable(entries));
  }
}

/// Private immutable files. One download, streaming hash, atomic rename; failures
/// produce null so callers keep a stable offline SVG and Unicode message format.
final class EmojiResourceStore {
  EmojiResourceStore(
      {required this.directory,
      required this.manifest,
      MaintenanceActivity? maintenance,
      Uri? baseUri,
      HttpClient Function()? clientFactory,
      DateTime Function()? clock,
      this.maxCacheBytes = 64 * 1024 * 1024})
      : _clock = clock ?? DateTime.now,
        _clientFactory = clientFactory ?? HttpClient.new,
        maintenance = maintenance ?? MaintenanceActivity.instance,
        baseUri = validateBaseUri(baseUri ??
            Uri.parse(const String.fromEnvironment('CHATFLOW_EMOJI_BASE_URL',
                defaultValue:
                    'https://d12fjr06o6tga5.cloudfront.net/resources/emoji/')));
  final DateTime Function() _clock;
  final HttpClient Function() _clientFactory;
  final _cancelled = Completer<void>();
  final Directory directory;
  final EmojiResourceManifest manifest;
  final MaintenanceActivity maintenance;
  final Uri baseUri;
  final int maxCacheBytes;
  final _pins = <String, int>{};
  final _verified = <String, File>{};
  final _verifiedStats =
      <String, (int, DateTime, DateTime, FileSystemEntityType)>{};
  int _hashChecks = 0, _fastLookups = 0;
  Map<String, int> get diagnostics => {
        'hashChecks': _hashChecks,
        'fastLookups': _fastLookups,
        'verifiedEntries': _verified.length
      };
  (int, DateTime, DateTime, FileSystemEntityType) _fingerprint(FileStat stat) =>
      (stat.size, stat.modified, stat.changed, stat.type);
  Future<void> _remember(String id, File file) async {
    final stat = await file.stat();
    if (!_disposed) {
      _verified[id] = file;
      _verifiedStats[id] = _fingerprint(stat);
    }
  }

  final _pending = <String, Future<File?>>{};
  final _localPending = <String, Future<File?>>{};
  final _prefetchPending = <String>{};
  final _failed = <String, (int, DateTime)>{};
  Future<void> _tail = Future.value();
  bool _disposed = false;
  HttpClient? _activeClient;
  String? _activeId;
  int _clientEpoch = 0;
  static Uri validateBaseUri(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host != 'd12fjr06o6tga5.cloudfront.net' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path != '/resources/emoji/') {
      throw const FormatException('Unapproved emoji resource origin');
    }
    return uri;
  }

  File _file(EmojiResourceEntry entry) =>
      File(p.join(directory.path, '${manifest.revision}-${entry.id}.webp'));
  void pin(String id) => _pins.update(id, (n) => n + 1, ifAbsent: () => 1);
  void unpin(String id) {
    final count = _pins[id] ?? 0;
    if (count <= 1) {
      _pins.remove(id);
    } else {
      _pins[id] = count - 1;
    }
  }

  /// SHA-verified private immutable files use a bounded metadata fast path.
  /// Any length/time/type change invalidates it and forces asynchronous SHA
  /// validation. No content is read or hashed on the UI thread.
  File? verifiedFile(String id) {
    if (_disposed) return null;
    final file = _verified[id], entry = manifest.entries[id];
    if (file == null || entry == null) return null;
    _fastLookups++;
    try {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
              FileSystemEntityType.file &&
          _fingerprint(file.statSync()) == _verifiedStats[id]) {
        return file;
      }
    } catch (_) {}
    _verified.remove(id);
    _verifiedStats.remove(id);
    return null;
  }

  /// A local candidate reserves neutral geometry while its SHA is checked.
  /// This never grants the caller permission to decode the unverified file.
  bool hasLocalCandidate(String id) {
    final entry = manifest.entries[id];
    if (_disposed || entry == null) return false;
    try {
      return _file(entry).existsSync();
    } catch (_) {
      return false;
    }
  }

  Future<File?> _resolveLocal(EmojiResourceEntry entry) =>
      _localPending.putIfAbsent(entry.id, () {
        return (() async {
          final file = _file(entry);
          if (await _valid(file, entry) && !_disposed) {
            await _remember(entry.id, file);
            return file;
          }
          _verified.remove(entry.id);
          return null;
        })()
            .whenComplete(() {
          _localPending.remove(entry.id);
        });
      });

  Future<File?> resolve(String id,
      {bool fetch = true,
      bool prefetch = false,
      Future<void>? ownerCancellation,
      Future<bool> Function()? allowed}) async {
    try {
      if (_disposed) return null;
      final entry = manifest.entries[id];
      if (entry == null) return null;
      final local = await _resolveLocal(entry);
      if (local != null) return local;
      if (_disposed) return null;
      final failure = _failed[id];
      if (!fetch || (failure != null && _clock().isBefore(failure.$2))) {
        return null;
      }
      if (!prefetch && _prefetchPending.contains(id)) {
        return await _pending[id]!.then((file) => file ?? resolve(id));
      }
      return await _pending.putIfAbsent(id, () {
        if (prefetch) _prefetchPending.add(id);
        final job = _tail.then((_) => _download(entry,
            ownerCancellation: ownerCancellation, allowed: allowed));
        _tail = job.then<void>((_) {}, onError: (Object _, StackTrace __) {});
        return job.whenComplete(() {
          _pending.remove(id);
          _prefetchPending.remove(id);
        });
      });
    } catch (_) {
      return null;
    }
  }

  Future<void> prefetchWifi(
      {required Future<bool> Function() isWifi,
      required Stream<bool> networkChanges}) async {
    final stop = Completer<void>();
    final subscription = networkChanges.listen((wifi) {
      if (!wifi && !stop.isCompleted) stop.complete();
    });
    try {
      for (final id in manifest.entries.keys) {
        if (_disposed || stop.isCompleted || !await isWifi()) return;
        await resolve(id,
            prefetch: true, ownerCancellation: stop.future, allowed: isWifi);
      }
    } finally {
      if (!stop.isCompleted) stop.complete();
      await subscription.cancel();
    }
  }

  Future<bool> _valid(File file, EmojiResourceEntry entry) async {
    try {
      if (!await file.exists() || await file.length() != entry.bytes) {
        return false;
      }
      _hashChecks++;
      return (await sha256.bind(file.openRead()).first).toString() == entry.sha;
    } catch (_) {
      return false;
    }
  }

  void _recordFailure(String id) {
    final attempt = (_failed[id]?.$1 ?? 0) + 1;
    final seconds = attempt >= 7 ? 60 : 1 << (attempt - 1);
    _failed[id] = (attempt, _clock().add(Duration(seconds: seconds)));
  }

  void _pressureChanged() {
    if (maintenance.pressureEpoch != _clientEpoch || !maintenance.canMaintain) {
      _activeClient?.close(force: true);
    }
  }

  File _part(EmojiResourceEntry entry) => File('${_file(entry).path}.part');
  File _meta(EmojiResourceEntry entry) =>
      File('${_file(entry).path}.resume.json');
  bool _strongEtag(String? value) =>
      value != null && RegExp(r'^"[\x21\x23-\x7e]{1,128}"$').hasMatch(value);
  Future<void> _discardPartial(EmojiResourceEntry entry) async {
    for (final file in [
      _part(entry),
      _meta(entry),
      File('${_meta(entry).path}.tmp')
    ]) {
      if (await file.exists()) await file.delete();
    }
  }

  Future<Map<String, dynamic>?> _readPartial(EmojiResourceEntry entry) async {
    final part = _part(entry), meta = _meta(entry);
    try {
      if (await FileSystemEntity.type(part.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await FileSystemEntity.type(meta.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await meta.length() > 2048) {
        throw const FormatException('Missing partial metadata');
      }
      final value =
          jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      final received = value['received'];
      if (value['revision'] != manifest.revision ||
          value['id'] != entry.id ||
          value['sha256'] != entry.sha ||
          value['bytes'] != entry.bytes ||
          !_strongEtag(value['etag'] as String?) ||
          received is! int ||
          received < 12 ||
          received > entry.bytes ||
          value['partialSha256'] is! String ||
          await part.length() < received ||
          await part.length() > entry.bytes) {
        throw const FormatException('Invalid partial identity');
      }
      // A crash after flush but before metadata rename may leave extra bytes:
      // retain only the last hash-bound checkpoint, never unverified tail bytes.
      if (await part.length() > received) {
        final handle = await part.open(mode: FileMode.append);
        try {
          await handle.truncate(received);
        } finally {
          await handle.close();
        }
      }
      if ((await sha256.bind(part.openRead()).first).toString() !=
          value['partialSha256']) {
        throw const FormatException('Partial digest mismatch');
      }
      return value;
    } catch (_) {
      await _discardPartial(entry);
      return null;
    }
  }

  Future<void> _checkpoint(
      EmojiResourceEntry entry, String etag, int received) async {
    if (received < 12 || !_strongEtag(etag)) return;
    final digest =
        (await sha256.bind(_part(entry).openRead()).first).toString();
    final temp = File('${_meta(entry).path}.tmp');
    await temp.writeAsString(
        jsonEncode({
          'revision': manifest.revision,
          'id': entry.id,
          'sha256': entry.sha,
          'bytes': entry.bytes,
          'etag': etag,
          'received': received,
          'partialSha256': digest
        }),
        flush: true);
    await temp.rename(_meta(entry).path);
  }

  Future<File?> _download(EmojiResourceEntry entry,
      {Future<void>? ownerCancellation,
      Future<bool> Function()? allowed}) async {
    var stopped = false;
    final cancellation = Future.any<void>([
      _cancelled.future,
      if (ownerCancellation != null) ownerCancellation
    ]).then((_) {
      stopped = true;
    });
    if (_disposed) return null;
    await maintenance.waitForIdle(cancelled: cancellation);
    if (_disposed ||
        stopped ||
        (allowed != null &&
            !await allowed()
                .timeout(const Duration(seconds: 1), onTimeout: () => false))) {
      return null;
    }
    final lease = await maintenance.acquireHeavy(cancellation: cancellation);
    if (lease == null) return null;
    final epoch = maintenance.pressureEpoch;
    HttpClient? client;
    IOSink? output;
    var resumable = false;
    var listening = false;
    try {
      if (_disposed ||
          stopped ||
          !maintenance.canMaintain ||
          (allowed != null &&
              !await allowed().timeout(const Duration(seconds: 1),
                  onTimeout: () => false))) {
        return null;
      }
      _activeId = entry.id;
      await directory.create(recursive: true);
      final partial = await _readPartial(entry);
      var offset = partial?['received'] as int? ?? 0;
      if (offset == entry.bytes) {
        if (await _valid(_part(entry), entry)) {
          final result = await _part(entry).rename(_file(entry).path);
          await _discardPartial(entry);
          await _remember(entry.id, result);
          return result;
        }
        await _discardPartial(entry);
        offset = 0;
      }
      final reserve = entry.bytes - offset + 4096;
      await trim(reserveBytes: reserve);
      var used = 0;
      await for (final file in directory.list(followLinks: false)) {
        if (file is File) used += await file.length();
      }
      if (used + reserve > maxCacheBytes) return null;
      if (_disposed ||
          stopped ||
          !maintenance.canMaintain ||
          (allowed != null &&
              !await allowed().timeout(const Duration(seconds: 1),
                  onTimeout: () => false))) {
        return null;
      }
      client = _clientFactory()
        ..connectionTimeout = const Duration(seconds: 10);
      _activeClient = client;
      _clientEpoch = epoch;
      maintenance.addListener(_pressureChanged);
      listening = true;
      // Cancellation closes only this prefetch/request owner; a later user
      // demand can immediately create a separate request on cellular.
      unawaited(cancellation.then((_) {
        client?.close(force: true);
      }));
      final request = await client
          .getUrl(baseUri.resolve('${manifest.revision}/${entry.path}'))
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      if (offset > 0) {
        request.headers.set('Range', 'bytes=$offset-');
        request.headers.set('If-Range', partial!['etag']);
      }
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      final etag = response.headers.value('etag');
      if (response.headers.contentType?.mimeType != 'image/webp') {
        throw const FormatException('Wrong resource media type');
      }
      if (response.statusCode == 206) {
        if (offset == 0 ||
            etag != partial!['etag'] ||
            response.headers.value('content-range') !=
                'bytes $offset-${entry.bytes - 1}/${entry.bytes}') {
          throw const FormatException('Invalid resumed resource range/ETag');
        }
      } else if (response.statusCode == 200) {
        offset = 0;
        await _discardPartial(entry);
      } else {
        throw const HttpException('Resource unavailable');
      }
      if (response.contentLength != -1 &&
          response.contentLength != entry.bytes - offset) {
        throw const FormatException('Resource size mismatch');
      }
      resumable = _strongEtag(etag);
      final digestSink = _DigestSink();
      final hash = sha256.startChunkedConversion(digestSink);
      var count = offset;
      if (offset > 0) {
        await for (final chunk in _part(entry).openRead()) {
          hash.add(chunk);
        }
      }
      output = _part(entry)
          .openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        if (_disposed ||
            stopped ||
            epoch != maintenance.pressureEpoch ||
            !maintenance.canMaintain ||
            (allowed != null &&
                !await allowed().timeout(const Duration(seconds: 1),
                    onTimeout: () => false))) {
          throw const FileSystemException('Resource owner paused');
        }
        if (count + chunk.length > entry.bytes) {
          throw const FormatException('Resource exceeds manifest size');
        }
        count += chunk.length;
        hash.add(chunk);
        output.add(chunk);
        await output.flush();
        if (resumable) await _checkpoint(entry, etag!, count);
      }
      hash.close();
      await output.close();
      output = null;
      if (_disposed ||
          stopped ||
          epoch != maintenance.pressureEpoch ||
          !maintenance.canMaintain) {
        throw const FileSystemException('Resource owner paused');
      }
      if (count != entry.bytes) {
        throw const HttpException('Interrupted resource');
      }
      if (digestSink.value?.toString() != entry.sha ||
          !await _valid(_part(entry), entry)) {
        throw const FormatException('Resource SHA256 mismatch');
      }
      final headerHandle = await _part(entry).open();
      late List<int> header;
      try {
        header = await headerHandle.read(12);
      } finally {
        await headerHandle.close();
      }
      if (ascii.decode(header.take(4).toList(), allowInvalid: true) != 'RIFF' ||
          ascii.decode(header.skip(8).toList(), allowInvalid: true) != 'WEBP') {
        throw const FormatException('Invalid WebP header');
      }
      final result = await _part(entry).rename(_file(entry).path);
      await _discardPartial(entry);
      await _remember(entry.id, result);
      _failed.remove(entry.id);
      await trim();
      return result;
    } catch (error) {
      try {
        await output?.close();
        output = null;
      } catch (_) {}
      if (error is FormatException || !resumable) await _discardPartial(entry);
      if (!_disposed &&
          !stopped &&
          epoch == maintenance.pressureEpoch &&
          maintenance.canMaintain) {
        _recordFailure(entry.id);
      }
      return null;
    } finally {
      try {
        await output?.close();
      } catch (_) {}
      lease.release();
      if (listening) maintenance.removeListener(_pressureChanged);
      client?.close(force: true);
      if (identical(client, _activeClient)) _activeClient = null;
      _activeId = null;
    }
  }

  /// Also used by offline import/tests. The source is never trusted before hash,
  /// exact byte length and WebP magic all pass. At most one file buffer is open.
  Future<File?> accept(String id, Stream<List<int>> source) async {
    final entry = manifest.entries[id];
    if (entry == null || _disposed) return null;
    await directory.create(recursive: true);
    final existing = _file(entry);
    if (await _valid(existing, entry)) {
      await _remember(id, existing);
      return existing;
    }
    final target = _file(entry), part = File('${_file(entry).path}.part');
    IOSink? output;
    final digests = _DigestSink();
    final hash = sha256.startChunkedConversion(digests);
    var count = 0;
    final header = <int>[];
    try {
      output = part.openWrite();
      await for (final chunk in source) {
        if (_disposed || count + chunk.length > entry.bytes) {
          throw const FormatException('Resource length exceeds manifest');
        }
        count += chunk.length;
        if (header.length < 12) header.addAll(chunk.take(12 - header.length));
        hash.add(chunk);
        output.add(chunk);
        // Bound pending IOSink data to this network chunk; never retain entire file.
        await output.flush();
      }
      hash.close();
      await output.close();
      output = null;
      if (count != entry.bytes ||
          digests.value?.toString() != entry.sha ||
          ascii.decode(header.take(4).toList(), allowInvalid: true) != 'RIFF' ||
          ascii.decode(header.skip(8).toList(), allowInvalid: true) != 'WEBP') {
        throw const FormatException('Resource verification failed');
      }
      if (await target.exists()) await target.delete();
      final file = await part.rename(target.path);
      await _remember(id, file);
      await trim();
      return await file.exists() ? file : null;
    } catch (_) {
      try {
        await output?.close();
      } catch (_) {}
      if (await part.exists()) await part.delete();
      return null;
    }
  }

  Future<void> trim({int reserveBytes = 0}) async {
    if (!await directory.exists()) return;
    final candidates = <(File, int, DateTime)>[];
    var total = 0;
    await for (final item in directory.list(followLinks: false)) {
      if (item is! File) continue;

      final stat = await item.stat();
      total += stat.size;
      candidates.add((item, stat.size, stat.modified));
    }
    candidates.sort((a, b) => a.$3.compareTo(b.$3));
    for (final candidate in candidates) {
      if (total <= maxCacheBytes - reserveBytes) break;
      final activeEntry = manifest.entries[_activeId];
      if (activeEntry != null &&
          candidate.$1.path.startsWith('${_file(activeEntry).path}.')) {
        continue;
      }
      final pinned = _pins.entries.any((p) =>
          p.value > 0 &&
          manifest.entries.containsKey(p.key) &&
          _file(manifest.entries[p.key]!).path == candidate.$1.path);
      if (pinned) continue;
      await candidate.$1.delete();
      total -= candidate.$2;
      _verified.removeWhere((id, f) {
        if (f.path != candidate.$1.path) return false;
        _verifiedStats.remove(id);
        return true;
      });
    }
  }

  void dispose() {
    _disposed = true;
    _verified.clear();
    _verifiedStats.clear();
    if (!_cancelled.isCompleted) _cancelled.complete();
    _activeClient?.close(force: true);
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
