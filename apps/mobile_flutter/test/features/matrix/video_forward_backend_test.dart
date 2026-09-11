import 'dart:async';
import 'dart:io';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

class ForwardTimeline extends Fake implements Timeline {
  ForwardTimeline(this.events);
  @override
  final List<Event> events;
  @override
  void cancelSubscriptions() {}
}

class ForwardClient extends Client {
  ForwardClient() : super('video-forward');
  @override
  bool get fileEncryptionEnabled => true;
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
    expect(extraContent?['chatflow_media']['v'], 1);
    return r'$copy';
  }
}

class ForwardVideo extends Event {
  ForwardVideo(Room room,
      {bool withInfo = true, int? declaredSize, this.byteSize = 3})
      : super(
          room: room,
          type: EventTypes.Message,
          eventId: r'$video',
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
  setUp(() async {
    final root = Directory(
        '../../docs/verification/artifacts/2026-09-09/media-dedup-implementation/mobile/forward');
    await root.create(recursive: true);
    final dir = await root.createTemp('case-');
    PathProviderPlatform.instance = ForwardPaths(dir.absolute.path);
    addTearDown(() => dir.delete(recursive: true));
  });
  for (final revoke in ['lease', 'account', 'destination']) {
    test('prepared media cannot start upload after $revoke revocation',
        () async {
      final client = ForwardClient();
      final target = ForwardRoom(id: '!target:test', client: client);
      client.destinations[target.id] = target;
      final owner = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://test'), clearClientData: (_) async {});
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
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
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
      final owner =
          MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
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
      final owner =
          MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
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
      final owner =
          MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
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

  test('unencrypted destination fails before decrypting video', () async {
    final client = ForwardClient();
    final source = ForwardRoom(id: '!source:test', client: client);
    final target =
        ForwardRoom(id: '!target:test', client: client, secure: false);
    client.destinations.addAll({source.id: source, target.id: target});
    final video = ForwardVideo(source);
    source.timeline = ForwardTimeline([video]);
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final backend = await owner.openRoomLease(source.id);
    await backend.openRoomTimeline(onUpdate: () {});
    await expectLater(
        backend.forwardEncryptedCopy(source.id, target.id, video.eventId),
        throwsStateError);
    expect(video.decryptions, 0);
    expect(target.sent, isNull);
  });
}
