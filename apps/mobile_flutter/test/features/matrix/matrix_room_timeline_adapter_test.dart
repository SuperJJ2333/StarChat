import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/file_send_request_credentials.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';

class RetryTimeline extends Fake implements Timeline {
  @override
  final events = <Event>[];
}

class RetryRoom extends Room {
  RetryRoom() : super(id: '!retry:test', client: Client('retry-test'));
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
  test('announcement documents are not ordinary chat bubbles', () {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    timeline.events.add(RetryEvent(room, timeline,
        id: 'announcement',
        minute: 1,
        payload: {
          'msgtype': 'com.changliao.group.announcement.document',
          'body': '群公告'
        }));
    expect(MatrixRoomTimelineAdapter(room, timeline).snapshot(), isEmpty);
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
    await MatrixRoomTimelineAdapter(room, timeline).retry(failed.eventId);
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
    await expectLater(MatrixRoomTimelineAdapter(room, timeline).retry('upload'),
        throwsStateError);
    expect(failed.cancellations, 0);
    expect(timeline.events, [failed]);
  });

  test('failed events stay at original timestamp despite SDK status ordering',
      () {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    timeline.events.addAll([
      RetryEvent(room, timeline, id: 'failed', minute: 1),
      RetryEvent(room, timeline,
          id: 'newer', minute: 3, status: EventStatus.sent),
      RetryEvent(room, timeline,
          id: 'older', minute: 0, status: EventStatus.sent),
    ]);
    expect(
        MatrixRoomTimelineAdapter(room, timeline).snapshot().map((e) => e.id),
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
    final adapter = MatrixRoomTimelineAdapter(room, timeline);
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
    final adapter = MatrixRoomTimelineAdapter(room, timeline);
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
    await MatrixRoomTimelineAdapter(room, timeline).retry('failed');
    expect(room.sends, isEmpty);
    expect(failed.cancellations, 0);
  });
}
