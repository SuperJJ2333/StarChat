import 'dart:async';
import 'dart:io';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/content_addressed_media.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_outgoing_work_coordinator.dart';

class ForwardTimeline extends Fake implements Timeline {
  ForwardTimeline(this.events);
  @override
  final List<Event> events;
  @override
  void cancelSubscriptions() {}
}

class ForwardClient extends Client {
  ForwardClient({http.Client? httpClient, this.userId = '@alice:test'})
      : super('video-forward', httpClient: httpClient);
  final String userId;
  @override
  bool get fileEncryptionEnabled => true;
  @override
  bool get encryptionEnabled => true;
  @override
  String? get userID => userId;
  @override
  String? get deviceID => 'ALICE';
  @override
  String? get accessToken => 'test-token';
  @override
  Uri? get homeserver => Uri.parse('https://matrix.test');
  @override
  Future<bool> authenticatedMediaSupported() async => true;
  final destinations = <String, Room>{};
  @override
  Room? getRoomById(String id) => destinations[id];
}

class ForwardRoom extends Room {
  ForwardRoom(
      {required super.id,
      required super.client,
      this.secure = true,
      this.direct = false});
  final bool direct;
  @override
  bool get isDirectChat => direct;
  @override
  Membership get membership => Membership.join;
  @override
  bool get canSendDefaultMessages => true;
  final bool secure;
  late ForwardTimeline timeline;
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      timeline;
  MatrixFile? sent;
  final List<MatrixFile> sentFiles = [];
  MatrixImageFile? sentThumbnail;
  var failuresBeforeSend = 0;
  final List<String?> sentTxids = [];
  @override
  bool get encrypted => secure;
  @override
  Future<String?> sendFileEvent(
    MatrixFile file, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    int? shrinkImageMaxDimension,
    MatrixImageFile? thumbnail,
    Map<String, dynamic>? extraContent,
    String? threadRootEventId,
    String? threadLastEventId,
  }) async {
    sent = file;
    sentFiles.add(file);
    sentThumbnail = thumbnail;
    sentTxids.add(txid);
    if (failuresBeforeSend > 0) {
      failuresBeforeSend--;
      throw StateError('held target failure');
    }
    expect(extraContent?['chatflow_media']['v'], 1);
    return r'$copy';
  }
}

/// Uses the real SDK attachment downloader/decryptor. Unlike [ForwardVideo],
/// it cannot shortcut the encrypted descriptor with a test override.
final class AuthenticatedForwardVideo extends Event {
  AuthenticatedForwardVideo._({
    required super.room,
    required String id,
    required MediaEnvelope envelope,
    required int contentBytes,
    this.messageType = MessageTypes.Video,
    this.mimeType = 'video/mp4',
    this.durationMilliseconds = 3200,
    this.thumbnail,
    this.infoOverride,
  }) : super(
          type: EventTypes.Message,
          eventId: id,
          senderId: '@alice:test',
          originServerTs: DateTime.utc(2026),
          originalSource: MatrixEvent(
            type: EventTypes.Encrypted,
            content: const {},
            senderId: '@alice:test',
            eventId: id,
            originServerTs: DateTime.utc(2026),
          ),
          content: {
            'msgtype': messageType,
            'body': 'clip-$id.mp4',
            'info': infoOverride ??
                {
                  'mimetype': mimeType,
                  'size': contentBytes,
                  'w': 720,
                  'h': 1280,
                  'duration': durationMilliseconds,
                  if (thumbnail != null)
                    'thumbnail_file': _encryptedDescriptor(
                        'mxc://old/cipher-thumb-${id.substring(1)}', thumbnail),
                  if (thumbnail != null) 'thumbnail_info': {'w': 240, 'h': 160},
                },
            'file': _encryptedDescriptor(
                'mxc://old/cipher-${id.substring(1)}', envelope),
            'chatflow_media': {
              'v': 1,
              'content_sha256': envelope.contentSha256,
            },
          },
        );

  @override
  final String messageType;
  final String mimeType;
  final int durationMilliseconds;
  final MediaEnvelope? thumbnail;
  final Object? infoOverride;
}

Map<String, Object?> _encryptedDescriptor(String url, MediaEnvelope envelope) =>
    {
      'url': url,
      'v': 'v2',
      'key': {
        'alg': 'A256CTR',
        'ext': true,
        'k': envelope.encrypted.k,
        'key_ops': ['encrypt', 'decrypt'],
        'kty': 'oct',
      },
      'iv': envelope.encrypted.iv,
      'hashes': {'sha256': envelope.encrypted.sha256},
    };

MatrixSdkE2eeClient forwardOwner(
  ForwardClient client, {
  Future<void> Function(Client? client)? clearClientData,
}) =>
    MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://test'),
      clearClientData: clearClientData,
      readContinuityMetadata: (active) async => MatrixClientContinuityMetadata(
        isLoggedIn: true,
        userId: active.userID,
        deviceId: active.deviceID,
        ed25519Fingerprint: 'fixture',
        databaseGeneration: 'fixture',
      ),
    );

class ForwardVideo extends Event {
  ForwardVideo(Room room,
      {this.id = r'$video',
      bool withInfo = true,
      int? declaredSize,
      this.byteSize = 3})
      : super(
          room: room,
          type: EventTypes.Message,
          eventId: id,
          senderId: '@alice:test',
          originServerTs: DateTime.utc(2026),
          content: {
            'msgtype': MessageTypes.Video,
            'body': 'clip.mp4',
            if (withInfo)
              'info': {
                'mimetype': 'video/mp4',
                if (declaredSize != null) 'size': declaredSize,
                'w': 720,
                'h': 1280,
                'duration': 3200,
                'thumbnail_url': 'mxc://old/thumbnail',
              },
            'file': {'url': 'mxc://old/encrypted-video'},
          },
        );
  final int byteSize;
  final String id;
  int decryptions = 0;
  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
  }) async {
    decryptions++;
    return MatrixFile(
        bytes:
            byteSize == 3 ? Uint8List.fromList([1, 2, 3]) : Uint8List(byteSize),
        name: 'clip.mp4');
  }
}

class ForwardPaths extends PathProviderPlatform {
  ForwardPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  setUp(() async {
    final root = Directory(
        '../../docs/verification/artifacts/2026-09-09/media-dedup-implementation/mobile/forward');
    await root.create(recursive: true);
    final dir = await root.createTemp('case-');
    PathProviderPlatform.instance = ForwardPaths(dir.absolute.path);
    addTearDown(() => dir.delete(recursive: true));
  });
  test('owner forwards two frozen existing media sources to two targets',
      () async {
    final onePlaintext = Uint8List.fromList([1, 2, 3]);
    final twoPlaintext = Uint8List.fromList([4, 5, 6]);
    final one = await MediaEnvelope.forBytes(onePlaintext);
    final two = await MediaEnvelope.forBytes(twoPlaintext);
    var downloads = 0;
    final client = ForwardClient(httpClient: MockClient((request) async {
      downloads++;
      expect(request.headers['authorization'], 'Bearer test-token');
      return http.Response.bytes(
        request.url.path.endsWith('cipher-one')
            ? one.encrypted.data
            : two.encrypted.data,
        200,
      );
    }));
    final source = ForwardRoom(id: '!source:test', client: client);
    final a = ForwardRoom(id: '!a:test', client: client);
    final b = ForwardRoom(id: '!b:test', client: client);
    client.destinations.addAll({source.id: source, a.id: a, b.id: b});
    source.timeline = ForwardTimeline([
      AuthenticatedForwardVideo._(
          room: source, id: r'$one', envelope: one, contentBytes: 3),
      AuthenticatedForwardVideo._(
          room: source, id: r'$two', envelope: two, contentBytes: 3),
    ]);
    final owner = forwardOwner(client);
    final lease = await owner.openRoomLease(source.id);
    await lease.openRoomTimeline(onUpdate: () {});
    final jobs = await lease.enqueueForward(
      batchId: 'two-media',
      messages: [
        lease.snapshotForwardSource(r'$one'),
        lease.snapshotForwardSource(r'$two')
      ],
      targetRoomIds: [a.id, b.id],
    );
    await owner.outgoingWork.drain();
    expect(jobs.expand((job) => job.items).map((item) => item.state),
        everyElement(MatrixOutgoingWorkState.sent));
    expect(downloads, 2);
    expect(a.sentFiles.map((file) => file.bytes),
        unorderedEquals([onePlaintext, twoPlaintext]));
    expect(b.sentFiles.map((file) => file.bytes),
        unorderedEquals([onePlaintext, twoPlaintext]));
    expect(a.sentTxids,
        unorderedEquals(['outgoing-two-media-0-0', 'outgoing-two-media-1-0']));
    expect(b.sentTxids,
        unorderedEquals(['outgoing-two-media-0-1', 'outgoing-two-media-1-1']));
  });
  for (final revoke in ['lease', 'account', 'destination']) {
    test('prepared media cannot start upload after $revoke revocation',
        () async {
      final client = ForwardClient();
      final target = ForwardRoom(id: '!target:test', client: client);
      client.destinations[target.id] = target;
      final owner = forwardOwner(client, clearClientData: (_) async {});
      final lease = await owner.openRoomLease(target.id);
      final sending =
          lease.sendEncryptedMedia(target.id, Uint8List(20971520), 'video/mp4');
      Future<void>? clearing;
      final revoked = Completer<void>();
      Timer.run(() {
        if (revoke == 'lease') lease.revokeNow();
        if (revoke == 'account') clearing = owner.clearLocalChatData();
        if (revoke == 'destination') {
          client.destinations[target.id] =
              ForwardRoom(id: target.id, client: client);
        }
        revoked.complete();
      });
      await expectLater(sending, throwsStateError);
      await revoked.future;
      await clearing;
      expect(target.sent, isNull);
    });
  }
  test('forwarding cannot upload after source lease is revoked during download',
      () async {
    final client = ForwardClient();
    final source = ForwardRoom(id: '!source:test', client: client);
    final target = ForwardRoom(id: '!target:test', client: client);
    client.destinations.addAll({source.id: source, target.id: target});
    final video = ForwardVideo(source, byteSize: 20971520);
    source.timeline = ForwardTimeline([video]);
    final owner = forwardOwner(client);
    final lease = await owner.openRoomLease(source.id);
    await lease.openRoomTimeline(onUpdate: () {});
    final sending =
        lease.forwardEncryptedCopy(source.id, target.id, video.eventId);
    Timer.run(lease.revokeNow);
    await expectLater(sending, throwsStateError);
    expect(target.sent, isNull);
  });
  for (final declared in [true, false]) {
    test(
        'group forwarded oversized video rejects ${declared ? 'before download' : 'after validating actual bytes'}',
        () async {
      final client = ForwardClient();
      final source = ForwardRoom(id: '!source:test', client: client);
      final target = ForwardRoom(id: '!target:test', client: client);
      client.destinations.addAll({source.id: source, target.id: target});
      final video = ForwardVideo(source,
          declaredSize: declared ? 20971521 : null, byteSize: 20971521);
      source.timeline = ForwardTimeline([video]);
      final owner = forwardOwner(client);
      final backend = await owner.openRoomLease(source.id);
      await backend.openRoomTimeline(onUpdate: () {});
      await expectLater(
          backend.forwardEncryptedCopy(source.id, target.id, video.eventId),
          throwsA(predicate((e) => e.toString() == '视频大小不能超过20MB')));
      expect(video.decryptions, declared ? 0 : 1);
      expect(target.sent, isNull);
    });
  }
  for (final direct in [false, true]) {
    test(
        'forward preserves ${direct ? 'private video above limit' : 'group exact 20MiB boundary'}',
        () async {
      final client = ForwardClient();
      final source = ForwardRoom(id: '!source:test', client: client);
      final target =
          ForwardRoom(id: '!target:test', client: client, direct: direct);
      client.destinations.addAll({source.id: source, target.id: target});
      final size = direct ? 20971521 : 20971520;
      final video = ForwardVideo(source, declaredSize: size, byteSize: size);
      source.timeline = ForwardTimeline([video]);
      final owner = forwardOwner(client);
      final backend = await owner.openRoomLease(source.id);
      await backend.openRoomTimeline(onUpdate: () {});
      await backend.forwardEncryptedCopy(source.id, target.id, video.eventId);
      expect(target.sent!.bytes.length, size);
    });
  }
  for (final withInfo in [true, false]) {
    test('video uses encrypted room attachment pipeline with info=$withInfo',
        () async {
      final client = ForwardClient();
      final source = ForwardRoom(id: '!source:test', client: client);
      final target = ForwardRoom(id: '!target:test', client: client);
      client.destinations.addAll({source.id: source, target.id: target});
      final video = ForwardVideo(source, withInfo: withInfo);
      source.timeline = ForwardTimeline([video]);
      final owner = forwardOwner(client);
      final backend = await owner.openRoomLease(source.id);
      await backend.openRoomTimeline(onUpdate: () {});
      await backend.forwardEncryptedCopy(source.id, target.id, video.eventId);
      expect(video.decryptions, 1);
      expect(target.sent, isA<MatrixVideoFile>());
      expect(target.sent!.msgType, MessageTypes.Video);
      expect(target.sent!.bytes, [1, 2, 3]);
      expect(target.sent!.name, 'clip.mp4');
      expect(target.sent!.info['mimetype'], 'video/mp4');
      expect(target.sent!.info['duration'], withInfo ? 3200 : null);
      expect(target.sent!.info['w'], withInfo ? 720 : null);
      expect(target.sent!.info['h'], withInfo ? 1280 : null);
      expect(target.sent!.info.containsKey('thumbnail_url'), isFalse);
    });
  }

  test(
      'legacy encrypted thumbnail reserves admission budget with no partial jobs',
      () async {
    final client = ForwardClient();
    final source = ForwardRoom(id: '!source:test', client: client);
    final target = ForwardRoom(id: '!target:test', client: client);
    client.destinations.addAll({source.id: source, target.id: target});
    final content = await MediaEnvelope.forBytes(Uint8List.fromList([1]));
    final thumb = await MediaEnvelope.forBytes(Uint8List.fromList([2]));
    const sixtyFourMiB = 64 * 1024 * 1024;
    source.timeline = ForwardTimeline([
      AuthenticatedForwardVideo._(
          room: source,
          id: r'$budget-one',
          envelope: content,
          contentBytes: sixtyFourMiB,
          thumbnail: thumb),
      AuthenticatedForwardVideo._(
          room: source,
          id: r'$budget-two',
          envelope: content,
          contentBytes: sixtyFourMiB,
          thumbnail: thumb),
    ]);
    final owner = forwardOwner(client);
    final lease = await owner.openRoomLease(source.id);
    await lease.openRoomTimeline(onUpdate: () {});

    await expectLater(
      lease.enqueueForward(
        batchId: 'budget',
        messages: [
          lease.snapshotForwardSource(r'$budget-one'),
          lease.snapshotForwardSource(r'$budget-two'),
        ],
        targetRoomIds: [target.id],
      ),
      throwsA(isA<MatrixOutgoingWorkCapacityException>()),
    );
    expect(owner.outgoingWork.itemsForRoom(target.id), isEmpty);
  });

  test('oversized hot thumbnail is dropped while its source media forwards',
      () async {
    var downloads = 0;
    final content = await MediaEnvelope.forBytes(Uint8List.fromList([1, 2]));
    final thumb = await MediaEnvelope.forBytes(Uint8List.fromList([3]));
    final client = ForwardClient(httpClient: MockClient((request) async {
      downloads++;
      return http.Response.bytes(content.encrypted.data, 200);
    }));
    final source = ForwardRoom(id: '!source:test', client: client);
    final target = ForwardRoom(id: '!target:test', client: client);
    client.destinations.addAll({source.id: source, target.id: target});
    final event = AuthenticatedForwardVideo._(
        room: source,
        id: r'$hot-thumb',
        envelope: content,
        contentBytes: 2,
        thumbnail: thumb);
    source.timeline = ForwardTimeline([event]);
    await loadMediaWithCache(
      MediaCacheKey(
        accountId: client.userID!,
        roomId: source.id,
        eventId: 'thumb:${event.eventId}',
        sourceIdentity:
            matrixMediaSourceIdentity(event.content, thumbnail: true),
      ),
      () async => Uint8List(512 * 1024 + 1),
    );
    final owner = forwardOwner(client);
    final lease = await owner.openRoomLease(source.id);
    await lease.openRoomTimeline(onUpdate: () {});
    await lease.enqueueForward(
      batchId: 'hot-thumb',
      messages: [lease.snapshotForwardSource(event.eventId)],
      targetRoomIds: [target.id],
    );
    await owner.outgoingWork.drain();

    expect(downloads, 1, reason: 'the oversized hot thumbnail was not fetched');
    expect(target.sentThumbnail, isNull);
    expect(target.sent?.bytes, [1, 2]);
  });

  test(
      'forwarded audio keeps pending voice kind and duration then sends m.audio',
      () async {
    final audio = await MediaEnvelope.forBytes(Uint8List.fromList([7, 8]));
    final client = ForwardClient(
        httpClient: MockClient(
            (_) async => http.Response.bytes(audio.encrypted.data, 200)));
    final source = ForwardRoom(id: '!source:test', client: client);
    final target = ForwardRoom(id: '!target:test', client: client);
    client.destinations.addAll({source.id: source, target.id: target});
    source.timeline = ForwardTimeline([
      AuthenticatedForwardVideo._(
        room: source,
        id: r'$voice',
        envelope: audio,
        contentBytes: 2,
        messageType: MessageTypes.Audio,
        mimeType: 'audio/ogg',
        durationMilliseconds: 2500,
      ),
    ]);
    final owner = forwardOwner(client);
    final lease = await owner.openRoomLease(source.id);
    await lease.openRoomTimeline(onUpdate: () {});
    final jobs = await lease.enqueueForward(
      batchId: 'voice',
      messages: [lease.snapshotForwardSource(r'$voice')],
      targetRoomIds: [target.id],
    );
    expect(jobs.single.items.single.presentation.kind,
        MatrixOutgoingPresentationKind.voice);
    expect(jobs.single.items.single.presentation.voiceDuration,
        const Duration(milliseconds: 2500));
    await owner.outgoingWork.drain();
    expect(target.sent, isA<MatrixAudioFile>());
    expect(target.sent?.msgType, MessageTypes.Audio);
  });

  test(
      'revoking the source lease during held download does not cancel admitted work',
      () async {
    final payload = await MediaEnvelope.forBytes(Uint8List.fromList([5]));
    final started = Completer<void>();
    final release = Completer<http.Response>();
    final client = ForwardClient(httpClient: MockClient((_) {
      started.complete();
      return release.future;
    }));
    final source = ForwardRoom(id: '!source:test', client: client);
    final target = ForwardRoom(id: '!target:test', client: client);
    client.destinations.addAll({source.id: source, target.id: target});
    source.timeline = ForwardTimeline([
      AuthenticatedForwardVideo._(
          room: source, id: r'$held', envelope: payload, contentBytes: 1),
    ]);
    final owner = forwardOwner(client);
    final lease = await owner.openRoomLease(source.id);
    await lease.openRoomTimeline(onUpdate: () {});
    await lease.enqueueForward(
      batchId: 'held',
      messages: [lease.snapshotForwardSource(r'$held')],
      targetRoomIds: [target.id],
    );
    await started.future;
    lease.revokeNow();
    release.complete(http.Response.bytes(payload.encrypted.data, 200));
    await owner.outgoingWork.drain();
    expect(target.sent?.bytes, [5]);
  });

  test('a frozen source cannot be admitted by another account in the same room',
      () async {
    final payload = await MediaEnvelope.forBytes(Uint8List.fromList([1]));
    final firstClient = ForwardClient();
    final source = ForwardRoom(id: '!shared:test', client: firstClient);
    final firstTarget = ForwardRoom(id: '!first:test', client: firstClient);
    firstClient.destinations
        .addAll({source.id: source, firstTarget.id: firstTarget});
    source.timeline = ForwardTimeline([
      AuthenticatedForwardVideo._(
          room: source, id: r'$account', envelope: payload, contentBytes: 1),
    ]);
    final firstOwner = forwardOwner(firstClient);
    final lease = await firstOwner.openRoomLease(source.id);
    await lease.openRoomTimeline(onUpdate: () {});
    final frozen = lease.snapshotForwardSource(r'$account');

    final secondClient = ForwardClient(userId: '@bob:test');
    final secondSource = ForwardRoom(id: source.id, client: secondClient);
    secondSource.timeline = ForwardTimeline(const []);
    final secondTarget = ForwardRoom(id: '!second:test', client: secondClient);
    secondClient.destinations
        .addAll({secondSource.id: secondSource, secondTarget.id: secondTarget});
    final secondOwner = forwardOwner(secondClient);
    await expectLater(
      secondOwner.enqueueForward(
        batchId: 'cross-account',
        messages: [frozen],
        targetRoomIds: [secondTarget.id],
      ),
      throwsStateError,
    );
    expect(secondOwner.outgoingWork.itemsForRoom(secondTarget.id), isEmpty);
  });

  test(
      'retry sends only failed target with its original txid and cached source',
      () async {
    var downloads = 0;
    final payload = await MediaEnvelope.forBytes(Uint8List.fromList([9]));
    final client = ForwardClient(httpClient: MockClient((_) async {
      downloads++;
      return http.Response.bytes(payload.encrypted.data, 200);
    }));
    final source = ForwardRoom(id: '!source:test', client: client);
    final a = ForwardRoom(id: '!a:test', client: client);
    final b = ForwardRoom(id: '!b:test', client: client)
      ..failuresBeforeSend = 1;
    client.destinations.addAll({source.id: source, a.id: a, b.id: b});
    source.timeline = ForwardTimeline([
      AuthenticatedForwardVideo._(
          room: source, id: r'$retry', envelope: payload, contentBytes: 1),
    ]);
    final owner = forwardOwner(client);
    final lease = await owner.openRoomLease(source.id);
    await lease.openRoomTimeline(onUpdate: () {});
    final jobs = await lease.enqueueForward(
      batchId: 'retry',
      messages: [lease.snapshotForwardSource(r'$retry')],
      targetRoomIds: [a.id, b.id],
    );
    await owner.outgoingWork.drain();
    final failed =
        jobs.single.items.singleWhere((item) => item.targetRoomId == b.id);
    expect(failed.state, MatrixOutgoingWorkState.failed);
    expect(downloads, 1);
    await owner.outgoingWork.retryItem(jobs.single.id, failed.id);
    await owner.outgoingWork.drain();
    expect(downloads, 1);
    expect(a.sentTxids, ['outgoing-retry-0-0']);
    expect(b.sentTxids, ['outgoing-retry-0-1', 'outgoing-retry-0-1']);
  });

  test('malformed info is treated as unknown-size legacy media', () async {
    final payload = await MediaEnvelope.forBytes(Uint8List.fromList([1]));
    final client = ForwardClient();
    final source = ForwardRoom(id: '!source:test', client: client);
    client.destinations[source.id] = source;
    source.timeline = ForwardTimeline([
      AuthenticatedForwardVideo._(
        room: source,
        id: r'$legacy-info',
        envelope: payload,
        contentBytes: 1,
        infoOverride: 'not a map',
      ),
    ]);
    final owner = forwardOwner(client);
    final lease = await owner.openRoomLease(source.id);
    await lease.openRoomTimeline(onUpdate: () {});
    final frozen = lease.snapshotForwardSource(r'$legacy-info')
        as MatrixOutgoingForwardMedia;
    expect(frozen.declaredContentBytes, isNull);
    expect(frozen.downloadLimitBytes, 100 * 1024 * 1024);
  });

  test('unencrypted destination fails before decrypting video', () async {
    final client = ForwardClient();
    final source = ForwardRoom(id: '!source:test', client: client);
    final target =
        ForwardRoom(id: '!target:test', client: client, secure: false);
    client.destinations.addAll({source.id: source, target.id: target});
    final video = ForwardVideo(source);
    source.timeline = ForwardTimeline([video]);
    final owner = forwardOwner(client);
    final backend = await owner.openRoomLease(source.id);
    await backend.openRoomTimeline(onUpdate: () {});
    await expectLater(
        backend.forwardEncryptedCopy(source.id, target.id, video.eventId),
        throwsStateError);
    expect(video.decryptions, 0);
    expect(target.sent, isNull);
  });
}
