import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/features/matrix/message_interaction_service.dart';

final class FakeMessageInteractionBackend implements MessageInteractionBackend {
  final sent = <({String roomId, Map<String, Object?> content})>[];
  final redactions = <({String roomId, String eventId, String reason})>[];
  final forwards =
      <({String sourceRoomId, String targetRoomId, String eventId})>[];

  @override
  Future<void> send(String roomId, Map<String, Object?> content) async {
    sent.add((roomId: roomId, content: content));
  }

  @override
  Future<void> redact(String roomId, String eventId, String reason) async {
    redactions.add((roomId: roomId, eventId: eventId, reason: reason));
  }

  @override
  Future<void> forwardEncryptedCopy(
    String sourceRoomId,
    String targetRoomId,
    String eventId,
  ) async {
    forwards.add((
      sourceRoomId: sourceRoomId,
      targetRoomId: targetRoomId,
      eventId: eventId,
    ));
  }
}

final class FakeHttpClient extends http.BaseClient {
  FakeHttpClient(this.response);
  final http.StreamedResponse response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response;
}

void main() {
  final now = DateTime.utc(2026, 8, 17, 12);
  late FakeMessageInteractionBackend backend;
  late MessageInteractionService service;

  setUp(() {
    backend = FakeMessageInteractionBackend();
    service = MessageInteractionService(
      backend: backend,
      roomId: '!source:example.test',
      currentUserId: '@alice:example.test',
    );
  });

  test('recall accepts 1:59 and sends exactly one Matrix redaction', () async {
    final event = MessageInteractionEvent(
      id: r'$mine',
      senderId: '@alice:example.test',
      originServerTs: now.subtract(const Duration(minutes: 1, seconds: 59)),
    );

    await service.recall(event, serverNow: now);

    expect(backend.redactions, hasLength(1));
    expect(backend.redactions.single.eventId, r'$mine');
  });

  test('recall rejects 2:01 and another sender', () async {
    final tooOld = MessageInteractionEvent(
      id: r'$old',
      senderId: '@alice:example.test',
      originServerTs: now.subtract(const Duration(minutes: 2, seconds: 1)),
    );
    final other = MessageInteractionEvent(
      id: r'$other',
      senderId: '@bob:example.test',
      originServerTs: now,
    );

    expect(() => service.recall(tooOld, serverNow: now), throwsStateError);
    expect(() => service.recall(other, serverNow: now), throwsStateError);
    expect(backend.redactions, isEmpty);
  });

  test('reply emits a Matrix reply relation', () async {
    await service.reply(r'$original', '收到');

    expect(backend.sent.single.content, {
      'msgtype': 'm.text',
      'body': '收到',
      'm.relates_to': {
        'm.in_reply_to': {'event_id': r'$original'},
      },
    });
  });

  test('reply preserves explicit mention ids', () async {
    await service.reply(
      r'$original',
      '收到 @小明',
      mentionedUserIds: const ['@ming:example.test'],
    );

    expect(backend.sent.single.content['m.mentions'], {
      'user_ids': ['@ming:example.test'],
    });
  });

  test('mentions use m.mentions user_ids without changing visible text',
      () async {
    await service.sendMention('你好 @小明', const ['@ming:example.test']);

    expect(backend.sent.single.content['body'], '你好 @小明');
    expect(backend.sent.single.content['m.mentions'], {
      'user_ids': ['@ming:example.test'],
    });
  });

  test('forward delegates a decrypt-and-reencrypt copy to target room',
      () async {
    await service.forward(r'$event', '!target:example.test');

    expect(backend.forwards.single, (
      sourceRoomId: '!source:example.test',
      targetRoomId: '!target:example.test',
      eventId: r'$event',
    ));
  });

  test('mention draft drops an id after its visible marker is edited away', () {
    final draft = MentionDraft();
    final text = draft.append('', displayName: '小明', userId: '@ming:test');

    expect(text, '@小明 ');
    expect(draft.activeUserIds('你好 @小明'), ['@ming:test']);
    expect(draft.activeUserIds('你好'), isEmpty);
  });

  test('avatar gestures fall back to Matrix member identity for non-friends',
      () {
    expect(
      resolveMessageSenderDisplayName(
        senderId: '@member:example.test',
        matrixDisplayName: '群成员',
      ),
      '群成员',
    );
    expect(
      resolveMessageSenderDisplayName(
        senderId: '@member:example.test',
        contactDisplayName: '好友备注',
        matrixDisplayName: '群成员',
      ),
      '好友备注',
    );
  });

  test('server clock reads authoritative HTTP Date from the homeserver',
      () async {
    final clock = MatrixServerClock(
      homeserver: Uri.parse('https://matrix.example.test'),
      httpClient: FakeHttpClient(
        http.StreamedResponse(
          const Stream<List<int>>.empty(),
          200,
          headers: {'date': 'Mon, 17 Aug 2026 12:00:00 GMT'},
        ),
      ),
    );

    expect(await clock.now(), DateTime.utc(2026, 8, 17, 12));
  });
}
