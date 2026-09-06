import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/message_interaction_service.dart';

class ForwardTimeline extends Fake implements Timeline {
  ForwardTimeline(this.events);
  @override
  final List<Event> events;
}

class ForwardClient extends Client {
  ForwardClient() : super('video-forward');
  final destinations = <String, Room>{};
  @override
  Room? getRoomById(String id) => destinations[id];
}

class ForwardRoom extends Room {
  ForwardRoom({required super.id, required super.client, this.secure = true});
  final bool secure;
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
    expect(extraContent, isNull);
    return r'$copy';
  }
}

class ForwardVideo extends Event {
  ForwardVideo(Room room, {bool withInfo = true})
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
                'w': 720,
                'h': 1280,
                'duration': 3200,
                'thumbnail_url': 'mxc://old/thumbnail',
              },
            'file': {'url': 'mxc://old/encrypted-video'},
          },
        );
  int decryptions = 0;
  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
  }) async {
    decryptions++;
    return MatrixFile(bytes: Uint8List.fromList([1, 2, 3]), name: 'clip.mp4');
  }
}

void main() {
  for (final withInfo in [true, false]) {
    test('video uses encrypted room attachment pipeline with info=$withInfo',
        () async {
      final client = ForwardClient();
      final source = ForwardRoom(id: '!source:test', client: client);
      final target = ForwardRoom(id: '!target:test', client: client);
      client.destinations.addAll({source.id: source, target.id: target});
      final video = ForwardVideo(source, withInfo: withInfo);
      final backend = MatrixMessageInteractionBackend(
        client: client,
        timeline: ForwardTimeline([video]),
      );
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
    final backend = MatrixMessageInteractionBackend(
      client: client,
      timeline: ForwardTimeline([video]),
    );
    await expectLater(
        backend.forwardEncryptedCopy(source.id, target.id, video.eventId),
        throwsStateError);
    expect(video.decryptions, 0);
    expect(target.sent, isNull);
  });
}
