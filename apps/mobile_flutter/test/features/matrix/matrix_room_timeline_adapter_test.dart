import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:matrix/src/utils/file_send_request_credentials.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

class RetryTimeline extends Fake implements Timeline {
  @override
  final events = <Event>[];
}

class RetryClient extends Client {
  RetryClient() : super('retry-test');
  late Room room;
  @override
  Room? getRoomById(String id) => room.id == id ? room : null;
}

Future<MatrixRoomTimelineAdapter> openAdapter(
    RetryRoom room, Timeline timeline) async {
  (room.client as RetryClient).room = room;
  room.timeline = timeline;
  final owner =
      MatrixSdkE2eeClient(room.client, homeserver: Uri.parse('https://test'));
  final lease = await owner.openRoomLease(room.id);
  return MatrixRoomTimelineAdapter(
      await lease.openRoomTimeline(onUpdate: () {}));
}

class RetryRoom extends Room {
  RetryRoom() : super(id: '!retry:test', client: RetryClient());
  late Timeline timeline;
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      timeline;
  final sends = <Map<String, dynamic>>[];
  final transactions = <String?>[];
  Completer<String?>? pending;
  MatrixFile? retryFile;
  MatrixImageFile? retryThumbnail;
  Map<String, dynamic>? retryExtra;
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
    retryFile = file;
    retryThumbnail = thumbnail;
    retryExtra = extraContent;
    transactions.add(txid);
    return r'$uploaded';
  }

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
    sends.add(content);
    transactions.add(txid);
    return pending == null ? r'$sent' : await pending!.future;
  }
}

class RetryEvent extends Event {
  RetryEvent(RetryRoom room, this.timeline,
      {required String id,
      required int minute,
      super.status = EventStatus.error,
      Map<String, dynamic>? payload})
      : super(
            room: room,
            type: EventTypes.Message,
            eventId: id,
            senderId: '@me:test',
            originServerTs: DateTime.utc(2026, 9, 6, 10, minute),
            content: payload ?? {'msgtype': 'm.text', 'body': 'fixture'},
            unsigned: {
              'transaction_id': 'original-$id',
            });
  final RetryTimeline timeline;
  int cancellations = 0;
  @override
  Future<void> cancelSend() async {
    cancellations++;
    timeline.events.remove(this);
  }
}

void main() {
  test(
      'real SDK replacement invalidates content reply and redaction projection',
      () async {
    final room = RetryRoom();
    Map<String, dynamic> message(String body, String reply) => {
          'event_id': 'event',
          'type': EventTypes.Message,
          'sender': '@peer:test',
          'origin_server_ts': 1000,
          'content': {
            'msgtype': 'm.video',
            'body': body,
            'info': {
              'duration': 3200,
              'mimetype': 'video/mp4',
              'size': 900,
              'w': 40,
              'h': 30
            },
            'm.relates_to': {
              'm.in_reply_to': {'event_id': reply}
            }
          },
        };
    final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(
            events: [Event.fromJson(message('before', 'reply-a'), room)]));
    final adapter = await openAdapter(room, timeline);
    final original = adapter.snapshot().single;
    expect(original.replyToEventId, 'reply-a');
    room.client.onEvent.add(EventUpdate(
        roomID: room.id,
        type: EventUpdateType.timeline,
        content: message('after', 'reply-b')));
    await Future<void>.delayed(Duration.zero);
    final updated = adapter.snapshot().single;
    expect(updated.text, 'after');
    expect(updated.replyToEventId, 'reply-b');
    expect(updated.videoDuration, const Duration(milliseconds: 3200));
    expect(updated.attachmentSize, 900);
    expect(updated.imageWidth, 40);
    expect(identical(updated, original), isFalse);
    room.client.onEvent.add(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
      'event_id': 'redact',
      'type': EventTypes.Redaction,
      'sender': '@peer:test',
      'origin_server_ts': 2000,
      'redacts': 'event',
      'content': {},
    }));
    await Future<void>.delayed(Duration.zero);
    final recalled = adapter.snapshot().single;
    expect(recalled.isRecalled, isTrue);
    expect(recalled.replyToEventId, isNull);
    expect(recalled.text, isEmpty);
    expect(identical(recalled, adapter.snapshot().single), isTrue);
    adapter.dispose();
    await room.client.dispose();
  });

  test('unchanged failed SDK echo retains projected list', () async {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    timeline.events.addAll([
      RetryEvent(room, timeline, id: 'failed', minute: 1),
      RetryEvent(room, timeline,
          id: 'newer', minute: 2, status: EventStatus.synced),
    ]);
    final adapter = await openAdapter(room, timeline);
    final first = adapter.snapshot();
    expect(identical(adapter.snapshot(), first), isTrue);
  });

  test('SDK snapshot reuses unchanged rows and preserves SDK order', () async {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    final older = RetryEvent(room, timeline,
        id: 'older', minute: 2, status: EventStatus.synced);
    final newer = RetryEvent(room, timeline,
        id: 'newer', minute: 1, status: EventStatus.synced);
    timeline.events.addAll([newer, older]);
    final adapter = await openAdapter(room, timeline);
    final first = adapter.snapshot();
    final second = adapter.snapshot();
    expect(identical(first, second), isTrue);
    expect(first.map((m) => m.id), ['older', 'newer']);
    newer.setRedactionEvent(Event(
        room: room,
        type: EventTypes.Redaction,
        eventId: 'redaction',
        senderId: '@me:test',
        originServerTs: DateTime.utc(2026),
        content: {}));
    final redacted = adapter.snapshot();
    expect(redacted.last.isRecalled, isTrue);
    expect(identical(redacted.first, first.first), isTrue);
    timeline.events.insert(
        0,
        RetryEvent(room, timeline,
            id: 'append', minute: 3, status: EventStatus.synced));
    final appended = adapter.snapshot();
    expect(appended.map((m) => m.id), ['older', 'newer', 'append']);
    expect(identical(appended[1], redacted[1]), isTrue);
  });

  test('HTTP ack and sync expose different timestamp authority', () async {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    timeline.events.add(RetryEvent(room, timeline,
        id: 'ack', minute: 1, status: EventStatus.sent));
    final adapter = (await openAdapter(room, timeline));
    expect(adapter.snapshot().single.isSdkLocalEcho, isTrue);
    timeline.events[0] = RetryEvent(room, timeline,
        id: 'ack', minute: 2, status: EventStatus.synced);
    expect(adapter.snapshot().single.isSdkLocalEcho, isFalse);
  });
  test('announcement documents are not ordinary chat bubbles', () async {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    timeline.events.add(RetryEvent(room, timeline,
        id: 'announcement',
        minute: 1,
        payload: {
          'msgtype': 'com.changliao.group.announcement.document',
          'body': '群公告'
        }));
    expect((await openAdapter(room, timeline)).snapshot(), isEmpty);
  });

  test('upload failure reuses cached media and SDK send credentials', () async {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    final failed = RetryEvent(room, timeline,
        id: 'upload',
        minute: 1,
        payload: {'msgtype': 'm.video', 'body': 'fixture.mp4'});
    final extra = <String, dynamic>{
      'm.mentions': {
        'user_ids': ['@peer:test']
      }
    };
    failed.unsigned!
        .addAll(FileSendRequestCredentials(extraContent: extra).toJson());
    final file =
        MatrixFile(bytes: Uint8List.fromList([1, 2]), name: 'fixture.mp4');
    room.sendingFilePlaceholders[failed.eventId] = file;
    timeline.events.add(failed);
    await (await openAdapter(room, timeline)).retry(failed.eventId);
    expect(failed.cancellations, 1);
    expect(room.retryFile, same(file));
    expect(room.retryExtra, extra);
    expect(room.transactions, ['original-upload']);
  });

  test('unrecoverable upload retains failed bubble for user action', () async {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    final failed = RetryEvent(room, timeline,
        id: 'upload',
        minute: 1,
        payload: {'msgtype': 'm.video', 'body': 'fixture.mp4'});
    timeline.events.add(failed);
    await expectLater(
        (await openAdapter(room, timeline)).retry('upload'), throwsStateError);
    expect(failed.cancellations, 0);
    expect(timeline.events, [failed]);
  });

  test('failed events stay at original timestamp despite SDK status ordering',
      () async {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    timeline.events.addAll([
      RetryEvent(room, timeline, id: 'failed', minute: 1),
      RetryEvent(room, timeline,
          id: 'newer', minute: 3, status: EventStatus.sent),
      RetryEvent(room, timeline,
          id: 'older', minute: 0, status: EventStatus.sent),
    ]);
    expect((await openAdapter(room, timeline)).snapshot().map((e) => e.id),
        ['older', 'failed', 'newer']);
  });

  test(
      'retry removes failed entry, preserves complete payload and transaction, dedups taps',
      () async {
    final room = RetryRoom()..pending = Completer<String?>();
    final timeline = RetryTimeline();
    final payload = <String, dynamic>{
      'msgtype': 'm.video',
      'body': 'fixture.mp4',
      'file': {
        'url': 'mxc://test/video',
        'key': {'k': 'fixture-key'}
      },
      'info': {'duration': 1200},
      'm.relates_to': {
        'm.in_reply_to': {'event_id': r'$reply'}
      },
      'm.mentions': {
        'user_ids': ['@peer:test']
      },
    };
    final failed =
        RetryEvent(room, timeline, id: 'failed', minute: 1, payload: payload);
    timeline.events.add(failed);
    final adapter = (await openAdapter(room, timeline));
    final first = adapter.retry('failed');
    final second = adapter.retry('failed');
    await Future<void>.delayed(Duration.zero);
    expect(failed.cancellations, 1);
    expect(timeline.events, isEmpty);
    expect(room.sends, [payload]);
    expect(room.transactions, ['original-failed']);
    room.pending!.complete(r'$sent');
    await Future.wait([first, second]);
  });

  test('stale retry of acknowledged or missing event never sends', () async {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    timeline.events.add(RetryEvent(room, timeline,
        id: 'sent', minute: 1, status: EventStatus.sent));
    final adapter = (await openAdapter(room, timeline));
    await adapter.retry('sent');
    await adapter.retry('missing');
    expect(room.sends, isEmpty);
  });

  test('acknowledged transaction prevents stale failed echo from resending',
      () async {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    final failed = RetryEvent(room, timeline, id: 'failed', minute: 1);
    final sent = RetryEvent(room, timeline,
        id: r'$sent', minute: 1, status: EventStatus.sent);
    sent.unsigned!['transaction_id'] = failed.unsigned!['transaction_id'];
    timeline.events.addAll([failed, sent]);
    await (await openAdapter(room, timeline)).retry('failed');
    expect(room.sends, isEmpty);
    expect(failed.cancellations, 0);
  });
}
