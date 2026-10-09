import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';
import 'package:liuhetong_mobile/features/emoji/emoji_resource_manifest.dart';
import 'package:liuhetong_mobile/features/emoji/emoji_resource_store.dart';

final class _LocalTransport implements HttpClient {
  _LocalTransport(this.origin, this.requested) : client = HttpClient();
  final Uri origin;
  final List<Uri> requested;
  final HttpClient client;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) {
    requested.add(uri);
    return client.getUrl(origin.replace(path: uri.path));
  }

  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;
  @override
  void close({bool force = false}) => client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Directory> _cache() async {
  final root = Directory(
      '../../docs/verification/artifacts/2026-10-09/mobile-responsive-maintenance/resources/test-cache');
  await root.create(recursive: true);
  return root.createTemp('transport-');
}

void main() {
  test(
      'two demand downloads serialize and use only immutable trusted resource URLs',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = Uri.parse('http://127.0.0.1:${server.port}');
    final requested = <Uri>[];
    var active = 0, peak = 0;
    final subscription = server.listen((request) async {
      active++;
      if (active > peak) peak = active;
      final path = request.uri.path.split('/').last;
      final bytes = await File('assets/emoji/$path').readAsBytes();
      request.response.headers.contentType = ContentType('image', 'webp');
      request.response.contentLength = bytes.length;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      request.response.add(bytes);
      await request.response.close();
      active--;
    });
    final cache = await _cache();
    var clock = DateTime(2026);
    final gate = MaintenanceActivity(clock: () => clock);
    clock = clock.add(const Duration(seconds: 1));
    final manifest = EmojiResourceManifest.parse(emojiManifestJson,
        expectedDigest: emojiManifestDigest);
    final store = EmojiResourceStore(
        directory: cache,
        manifest: manifest,
        maintenance: gate,
        clientFactory: () => _LocalTransport(origin, requested));
    try {
      final files =
          await Future.wait([store.resolve('joy'), store.resolve('smile')]);
      expect(files, everyElement(isNotNull));
      expect(peak, 1);
      expect(requested, hasLength(2));
      expect(
          requested.every((uri) =>
              uri.scheme == 'https' &&
              uri.host == 'd12fjr06o6tga5.cloudfront.net' &&
              uri.path.startsWith('/resources/emoji/${manifest.revision}/') &&
              !uri.hasQuery),
          true);
      expect(gate.heavyBusy, false);
    } finally {
      store.dispose();
      gate.dispose();
      await subscription.cancel();
      await server.close(force: true);
      await cache.delete(recursive: true);
    }
  });
  test('memory pressure cancels an in-flight chunk and removes partial file',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = Uri.parse('http://127.0.0.1:${server.port}');
    final firstChunk = Completer<void>(), finish = Completer<void>();
    final subscription = server.listen((request) async {
      final bytes = await File('assets/emoji/joy.webp').readAsBytes();
      request.response.headers.contentType = ContentType('image', 'webp');
      request.response.contentLength = bytes.length;
      request.response.add(bytes.take(1024).toList());
      await request.response.flush();
      firstChunk.complete();
      await finish.future;
      try {
        request.response.add(bytes.skip(1024).toList());
        await request.response.close();
      } catch (_) {}
    });
    final cache = await _cache();
    var clock = DateTime(2026);
    final gate = MaintenanceActivity(clock: () => clock);
    clock = clock.add(const Duration(seconds: 1));
    final store = EmojiResourceStore(
        directory: cache,
        manifest: EmojiResourceManifest.parse(emojiManifestJson,
            expectedDigest: emojiManifestDigest),
        maintenance: gate,
        clientFactory: () => _LocalTransport(origin, <Uri>[]));
    try {
      final work = store.resolve('joy');
      await firstChunk.future.timeout(const Duration(seconds: 2));
      gate.pressure();
      finish.complete();
      expect(await work.timeout(const Duration(seconds: 2)), isNull);
      expect(await cache.list().toList(), isEmpty);
      expect(gate.heavyBusy, false);
      expect(gate.pendingWaiters, 0);
    } finally {
      if (!finish.isCompleted) finish.complete();
      store.dispose();
      gate.dispose();
      await subscription.cancel();
      await server.close(force: true);
      await cache.delete(recursive: true);
    }
  });
  test(
      'transient download failure retries after bounded backoff in the same store',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = Uri.parse('http://127.0.0.1:${server.port}');
    var requests = 0;
    final subscription = server.listen((request) async {
      requests++;
      if (requests == 1) {
        request.response.statusCode = 503;
        await request.response.close();
        return;
      }
      final bytes = await File('assets/emoji/joy.webp').readAsBytes();
      request.response.headers.contentType = ContentType('image', 'webp');
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    final cache = await _cache();
    var clock = DateTime(2026);
    final gate = MaintenanceActivity(clock: () => clock);
    clock = clock.add(const Duration(seconds: 1));
    final store = EmojiResourceStore(
        directory: cache,
        manifest: EmojiResourceManifest.parse(emojiManifestJson,
            expectedDigest: emojiManifestDigest),
        maintenance: gate,
        clientFactory: () => _LocalTransport(origin, <Uri>[]),
        clock: () => clock);
    try {
      expect(await store.resolve('joy'), isNull);
      expect(requests, 1);
      expect(await store.resolve('joy'), isNull);
      expect(requests, 1);
      clock = clock.add(const Duration(seconds: 1));
      expect(await store.resolve('joy'), isNotNull);
      expect(requests, 2);
    } finally {
      store.dispose();
      gate.dispose();
      await subscription.cancel();
      await server.close(force: true);
      await cache.delete(recursive: true);
    }
  });
  test(
      'Wi-Fi prefetch stops next file on cellular while user demand remains available',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = Uri.parse('http://127.0.0.1:${server.port}');
    final changes = StreamController<bool>.broadcast();
    var wifi = true;
    final names = <String>[];
    final subscription = server.listen((request) async {
      final name = request.uri.path.split('/').last;
      names.add(name);
      final bytes = await File('assets/emoji/$name').readAsBytes();
      request.response.headers.contentType = ContentType('image', 'webp');
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
      wifi = false;
      changes.add(false);
    });
    final cache = await _cache();
    var clock = DateTime(2026);
    final gate = MaintenanceActivity(clock: () => clock);
    clock = clock.add(const Duration(seconds: 1));
    final store = EmojiResourceStore(
        directory: cache,
        manifest: EmojiResourceManifest.parse(emojiManifestJson,
            expectedDigest: emojiManifestDigest),
        maintenance: gate,
        clientFactory: () => _LocalTransport(origin, <Uri>[]));
    try {
      await store.prefetchWifi(
          isWifi: () async => wifi, networkChanges: changes.stream);
      expect(names, hasLength(1));
      expect(await store.resolve('joy'), isNotNull);
      expect(names, hasLength(2));
    } finally {
      store.dispose();
      gate.dispose();
      await changes.close();
      await subscription.cancel();
      await server.close(force: true);
      await cache.delete(recursive: true);
    }
  });
  test(
      'strong ETag partial resumes after store reopen with exact Range and final SHA',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = Uri.parse('http://127.0.0.1:${server.port}');
    final bytes = await File('assets/emoji/joy.webp').readAsBytes();
    var requests = 0;
    final subscription = server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType('image', 'webp');
      request.response.headers.set('etag', '"immutable-v1"');
      if (requests == 1) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.add(utf8.encode(
            'HTTP/1.1 200 OK\r\nContent-Type: image/webp\r\nContent-Length: ${bytes.length}\r\nETag: "immutable-v1"\r\n\r\n'));
        socket.add(bytes.take(1024).toList());
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        socket.destroy();
      } else {
        expect(request.headers.value('range'), 'bytes=1024-');
        expect(request.headers.value('if-range'), '"immutable-v1"');
        request.response.statusCode = 206;
        request.response.headers.set(
            'content-range', 'bytes 1024-${bytes.length - 1}/${bytes.length}');
        request.response.contentLength = bytes.length - 1024;
        request.response.add(bytes.skip(1024).toList());
        await request.response.close();
      }
    });
    final cache = await _cache();
    var clock = DateTime(2026);
    final gate = MaintenanceActivity(clock: () => clock);
    clock = clock.add(const Duration(seconds: 1));
    EmojiResourceStore make() => EmojiResourceStore(
        directory: cache,
        manifest: EmojiResourceManifest.parse(emojiManifestJson,
            expectedDigest: emojiManifestDigest),
        maintenance: gate,
        clientFactory: () => _LocalTransport(origin, <Uri>[]));
    final first = make();
    EmojiResourceStore? second;
    try {
      expect(await first.resolve('joy'), isNull);
      expect(await first.resolve('joy', fetch: false), isNull);
      first.dispose();
      second = make();
      expect(await second.resolve('joy'), isNotNull);
      expect(requests, 2);
      expect(
          (await cache.list().toList()).where((f) => f.path.endsWith('.part')),
          isEmpty);
    } finally {
      first.dispose();
      second?.dispose();
      gate.dispose();
      await subscription.cancel();
      await server.close(force: true);
      await cache.delete(recursive: true);
    }
  });
  for (final scenario in [
    'wrong-range',
    'wrong-etag',
    'final-corrupt',
    'ignored-range',
    'changed-etag-200',
    'weak-etag',
    'wrong-revision',
    'corrupt-prefix'
  ]) {
    test(
        'resume rejects or restarts $scenario without displaying partial bytes',
        () async {
      final cache = await _cache();
      final manifest = EmojiResourceManifest.parse(emojiManifestJson,
          expectedDigest: emojiManifestDigest);
      final entry = manifest.entries['joy']!,
          bytes = await File('assets/emoji/joy.webp').readAsBytes();
      final part = File('${cache.path}/${manifest.revision}-joy.webp.part');
      await part.writeAsBytes(bytes.take(1024).toList());
      final metadata = {
        'revision': scenario == 'wrong-revision' ? '0' * 24 : manifest.revision,
        'id': 'joy',
        'sha256': entry.sha,
        'bytes': entry.bytes,
        'etag': scenario == 'weak-etag' ? 'W/"old"' : '"old"',
        'received': 1024,
        'partialSha256': sha256.convert(bytes.take(1024).toList()).toString()
      };
      await File('${cache.path}/${manifest.revision}-joy.webp.resume.json')
          .writeAsString(jsonEncode(metadata));
      if (scenario == 'corrupt-prefix') {
        await part.writeAsBytes(List.filled(1024, 0));
      }
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType('image', 'webp');
        final full = [
          'ignored-range',
          'changed-etag-200',
          'weak-etag',
          'wrong-revision',
          'corrupt-prefix'
        ].contains(scenario);
        request.response.headers.set(
            'etag',
            scenario == 'wrong-etag' || scenario == 'changed-etag-200'
                ? '"new"'
                : '"old"');
        if (['weak-etag', 'wrong-revision', 'corrupt-prefix']
            .contains(scenario)) {
          expect(request.headers.value('range'), isNull);
        } else {
          expect(request.headers.value('range'), 'bytes=1024-');
        }
        var payload = bytes;
        if (!full) {
          request.response.statusCode = 206;
          request.response.headers.set('content-range',
              'bytes ${scenario == 'wrong-range' ? 1025 : 1024}-${bytes.length - 1}/${bytes.length}');
          payload = Uint8List.fromList(bytes.skip(1024).toList());
          if (scenario == 'final-corrupt') payload[payload.length - 1] ^= 1;
        }
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      });
      var clock = DateTime(2026);
      final gate = MaintenanceActivity(clock: () => clock);
      clock = clock.add(const Duration(seconds: 1));
      final store = EmojiResourceStore(
          directory: cache,
          manifest: manifest,
          maintenance: gate,
          clientFactory: () => _LocalTransport(origin, <Uri>[]));
      try {
        expect(await store.resolve('joy', fetch: false), isNull);
        final file = await store.resolve('joy');
        if (['wrong-range', 'wrong-etag', 'final-corrupt'].contains(scenario)) {
          expect(file, isNull);
          expect(await cache.list().toList(), isEmpty);
        } else {
          expect(file, isNotNull);
          expect(await file!.readAsBytes(), bytes);
        }
        expect(gate.heavyBusy, false);
      } finally {
        store.dispose();
        gate.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await cache.delete(recursive: true);
      }
    });
  }
  for (final pause in ['wifi', 'interactive', 'pressure']) {
    test(
        '$pause interrupts active transfer, preserves only bounded hash-bound partial and releases heavy lease',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      final started = Completer<void>(), release = Completer<void>();
      final changes = StreamController<bool>.broadcast();
      var wifi = true;
      final subscription = server.listen((request) async {
        final bytes =
            await File('assets/emoji/${request.uri.path.split('/').last}')
                .readAsBytes();
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.add(utf8.encode(
            'HTTP/1.1 200 OK\r\nContent-Type: image/webp\r\nContent-Length: ${bytes.length}\r\nETag: "stable"\r\n\r\n'));
        socket.add(bytes.take(2048).toList());
        await socket.flush();
        started.complete();
        await release.future;
        try {
          socket.add(bytes.skip(2048).toList());
          await socket.flush();
        } catch (_) {}
        socket.destroy();
      });
      final cache = await _cache();
      var clock = DateTime(2026);
      final gate = MaintenanceActivity(clock: () => clock);
      clock = clock.add(const Duration(seconds: 1));
      final store = EmojiResourceStore(
          directory: cache,
          manifest: EmojiResourceManifest.parse(emojiManifestJson,
              expectedDigest: emojiManifestDigest),
          maintenance: gate,
          clientFactory: () => _LocalTransport(origin, <Uri>[]));
      try {
        final Future<Object?> work = pause == 'wifi'
            ? store.prefetchWifi(
                isWifi: () async => wifi, networkChanges: changes.stream)
            : store.resolve('joy');
        await started.future;
        var checkpoint = false;
        for (var n = 0; n < 50; n++) {
          checkpoint = (await cache.list().toList())
              .any((f) => f.path.endsWith('.resume.json'));
          if (checkpoint) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(checkpoint, true);
        if (pause == 'wifi') {
          wifi = false;
          changes.add(false);
        } else if (pause == 'interactive') {
          gate.setInteractive('keyboard', true);
        } else {
          gate.pressure();
        }
        await work.timeout(const Duration(seconds: 1));
        expect(gate.heavyBusy, false);
        expect(gate.pendingWaiters, 0);
        final files = await cache.list().toList();
        expect(files.where((f) => f.path.endsWith('.part')), hasLength(1));
        var bytes = 0;
        for (final f in files.whereType<File>()) {
          bytes += await f.length();
        }
        expect(bytes, lessThanOrEqualTo(store.maxCacheBytes));
        expect(await store.resolve('joy', fetch: false), isNull);
      } finally {
        release.complete();
        store.dispose();
        gate.dispose();
        await changes.close();
        await subscription.cancel();
        await server.close(force: true);
        await cache.delete(recursive: true);
      }
    });
  }
}
