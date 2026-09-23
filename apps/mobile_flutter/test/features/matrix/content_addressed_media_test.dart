import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/content_addressed_media.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

class _UploadClient extends Client {
  _UploadClient() : super('media-upload-test');
  late Room room;
  final uploads = <Uint8List>[];
  final uploadNames = <String?>[];
  Future<Uri> Function(int attempt)? uploadResponse;
  final syncTransactionIds = <String>[];
  @override
  bool get fileEncryptionEnabled => true;
  @override
  String? get userID => '@sender:test';
  @override
  Room? getRoomById(String id) => room;
  @override
  Future<MediaConfig> getConfig() async => MediaConfig(mUploadSize: 1000000);
  @override
  Future<void> handleSync(SyncUpdate sync, {Direction? direction}) async {
    for (final joined in sync.rooms?.join?.values ?? <JoinedRoomUpdate>[]) {
      for (final event in joined.timeline?.events ?? <MatrixEvent>[]) {
        final txid = event.unsigned?['transaction_id'];
        if (txid is String) syncTransactionIds.add(txid);
      }
    }
  }

  @override
  Future<Uri> uploadContent(Uint8List file,
      {String? filename, String? contentType}) async {
    uploads.add(file);
    uploadNames.add(filename);
    expect(contentType, 'application/octet-stream');
    if (uploadResponse != null) return uploadResponse!(uploads.length);
    return Uri.parse('mxc://test/${uploads.length}');
  }
}

class _UploadRoom extends Room {
  _UploadRoom(Client client) : super(id: '!test:example', client: client);
  Map<String, dynamic>? sent;
  final sentTransactionIds = <String?>[];
  Event? received;
  Timeline? testTimeline;
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      testTimeline!;
  @override
  Future<Event?> getEventById(String eventID) async => received;
  @override
  bool get encrypted => true;
  @override
  Membership get membership => Membership.join;
  @override
  bool get canSendDefaultMessages => true;
  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
  }) async {
    sent = content;
    sentTransactionIds.add(txid);
    return 'event';
  }
}

class _MediaTimeline extends Fake implements Timeline {
  _MediaTimeline(this.events);
  @override
  final List<Event> events;
  @override
  void cancelSubscriptions() {}
}

class _ReceivedMedia extends Event {
  _ReceivedMedia(
      Room room, String id, Map<String, dynamic> extension, this.bytes,
      {bool decrypted = true, this.failDownload = false})
      : super(
            room: room,
            eventId: id,
            senderId: '@sender:test',
            type: EventTypes.Message,
            originServerTs: DateTime.utc(2026),
            content: {
              'msgtype': MessageTypes.Image,
              'body': 'image.png',
              'file': {
                'url': 'mxc://test/file',
                'key': {'k': 'deliberately-different'}
              },
              'info': {
                'thumbnail_file': {'url': 'mxc://test/thumbnail'}
              },
              ...extension
            },
            originalSource: decrypted
                ? MatrixEvent(
                    content: {},
                    type: EventTypes.Encrypted,
                    senderId: '@sender:test',
                    eventId: id,
                    originServerTs: DateTime.utc(2026))
                : null);
  final Uint8List bytes;
  final bool failDownload;
  int downloads = 0;
  @override
  Future<MatrixFile> downloadAndDecryptAttachment(
      {bool getThumbnail = false,
      Future<Uint8List> Function(Uri)? downloadCallback,
      bool fromLocalStoreOnly = false}) async {
    downloads++;
    if (failDownload) throw const FormatException('Bad current envelope');
    return MatrixFile(bytes: bytes, name: 'image.png');
  }
}

/// A controllable streaming transport: it schedules each chunk separately so
/// tests can prove a bounded reader cancels before later chunks are consumed.
final class _StreamingHttpClient extends http.BaseClient {
  _StreamingHttpClient(this.statusCode, this.chunks);

  final int statusCode;
  final List<List<int>> chunks;
  final emittedChunkIndexes = <int>[];
  String? authorization;
  bool cancelled = false;
  var closedNormally = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    authorization = request.headers['authorization'];
    late StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        void emit(int index) {
          if (cancelled || index >= chunks.length) return;
          emittedChunkIndexes.add(index);
          controller.add(chunks[index]);
          if (index + 1 == chunks.length) {
            closedNormally = true;
            controller.close();
          } else {
            scheduleMicrotask(() => emit(index + 1));
          }
        }

        emit(0);
      },
      onCancel: () {
        cancelled = !closedNormally;
      },
    );
    return http.StreamedResponse(controller.stream, statusCode);
  }
}

final class _DownloadClient extends Client {
  _DownloadClient(http.Client httpClient)
      : super('bounded-download-test', httpClient: httpClient);

  @override
  String? get accessToken => 'download-token';
}

final class _DownloadRoom extends Room {
  _DownloadRoom(Client client) : super(id: '!bounded:test', client: client);
}

final class _DownloadedEvent extends Event {
  _DownloadedEvent(Room room)
      : super(
          room: room,
          eventId: r'$download',
          senderId: '@sender:test',
          type: EventTypes.Message,
          originServerTs: DateTime.utc(2026),
          content: {
            'msgtype': MessageTypes.File,
            'body': 'download.bin',
            'url': 'mxc://test/download',
          },
        );

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
  }) async {
    final bytes = await downloadCallback!(Uri.parse('https://test/download'));
    return MatrixFile(bytes: bytes, name: 'download.bin');
  }
}

Future<MatrixRoomTimelineAdapter> _adapter(
    _UploadRoom room, List<Event> events) async {
  final client = room.client as _UploadClient;
  client.room = room;
  room.testTimeline = _MediaTimeline(events);
  final owner =
      MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
  final lease = await owner.openRoomLease(room.id);
  return MatrixRoomTimelineAdapter(
      await lease.openRoomTimeline(onUpdate: () {}));
}

void main() {
  test('video loader that already caches its content never awaits itself',
      () async {
    final payload = Uint8List.fromList(
        [0, 0, 0, 24, ...ascii.encode('ftypisom'), ...List<int>.filled(12, 0)]);
    final key = MediaCacheKey(
        roomId: '!nested-video',
        eventId: 'v',
        contentSha256: sha256.convert(payload).toString());
    var downloads = 0;
    final load = resolveCachedVideoFile(
        key: key,
        loaderCachesContent: true,
        decrypt: () => loadMediaWithCache(key, () async {
              downloads++;
              return payload;
            }));
    try {
      final file = await load.timeout(const Duration(seconds: 1));
      expect(await file.readAsBytes(), payload);
      expect(downloads, 1);
    } finally {
      clearMediaMemoryCaches();
      await load.then<void>((_) {}, onError: (Object _) {});
    }
  });

  test('cold cache source work has a shared three-request limit', () async {
    final gates = List.generate(4, (_) => Completer<Uint8List>());
    final threeStarted = Completer<void>();
    var started = 0;
    final loads = [
      for (var i = 0; i < 4; i++)
        loadMediaWithCache(
            MediaCacheKey(
                roomId: '!scheduler',
                eventId: '$i',
                contentSha256: sha256.convert([i]).toString()), () {
          started++;
          if (started == 3) threeStarted.complete();
          return gates[i].future;
        })
    ];
    await threeStarted.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final beforeRelease = started;
    for (var i = 0; i < gates.length; i++) {
      gates[i].complete(Uint8List.fromList([i]));
    }
    await Future.wait(loads);
    expect(beforeRelease, 3);
    expect(started, 4);
  });

  final bytes = Uint8List.fromList(utf8.encode('abc'));
  final hash = sha256.convert(bytes).toString();
  setUp(() async {
    clearMediaMemoryCaches();
    SharedPreferences.setMockInitialValues({});
    final root = Directory(
        '../../docs/verification/artifacts/2026-09-11/performance/media-cache-fixtures');
    await root.create(recursive: true);
    final scratch = await root.createTemp('case-');
    PathProviderPlatform.instance = _Paths(scratch.absolute.path);
    addTearDown(() => scratch.delete(recursive: true));
  });
  test('bounded encrypted download authenticates and stops after its byte cap',
      () async {
    final transport = _StreamingHttpClient(200, const <List<int>>[
      [1, 2],
      [3, 4],
      [5, 6]
    ]);
    final event = _DownloadedEvent(_DownloadRoom(_DownloadClient(transport)));

    await expectLater(
      downloadMediaContentBounded(event, maxDownloadBytes: 3),
      throwsA(isA<MediaContentLimitException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(transport.authorization, 'Bearer download-token');
    expect(transport.cancelled, isTrue);
    expect(transport.emittedChunkIndexes, [0, 1],
        reason: 'The reader must not request the third chunk after overflow.');
  });
  test('bounded encrypted download cancels a non-success response stream',
      () async {
    final transport = _StreamingHttpClient(503, const <List<int>>[
      [1, 2],
      [3, 4],
    ]);
    final event = _DownloadedEvent(_DownloadRoom(_DownloadClient(transport)));

    await expectLater(
      downloadMediaContentBounded(event, maxDownloadBytes: 3),
      throwsA(isA<http.ClientException>()),
    );

    expect(transport.authorization, 'Bearer download-token');
    expect(transport.cancelled, isTrue);
  });
  test(
      'bounded encrypted download accepts unknown declared size within its cap',
      () async {
    final transport = _StreamingHttpClient(200, const <List<int>>[
      [1, 2, 3]
    ]);
    final event = _DownloadedEvent(_DownloadRoom(_DownloadClient(transport)));

    expect(
      await downloadMediaContentBounded(event, maxDownloadBytes: 3),
      Uint8List.fromList([1, 2, 3]),
    );
    expect(transport.cancelled, isFalse);
  });
  test('20MiB encryption leaves the event loop responsive', () async {
    var eventLoopRan = false;
    final tick = Timer(Duration.zero, () => eventLoopRan = true);
    await MediaEnvelope.forBytes(Uint8List(20 * 1024 * 1024));
    tick.cancel();
    expect(eventLoopRan, isTrue,
        reason: 'Hash and AES work must run outside the UI isolate');
  });
  test('ADR raw digest HKDF vector and standard Matrix decryption', () async {
    final envelope = await MediaEnvelope.forBytes(bytes);
    expect(envelope.contentSha256, hash);
    String hex(List<int> b) =>
        b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    expect(hex(base64Url.decode(base64Url.normalize(envelope.encrypted.k))),
        '649f2f0e748acc0f6ccc7c6b0e679c8e6fd35c98640435d88bea79501668e95a');
    expect(hex(base64.decode(base64.normalize(envelope.encrypted.iv))),
        'cc73dc7a5ce580ec0000000000000000');
    expect(await decryptFileImplementation(envelope.encrypted), bytes);
    expect((await MediaEnvelope.forBytes(bytes)).encrypted.data,
        envelope.encrypted.data);
  });
  test(
      'prepared typed media keeps metadata plaintext preview and envelope on retry',
      () async {
    final video =
        MatrixVideoFile(bytes: bytes, name: 'clip.mp4', duration: 42, width: 3);
    final thumb = MatrixImageFile(
        bytes: Uint8List.fromList([4, 5]),
        name: 'thumb.jpg',
        width: 1,
        height: 2);
    final prepared = await prepareContentAddressedMedia(
        file: video,
        thumbnail: thumb,
        extraContent: {
          'chatflow_media': {'v': 9},
          'info': {'bad': true}
        });
    expect(prepared.file, isA<MatrixVideoFile>());
    expect(prepared.file.bytes, bytes);
    expect(prepared.file.info['duration'], 42);
    expect(prepared.thumbnail!.info['h'], 2);
    final encrypted = await prepared.file.encrypt();
    expect(identical(await prepared.file.encrypt(), encrypted), isTrue);
    expect(await decryptFileImplementation(encrypted), bytes);
    expect(prepared.extraContent!['chatflow_media']['content_sha256'], hash);
    expect(prepared.extraContent!['chatflow_media']['thumbnail_sha256'],
        sha256.convert([4, 5]).toString());
    expect(prepared.extraContent!.containsKey('info'), isFalse);
    final random = await prepareContentAddressedMedia(
        file: video,
        deterministic: false,
        extraContent: {
          'chatflow_media': {'v': 1}
        });
    expect(
        random.extraContent?.containsKey('chatflow_media') ?? false, isFalse);
    expect((await random.file.encrypt()).k,
        isNot((await random.file.encrypt()).k));
  });
  test('strict extension only from successfully decrypted events', () {
    expect(
        TrustedMediaHashes.parse({
          'chatflow_media': {'v': 1, 'content_sha256': hash}
        }, decrypted: true)!
            .contentSha256,
        hash);
    expect(
        TrustedMediaHashes.parse({
          'chatflow_media': {'v': 1, 'content_sha256': hash}
        }, decrypted: false),
        isNull);
    expect(TrustedMediaHashes.parse({}, decrypted: true), isNull);
    for (final value in [
      null,
      {},
      {'v': 2, 'content_sha256': hash},
      {'v': 1, 'content_sha256': hash.toUpperCase()},
      {'v': 1, 'content_sha256': hash, 'thumbnail_sha256': 2}
    ]) {
      expect(
          () => TrustedMediaHashes.parse({'chatflow_media': value},
              decrypted: true),
          throwsFormatException);
    }
  });
  test(
      'cross room content hits zero download and rejects same length corruption',
      () async {
    final a = MediaCacheKey(roomId: '!a', eventId: 'a', contentSha256: hash);
    final b = MediaCacheKey(roomId: '!b', eventId: 'b', contentSha256: hash);
    await loadMediaWithCache(a, () async => bytes);
    expect(
        await loadMediaWithCache(
            b, () => throw StateError('must not decrypt current envelope')),
        bytes);
    final file =
        await MediaCache.cached(b.roomId, b.eventId, contentSha256: hash);
    expect(file!.path.replaceAll('\\', '/'), contains('/objects/$hash'));
    await file.writeAsBytes([3, 2, 1]);
    clearMediaMemoryCaches(); // Exercise corrupted disk, not a valid warm copy.
    var downloads = 0;
    expect(
        await loadMediaWithCache(b, () async {
          downloads++;
          return bytes;
        }),
        bytes);
    expect(downloads, 1);
    final wrongHash = sha256.convert([9]).toString();
    final bad =
        MediaCacheKey(roomId: '!a', eventId: 'bad', contentSha256: wrongHash);
    await expectLater(
        loadMediaWithCache(bad, () async => bytes), throwsFormatException);
    expect(
        await MediaCache.cached(bad.roomId, bad.eventId,
            contentSha256: wrongHash),
        isNull);
  });
  test('producer mutation cannot corrupt memory and cross-room loads coalesce',
      () async {
    final memory = MediaMemoryCache();
    final key = MediaCacheKey(roomId: '!a', eventId: 'a', contentSha256: hash);
    final mutable = Uint8List.fromList(bytes);
    memory.put(key.cacheId, mutable);
    mutable[0] = 0;
    expect(memory.get(key.cacheId), bytes);
    var downloads = 0;
    Future<Uint8List> source() async {
      downloads++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return bytes;
    }

    await Future.wait([
      loadMediaWithCache(key, source),
      loadMediaWithCache(
          MediaCacheKey(roomId: '!b', eventId: 'b', contentSha256: hash),
          source)
    ]);
    expect(downloads, 1);
  });
  test('SDK wire upload has only ciphertext; event holds hashes and metadata',
      () async {
    final client = _UploadClient();
    final room = _UploadRoom(client);
    client.room = room;
    await MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'))
        .sendEncryptedMedia(room.id, bytes, 'video/mp4',
            filename: 'clip.mp4',
            thumbnailBytes: Uint8List.fromList([4, 5]),
            thumbnailWidth: 1,
            thumbnailHeight: 2,
            extraContent: {
          'info': {'duration': 42, 'w': 3},
          'chatflow_media': {'v': 99}
        });
    expect(client.uploads.length, 2);
    expect(client.uploadNames, ['crypt', 'crypt']);
    expect(client.uploads.first,
        (await MediaEnvelope.forBytes(bytes)).encrypted.data);
    expect(client.uploads.first, isNot(bytes));
    expect(room.sent!['chatflow_media']['content_sha256'], hash);
    expect(room.sent!['file']['v'], 'v2');
    expect(room.sent!['info']['duration'], 42);
    expect(room.sent!['info']['thumbnail_info']['h'], 2);
    expect(room.sent!['info']['thumbnail_file']['key']['k'],
        (await MediaEnvelope.forBytes(Uint8List.fromList([4, 5]))).encrypted.k);
  });
  for (final failingPhase in ['main', 'thumbnail']) {
    test('SDK upload retries only the unfinished $failingPhase phase',
        () async {
      final client = _UploadClient();
      final room = _UploadRoom(client);
      client.room = room;
      final thumbnailBytes = Uint8List.fromList([4, 5]);
      final prepared = await prepareContentAddressedMedia(
          file: MatrixVideoFile(bytes: bytes, name: 'clip.mp4', duration: 42),
          thumbnail: MatrixImageFile(
              bytes: thumbnailBytes, name: 'thumb.jpg', width: 1, height: 2));
      final encrypted = await prepared.file.encrypt();
      final encryptedThumbnail = await prepared.thumbnail!.encrypt();
      var mainAttempts = 0;
      var thumbnailAttempts = 0;
      client.uploadResponse = (attempt) async {
        final isMain = listEquals(client.uploads[attempt - 1], encrypted.data);
        final phaseAttempt = isMain ? ++mainAttempts : ++thumbnailAttempts;
        if ((isMain ? 'main' : 'thumbnail') == failingPhase &&
            phaseAttempt == 1) {
          throw const SocketException('transient upload failure');
        }
        return Uri.parse(
            'mxc://test/${isMain ? 'main' : 'thumbnail'}-$phaseAttempt');
      };

      expect(
          await room.sendFileEvent(prepared.file,
              thumbnail: prepared.thumbnail,
              extraContent: prepared.extraContent,
              txid: 'stable-upload-transaction'),
          'event');

      expect(mainAttempts, failingPhase == 'main' ? 2 : 1);
      expect(thumbnailAttempts, failingPhase == 'thumbnail' ? 2 : 1);
      expect(
          client.uploads,
          failingPhase == 'main'
              ? [encrypted.data, encrypted.data, encryptedThumbnail.data]
              : [
                  encrypted.data,
                  encryptedThumbnail.data,
                  encryptedThumbnail.data
                ]);
      expect(client.uploadNames, everyElement('crypt'));
      expect(room.sentTransactionIds, ['stable-upload-transaction']);
      expect(client.syncTransactionIds, isNotEmpty);
      expect(
          client.syncTransactionIds, everyElement('stable-upload-transaction'));
      final content = room.sent!;
      void checkDescriptor(
          dynamic descriptor, EncryptedFile envelope, String uri) {
        expect(descriptor['url'], uri);
        expect(descriptor['v'], 'v2');
        expect(descriptor['key']['k'], envelope.k);
        expect(descriptor['iv'], envelope.iv);
        expect(descriptor['hashes']['sha256'], envelope.sha256);
      }

      checkDescriptor(content['file'], encrypted,
          'mxc://test/main-${failingPhase == 'main' ? 2 : 1}');
      checkDescriptor(content['info']['thumbnail_file'], encryptedThumbnail,
          'mxc://test/thumbnail-${failingPhase == 'thumbnail' ? 2 : 1}');
      expect(content.containsKey('url'), isFalse);
      expect(content['info'].containsKey('thumbnail_url'), isFalse);
      expect(content['info']['duration'], 42);
      expect(content['info']['thumbnail_info']['h'], 2);
      expect(content['chatflow_media']['content_sha256'], hash);
      expect(await decryptFileImplementation(encrypted), bytes);
      expect(
          await decryptFileImplementation(encryptedThumbnail), thumbnailBytes);
      expect(room.sendingFilePlaceholders, isEmpty);
      expect(room.sendingFileThumbnails, isEmpty);
    });

    test('SDK upload stops on a permanent $failingPhase failure', () async {
      final client = _UploadClient();
      final room = _UploadRoom(client);
      client.room = room;
      final failureAttempt = failingPhase == 'main' ? 1 : 2;
      final error = MatrixException(http.Response(
          '{"errcode":"M_FORBIDDEN","error":"Upload denied"}', 403));
      client.uploadResponse = (attempt) async {
        if (attempt == failureAttempt) throw error;
        return Uri.parse('mxc://test/main');
      };
      final prepared = await prepareContentAddressedMedia(
          file: MatrixVideoFile(bytes: bytes, name: 'clip.mp4'),
          thumbnail: MatrixImageFile(
              bytes: Uint8List.fromList([4, 5]), name: 'thumb.jpg'));

      await expectLater(
          room.sendFileEvent(prepared.file,
              thumbnail: prepared.thumbnail, txid: 'permanent-upload-failure'),
          throwsA(same(error)));

      expect(client.uploads.length, failureAttempt);
      expect(room.sentTransactionIds, isEmpty);
      expect(room.sent, isNull);
      expect(
          client.syncTransactionIds, everyElement('permanent-upload-failure'));
    });
  }
  test('prepared images skip SDK post-encryption resizing and retain thumbnail',
      () async {
    final client = _UploadClient();
    final room = _UploadRoom(client);
    client.room = room;
    final prepared = await prepareContentAddressedMedia(
        file: MatrixImageFile(
            bytes: bytes, name: 'already-small.png', width: 2, height: 3),
        thumbnail: MatrixImageFile(
            bytes: Uint8List.fromList([4]),
            name: 'thumb.png',
            width: 1,
            height: 1));
    await room.sendFileEvent(prepared.file,
        thumbnail: prepared.thumbnail,
        shrinkImageMaxDimension: 1,
        extraContent: prepared.extraContent);
    expect(client.uploads.first, (await prepared.file.encrypt()).data);
    expect(room.sent!['info']['w'], 2);
    expect(room.sent!['info']['thumbnail_info']['w'], 1);
  });
  test(
      'image automatic thumbnail preprocessing happens before content derivation',
      () async {
    final client = _UploadClient();
    final room = _UploadRoom(client);
    client.room = room;
    var resizes = 0;
    client.customImageResizer = (args) async {
      resizes++;
      expect(args.bytes, bytes);
      return MatrixImageFileResizedResponse(
          bytes: Uint8List.fromList([7]),
          width: 1,
          height: 1,
          originalWidth: 12,
          originalHeight: 15);
    };
    await MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'))
        .sendEncryptedMedia(room.id, bytes, 'image/png',
            filename: 'image.png',
            extraContent: {
          'info': {'w': 12, 'h': 15}
        });
    expect(resizes, 1);
    expect(room.sent!['info']['w'], 12);
    expect(room.sent!['chatflow_media']['content_sha256'], hash);
    expect(room.sent!['chatflow_media']['thumbnail_sha256'],
        sha256.convert([7]).toString());
    expect(client.uploads.last,
        (await MediaEnvelope.forBytes(Uint8List.fromList([7]))).encrypted.data);
  });
  test(
      'decrypted timeline hash authority bypasses a bad current envelope only on hot content',
      () async {
    final client = _UploadClient();
    final room = _UploadRoom(client);
    final extension = {
      'chatflow_media': {
        'v': 1,
        'content_sha256': hash,
        'thumbnail_sha256': hash
      }
    };
    final first = _ReceivedMedia(room, 'first', extension, bytes);
    final second =
        _ReceivedMedia(room, 'second', extension, bytes, failDownload: true);
    final adapter = await _adapter(room, [first, second]);
    await expectLater(adapter.loadAttachment('second'), throwsFormatException);
    expect(await adapter.loadAttachment('first'), bytes);
    expect(await adapter.loadAttachment('second'), bytes);
    second.content['info'] = <String, dynamic>{};
    expect(await adapter.loadThumbnail('second'), bytes);
    expect(first.downloads, 1);
    expect(second.downloads, 1,
        reason: 'only the initial cold request touched the bad envelope');
    final corrupt = _ReceivedMedia(
        room,
        'bad-extension',
        {
          'chatflow_media': {'v': 2}
        },
        bytes);
    final invalidAdapter = await _adapter(room, [corrupt]);
    await expectLater(
        invalidAdapter.loadAttachment(corrupt.eventId), throwsFormatException);
    await expectLater(
        invalidAdapter.loadThumbnail(corrupt.eventId), throwsFormatException);
    expect(corrupt.downloads, 0);
    final untrusted = _ReceivedMedia(room, 'raw', extension, bytes,
        decrypted: false, failDownload: true);
    await expectLater((await _adapter(room, [untrusted])).loadAttachment('raw'),
        throwsFormatException);
    expect(untrusted.downloads, 1,
        reason: 'unencrypted extension cannot claim shared cached content');
  });
  test(
      'content video playback renames the single verified blob and repairs corruption',
      () async {
    final payload = Uint8List.fromList(
        [0, 0, 0, 24, ...ascii.encode('ftypisom'), ...List<int>.filled(12, 0)]);
    final videoHash = sha256.convert(payload).toString();
    final first =
        MediaCacheKey(roomId: '!a', eventId: 'movie', contentSha256: videoHash);
    final second =
        MediaCacheKey(roomId: '!b', eventId: 'copy', contentSha256: videoHash);
    final file =
        await resolveCachedVideoFile(key: first, decrypt: () async => payload);
    expect(file.path, endsWith('$videoHash.mp4'));
    expect(await File(file.path.substring(0, file.path.length - 4)).exists(),
        isFalse);
    final hot = await resolveCachedVideoFile(
        key: second, decrypt: () => throw StateError('no download'));
    expect(hot.path, file.path);
    final changed = Uint8List.fromList(payload)..[0] = 1;
    await file.writeAsBytes(changed);
    clearMediaMemoryCaches(); // Force the disk-integrity repair path.
    final memory = MediaMemoryCache();
    var downloads = 0;
    final repaired = await resolveCachedVideoFile(
        key: second,
        memoryCache: memory,
        decrypt: () async {
          downloads++;
          return payload;
        });
    expect(downloads, 1);
    expect(await repaired.readAsBytes(), payload);
  });
  test(
      'trusted hash rejects plaintext URLs only on cold attachment and thumbnail paths',
      () async {
    final client = _UploadClient();
    final room = _UploadRoom(client);
    final event = _ReceivedMedia(
        room,
        'plain-url',
        {
          'chatflow_media': {
            'v': 1,
            'content_sha256': hash,
            'thumbnail_sha256': hash
          }
        },
        bytes);
    event.content.remove('file');
    event.content['url'] = 'mxc://test/plain';
    event.content['info'] = {'thumbnail_url': 'mxc://test/plain-thumb'};
    final adapter = await _adapter(room, [event]);
    await expectLater(
        adapter.loadAttachment(event.eventId), throwsFormatException);
    await expectLater(
        adapter.loadThumbnail(event.eventId), throwsFormatException);
    expect(event.downloads, 0);
    await MediaCache.store(room.id, 'seed', bytes,
        accountId: client.userID ?? '', contentSha256: hash);
    expect(await adapter.loadAttachment(event.eventId), bytes);
    expect(await adapter.loadThumbnail(event.eventId), bytes);
    expect(event.downloads, 0);
  });
  test(
      'announcement hot content does not require a current attachment descriptor',
      () async {
    final client = _UploadClient();
    final room = _UploadRoom(client);
    final event = _ReceivedMedia(
        room,
        'announcement',
        {
          'chatflow_media': {'v': 1, 'content_sha256': hash}
        },
        bytes,
        failDownload: true);
    event.content.remove('file');
    room.received = event;
    await MediaCache.store(room.id, 'seed', bytes,
        accountId: client.userID ?? '', contentSha256: hash);
    expect(await MatrixGroupAnnouncementService(room).loadImage(event.eventId),
        bytes);
    expect(event.downloads, 0);
  });
}
