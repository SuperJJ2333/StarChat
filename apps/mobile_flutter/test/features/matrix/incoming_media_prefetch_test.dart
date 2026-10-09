import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:liuhetong_mobile/core/native_media_download.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/room_image_preview_cache.dart';
import 'package:liuhetong_mobile/features/matrix/content_addressed_media.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_session_cache.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/incoming_media_prefetch.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sdk_incoming_media_source.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';

class _Source implements IncomingMediaSource {
  final controller = StreamController<IncomingMediaCandidate>.broadcast();
  @override
  Stream<IncomingMediaCandidate> get candidates => controller.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> dispose() => controller.close();
}

IncomingMediaCandidate _candidate(String id,
        {Future<void> Function()? prepare}) =>
    IncomingMediaCandidate(
        originalKey:
            MediaCacheKey(accountId: 'alice', roomId: 'room', eventId: id),
        isVideo: false,
        isAnimated: false,
        prepare: prepare ?? () async {},
        download: (_) async => Uint8List.fromList([1]));

class _Client extends Client {
  _Client() : super('incoming-test');
  late final room =
      Room(id: '!room:test', client: this, membership: Membership.join);
  @override
  Uri get homeserver => Uri.parse('https://matrix.test');
  @override
  Future<bool> authenticatedMediaSupported() async => true;
  @override
  String get userID => '@alice:test';
  @override
  Room? getRoomById(String id) => room;
}

Map<String, dynamic> _event(String id,
        {String sender = '@bob:test',
        bool flash = false,
        bool encrypted = false,
        bool redacted = false}) =>
    {
      'event_id': id,
      'sender': sender,
      'origin_server_ts': 1,
      'type': encrypted ? EventTypes.Encrypted : EventTypes.Message,
      'original_source': {
        'type': EventTypes.Encrypted,
        'content': <String, dynamic>{},
        'event_id': id,
        'sender': sender,
        'origin_server_ts': 1
      },
      'content': {
        'msgtype': MessageTypes.Image,
        'body': 'media',
        if (flash) 'flash': '1',
        'file': {
          'url': 'mxc://test/$id',
          'key': {
            'k': 'test-key',
            'key_ops': ['decrypt']
          },
          'iv': 'test-iv',
          'hashes': {'sha256': 'test-hash'}
        }
      },
      if (redacted) 'unsigned': {'redacted_because': {}},
    };

class _ProbeEvent extends Event {
  _ProbeEvent(Event event)
      : super(
            room: event.room,
            eventId: event.eventId,
            senderId: event.senderId,
            type: event.type,
            originServerTs: event.originServerTs,
            content: event.content,
            originalSource: event.originalSource);
  bool joinedNative = false;
  @override
  Future<MatrixFile> downloadAndDecryptAttachment(
      {bool getThumbnail = false,
      Future<Uint8List> Function(Uri)? downloadCallback,
      bool fromLocalStoreOnly = false}) async {
    joinedNative = downloadCallback != null;
    if (downloadCallback != null) {
      try {
        await downloadCallback(
            Uri.parse('https://matrix.test/_matrix/media/v3/download/test/id'));
      } catch (_) {}
    }
    return MatrixFile(bytes: Uint8List.fromList([1]), name: 'probe');
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    clearMediaMemoryCaches();
    SharedPreferences.setMockInitialValues({});
    final root = Directory(
        '../../docs/verification/artifacts/2026-09-30/mobile-perf-mute-media/review-cache');
    await root.create(recursive: true);
    final scratch = await root.createTemp('case-');
    PathProviderPlatform.instance = _Paths(scratch.absolute.path);
    addTearDown(() async {
      clearMediaMemoryCaches();
      await scratch.delete(recursive: true);
    });
  });
  test(
      'every received media event and late decryption works without opening a room',
      () async {
    final client = _Client();
    final source =
        MatrixSdkIncomingMediaSource(client: client, ensureActive: () {});
    final received = <IncomingMediaCandidate>[];
    final sub = source.candidates.listen(received.add);
    await source.start();
    final parsed = Event.fromJson(_event('one'), client.room);
    expect(parsed.isAttachmentEncrypted, isTrue);
    expect(parsed.status.isSending, isFalse);
    expect(parsed.originalSource?.type, EventTypes.Encrypted);
    for (final id in ['one', 'two', 'three']) {
      client.onEvent.add(EventUpdate(
          roomID: client.room.id,
          type: EventUpdateType.timeline,
          content: _event(id)));
    }
    client.onEvent.add(EventUpdate(
        roomID: client.room.id,
        type: EventUpdateType.timeline,
        content: _event('late', encrypted: true)));
    client.onEvent.add(EventUpdate(
        roomID: client.room.id,
        type: EventUpdateType.decryptedTimelineQueue,
        content: _event('late')));
    await Future<void>.delayed(Duration.zero);
    expect(received.map((c) => c.originalKey.eventId),
        ['one', 'two', 'three', 'late']);
    expect(received.first.previewAccountId,
        '${client.homeserver}|${client.userID}');
    await source.dispose();
    await sub.cancel();
  });
  test('flash own redacted and encrypted events never enter the queue',
      () async {
    final client = _Client();
    var revoked = false;
    final source = MatrixSdkIncomingMediaSource(
        client: client,
        ensureActive: () {
          if (revoked) throw StateError('revoked');
        });
    final received = <IncomingMediaCandidate>[];
    final sub = source.candidates.listen(received.add);
    await source.start();
    for (final event in [
      _event('flash', flash: true),
      _event('own', sender: client.userID),
      _event('redacted', redacted: true),
      _event('encrypted', encrypted: true)
    ]) {
      client.onEvent.add(EventUpdate(
          roomID: client.room.id,
          type: EventUpdateType.timeline,
          content: event));
    }
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);
    revoked = true;
    client.onEvent.add(EventUpdate(
        roomID: client.room.id,
        type: EventUpdateType.timeline,
        content: _event('old')));
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);
    await source.dispose();
    await sub.cancel();
  });
  test(
      'duplicate events share a job, failed cache work retries without losing the media',
      () async {
    final source = _Source();
    var attempts = 0, prepared = 0;
    final service = IncomingMediaPrefetchService(source,
        retryDelay: const Duration(milliseconds: 10), persist: (_) async {
      attempts++;
      if (attempts == 1) throw StateError('offline');
    });
    await service.start();
    final item = _candidate('one', prepare: () async {
      prepared++;
    });
    source.controller.add(item);
    source.controller.add(item);
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(attempts, 2);
    expect(prepared, 2);
    expect(service.completedCount, 1);
    source.controller.add(item);
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 2);
    await service.dispose();
  });
  test(
      'all bounded native requests register while cache worker waits; logout fences late completion',
      () async {
    final source = _Source();
    final gate = Completer<void>();
    var prepared = 0, cached = 0;
    final service =
        IncomingMediaPrefetchService(source, maxPending: 3, persist: (_) async {
      cached++;
      await gate.future;
    });
    await service.start();
    for (var i = 0; i < 4; i++) {
      source.controller.add(_candidate('$i', prepare: () async {
        prepared++;
      }));
    }
    await Future<void>.delayed(Duration.zero);
    expect(prepared, 3);
    expect(cached, 1);
    expect(service.pendingCount, 3);
    await service.dispose();
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(service.completedCount, 0);
    expect(service.pendingCount, 0);
  });
  test(
      'forwarded pending and completed content still writes each page preview alias',
      () async {
    final source = _Source();
    final service = IncomingMediaPrefetchService(source);
    addTearDown(service.dispose);
    final bytes = Uint8List.fromList([1, 2, 3]);
    final hash = sha256.convert(bytes).toString();
    final gate = Completer<void>();
    var downloads = 0;
    IncomingMediaCandidate item(String room, String event) =>
        IncomingMediaCandidate(
            originalKey: MediaCacheKey(
                accountId: 'alice',
                roomId: room,
                eventId: event,
                contentSha256: hash),
            thumbnailKey: MediaCacheKey(
                accountId: 'alice',
                roomId: room,
                eventId: 'thumb:$event',
                contentSha256: hash),
            previewAccountId: 'https://matrix.test|alice',
            isVideo: false,
            isAnimated: false,
            prepare: () async {},
            download: (_) async {
              downloads++;
              await gate.future;
              return bytes;
            });
    await service.start();
    source.controller.add(item('r1', 'one'));
    source.controller.add(item('r2', 'two'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete();
    for (var i = 0; i < 100 && service.pendingCount > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    source.controller.add(item('r3', 'three'));
    final completionDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (service.completedCount < 3 &&
        DateTime.now().isBefore(completionDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    for (final pair in [('r1', 'one'), ('r2', 'two'), ('r3', 'three')]) {
      final page = RoomImagePreviewCache.forRoomSession(
          accountId: 'https://matrix.test|alice',
          memoryNamespace: 'alice',
          roomId: pair.$1,
          read: (_) async => null,
          write: (_, __) async {});
      expect(await page.readCached(pair.$2), bytes,
          reason:
              'each forwarded event must be ready in the real page namespace');
      page.dispose();
    }
    expect(downloads, 1,
        reason: 'plaintext cache still shares the one content load');
    expect(service.completedCount, 3);
  });
  test(
      'permanent failed work retires and leaves bounded queue room for healthy media',
      () async {
    final source = _Source();
    var failures = 0, good = 0;
    final service = IncomingMediaPrefetchService(source,
        maxPending: 1,
        retryDelay: const Duration(milliseconds: 1), persist: (item) async {
      if (item.originalKey.eventId == 'bad') {
        failures++;
        throw StateError('permanently rejected');
      }
      good++;
    });
    addTearDown(service.dispose);
    await service.start();
    source.controller.add(_candidate('bad'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    source.controller.add(_candidate('good'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(failures, greaterThan(1),
        reason: 'transient failures must retain a retry opportunity');
    expect(good, 1);
    expect(service.pendingCount, 0);
  });
  test(
      'same plaintext with independent encrypted descriptors registers separate native transfers',
      () async {
    const channel = MethodChannel('chatflow/background_media');
    final ids = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'activate') return 'nonce';
      if (call.method == 'status') return {'state': 'failed'};
      if (call.method == 'enqueue') {
        ids.add((call.arguments as Map)['id'] as String);
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final client = _Client();
    final source =
        MatrixSdkIncomingMediaSource(client: client, ensureActive: () {});
    addTearDown(source.dispose);
    final received = <IncomingMediaCandidate>[];
    source.candidates.listen(received.add);
    await source.start();
    final events = <Event>[];
    for (final id in ['cipher-a', 'cipher-b']) {
      final raw = _event(id);
      final content = raw['content'] as Map;
      content['chatflow_media'] = {'v': 1, 'content_sha256': 'a' * 64};
      final file = content['file'] as Map;
      (file['key'] as Map)['k'] = 'key-$id';
      file['iv'] = 'iv-$id';
      file['hashes'] = {'sha256': 'hash-$id'};
      events.add(Event.fromJson(raw, client.room));
      client.onEvent.add(EventUpdate(
          roomID: client.room.id,
          type: EventUpdateType.timeline,
          content: raw));
    }
    await Future<void>.delayed(Duration.zero);
    expect(received[0].originalKey.identity, received[1].originalKey.identity);
    await received[0].prepare();
    final foregroundB = _ProbeEvent(events[1]);
    await downloadMediaContent(foregroundB);
    expect(foregroundB.joinedNative, isFalse,
        reason:
            'foreground B must not decrypt pending ciphertext A using B descriptor');
    await received[1].prepare();
    expect(ids.toSet().length, 2,
        reason: 'equal plaintext is not equal ciphertext');
  });
  test(
      'cache reuse consumes unused ciphertext registration and retirement cancels staging',
      () async {
    const channel = MethodChannel('test/prefetch-release');
    final staged = <String>{};
    var enqueues = 0, reads = 0, consumes = 0;
    final root =
        await PathProviderPlatform.instance.getApplicationDocumentsPath();
    final file = File('$root/native.bin');
    await file.writeAsBytes([1, 2, 3]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      if (call.method == 'activate') return 'nonce';
      if (call.method == 'enqueue') {
        enqueues++;
        staged.add(args['id'] as String);
      }
      if (call.method == 'consume') {
        consumes++;
        staged.remove(args['id']);
      }
      if (call.method == 'status') {
        reads++;
        return {'state': 'complete', 'path': file.absolute.path};
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final session =
        NativeMediaDownloadSession('release-account', channel: channel);
    addTearDown(session.dispose);
    final source = _Source();
    final service = IncomingMediaPrefetchService(source,
        retryDelay: const Duration(milliseconds: 1));
    addTearDown(service.dispose);
    final hash = sha256.convert([1, 2, 3]).toString();
    IncomingMediaCandidate item(String id, {bool bad = false}) {
      final owner = Object();
      final request = NativeMediaRequest(
          id: id,
          url: Uri.parse(
              'https://matrix.test/_matrix/media/v3/download/test/$id'),
          trustedOrigin: 'https://matrix.test',
          kind: 'matrix',
          maxBytes: 100);
      return IncomingMediaCandidate(
          originalKey: MediaCacheKey(
              accountId: 'release-account',
              roomId: 'r',
              eventId: id,
              contentSha256: bad ? null : hash),
          isVideo: false,
          isAnimated: false,
          prepare: () => session.prepare(request, owner: owner),
          release: () => session.release(request, owner: owner),
          download: (_) async {
            if (bad) throw StateError('permanent decrypt rejection');
            return session.download(request);
          });
    }

    await service.start();
    source.controller.add(item('cipher-a'));
    source.controller.add(item('cipher-b'));
    for (var i = 0; i < 100 && service.completedCount < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(enqueues, 2);
    expect(reads, 1);
    expect(staged, isEmpty,
        reason:
            'second ciphertext was never read because plaintext was cached');
    expect(consumes, 2);
    source.controller.add(item('bad', bad: true));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(service.pendingCount, 0);
    expect(staged, isEmpty,
        reason:
            'retiring final failed candidate must cancel its prepared request');
    expect(
        NativeMediaDownloadSession.joinPending('release-account', 'cipher-b'),
        isNull);
    expect(NativeMediaDownloadSession.joinPending('release-account', 'bad'),
        isNull);
  });
  test(
      'prefetched video thumbnail is a synchronous page poster hit with account and size bounds',
      () async {
    final source = _Source();
    final service = IncomingMediaPrefetchService(source);
    addTearDown(service.dispose);
    final poster = Uint8List.fromList([1, 2, 3]);
    IncomingMediaCandidate item(String id, Uint8List thumb) =>
        IncomingMediaCandidate(
            originalKey: MediaCacheKey(
                accountId: 'video-account', roomId: 'r', eventId: id),
            thumbnailKey: MediaCacheKey(
                accountId: 'video-account', roomId: 'r', eventId: 'thumb:$id'),
            previewAccountId: 'https://matrix.test|video-account',
            isVideo: true,
            isAnimated: false,
            prepare: () async {},
            download: (thumbnail) async =>
                thumbnail ? thumb : Uint8List.fromList([4, 5, 6]));
    await service.start();
    source.controller.add(item('small', poster));
    source.controller.add(item('large', Uint8List(512 * 1024 + 1)));
    for (var i = 0; i < 100 && service.completedCount < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.completedCount, 2);
    await service.dispose();
    final pageCache = VideoPosterSessionCache.forRoomSession();
    addTearDown(pageCache.disposeRoomSession);
    VideoPosterPipeline page(String account) => VideoPosterPipeline(
        accountId: account,
        roomId: 'r',
        memory: pageCache,
        loadServerPoster: (_) async => throw StateError('unexpected network'),
        readCachedPoster: (_) async => null,
        writeCachedPoster: (_, __) async {},
        findLocalVideoFile: (_) async => null);
    expect(page('video-account').peek('small'), poster,
        reason:
            'the real RoomPage pipeline must paint the first frame synchronously');
    expect(page('other-account').peek('small'), isNull);
    expect(page('video-account').peek('large'), isNull,
        reason: 'oversized thumbnails must not enter completed poster memory');
    final durable = await MediaCache.cached('r', videoPosterCacheRefId('small'),
        accountId: 'video-account');
    expect(await durable?.readAsBytes(), poster);
    expect(
        await MediaCache.cached('r', videoPosterCacheRefId('large'),
            accountId: 'video-account'),
        isNull);
  });
}
