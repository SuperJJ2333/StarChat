import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';

void main() {
  Timeline fragmentedTimeline({required String prevBatch, String? roomToken}) {
    final client = Client('fragment-history-fixture');
    final room = Room(id: '!fragment:synthetic', client: client)
      ..prev_batch = roomToken;
    return Timeline(
      room: room,
      chunk: TimelineChunk(
        prevBatch: prevBatch,
        events: [
          Event.fromJson({
            'event_id': r'$fragment-event',
            'type': EventTypes.Message,
            'sender': '@sender:synthetic',
            'origin_server_ts': 1,
            'content': {'msgtype': 'm.text', 'body': 'synthetic'},
          }, room),
        ],
      ),
    )..isFragmentedTimeline = true;
  }

  Map<String, dynamic> event(String id, String body) => {
        'event_id': id,
        'type': EventTypes.Message,
        'sender': '@sender:synthetic',
        'origin_server_ts': 1,
        'content': {'msgtype': 'm.text', 'body': body},
      };

  test('fragment history availability uses its own backward token', () async {
    final exhausted = fragmentedTimeline(prevBatch: '', roomToken: 'live-old');
    final available = fragmentedTimeline(prevBatch: 'context-old');
    expect(exhausted.canRequestHistory, isFalse);
    expect(available.canRequestHistory, isTrue);
    await exhausted.room.client.dispose();
    await available.room.client.dispose();
  });

  test('real context at the latest tail remains a fragmented timeline',
      () async {
    final client =
        Client('context-tail', httpClient: MockClient((request) async {
      expect(request.url.path, contains('/context/'));
      return http.Response(
          r'{"start":"context-prev","event":{"event_id":"$anchor","type":"m.room.message","sender":"@sender:synthetic","origin_server_ts":1,"content":{"msgtype":"m.text","body":"anchor"}},"events_before":[],"events_after":[]}',
          200);
    }))
          ..homeserver = Uri.parse('https://matrix.fixture.test')
          ..accessToken = 'fixture-token';
    final room = Room(id: '!fragment:synthetic', client: client)
      ..prev_batch = 'live-old';
    try {
      final timeline = await room.getTimeline(eventContextId: r'$anchor');
      expect(timeline.isFragmentedTimeline, isTrue);
      expect(timeline.allowNewEvent, isFalse);
      expect(timeline.canRequestHistory, isTrue);
      expect(timeline.canRequestFuture, isFalse,
          reason: 'an empty context end token must not request from the head');
      timeline.cancelSubscriptions();
    } finally {
      await client.dispose();
    }
  });

  test('a failed forward request clears the retry flag for the next request',
      () async {
    var requests = 0;
    final client = Client(
      'fragment-forward-retry',
      httpClient: MockClient((_) async {
        requests++;
        if (requests == 1) return http.Response('{"errcode":"M_UNKNOWN"}', 503);
        return http.Response(
            '{"start":"context-next","end":"","chunk":[]}', 200);
      }),
    )
      ..homeserver = Uri.parse('https://matrix.fixture.test')
      ..accessToken = 'fixture-token';
    final room = Room(id: '!fragment:synthetic', client: client);
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(
        prevBatch: 'context-prev',
        nextBatch: 'context-next',
        events: [Event.fromJson(event(r'$fragment-event', 'loaded'), room)],
      ),
    );
    try {
      await expectLater(timeline.requestFuture(), throwsA(isA<Exception>()));
      expect(timeline.isRequestingFuture, isFalse);
      await timeline.requestFuture();
      expect(requests, 2);
    } finally {
      timeline.cancelSubscriptions();
      await client.dispose();
    }
  });

  test('a context with no forward token does not request the room head',
      () async {
    var requests = 0;
    final client = Client('fragment-empty-forward',
        httpClient: MockClient((request) async {
      requests++;
      return http.Response('{}', 500);
    }))
      ..homeserver = Uri.parse('https://matrix.fixture.test')
      ..accessToken = 'fixture-token';
    final room = Room(id: '!fragment:synthetic', client: client);
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(
        prevBatch: 'context-prev',
        nextBatch: '',
        events: [Event.fromJson(event(r'$fragment-event', 'loaded'), room)],
      ),
    )
      ..isFragmentedTimeline = true
      ..allowNewEvent = false;
    try {
      expect(timeline.canRequestFuture, isFalse);
      await timeline.requestFuture();
      expect(requests, 0);
    } finally {
      timeline.cancelSubscriptions();
      await client.dispose();
    }
  });

  test(
      'forward page keeps redacted duplicates suppressed and advances its token',
      () async {
    final client = Client('fragment-forward-dedup',
        httpClient: MockClient((request) async {
      expect(request.url.queryParameters['dir'], 'f');
      expect(request.url.queryParameters['from'], 'context-next');
      return http.Response(
          r'{"start":"context-next-2","end":"","chunk":['
                  .replaceAll(r'\"', '"') +
              r'{"event_id":"$fragment-event","type":"m.room.message","sender":"@sender:synthetic","origin_server_ts":1,"content":{"msgtype":"m.text","body":"late original"},"unsigned":{"redacted_because":{"event_id":"$redaction","type":"m.room.redaction","sender":"@sender:synthetic","origin_server_ts":2,"content":{}}}},'
                  .replaceAll(r'\"', '"') +
              r'{"event_id":"$future","type":"m.room.message","sender":"@sender:synthetic","origin_server_ts":2,"content":{"msgtype":"m.text","body":"future"}}]}'
                  .replaceAll(r'\"', '"'),
          200);
    }))
      ..homeserver = Uri.parse('https://matrix.fixture.test')
      ..accessToken = 'fixture-token';
    final room = Room(id: '!fragment:synthetic', client: client);
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(
        prevBatch: 'context-prev',
        nextBatch: 'context-next',
        events: [Event.fromJson(event(r'$fragment-event', 'loaded'), room)],
        isFragment: true,
      ),
    );
    try {
      await timeline.requestFuture();
      expect(timeline.chunk.nextBatch, '');
      expect(timeline.events.where((e) => e.eventId == r'$fragment-event'),
          hasLength(1));
      expect(
          timeline.events
              .singleWhere((e) => e.eventId == r'$fragment-event')
              .redacted,
          isTrue);
      expect(
          timeline.events
              .singleWhere((e) => e.eventId == r'$fragment-event')
              .body,
          isNot('loaded'),
          reason: 'a paging redaction must clear the already decrypted body');
      expect(
          timeline.events
              .singleWhere((e) => e.eventId == r'$fragment-event')
              .content['body'],
          isNot('loaded'),
          reason: 'raw event content must not retain redacted plaintext');
      expect(
          timeline.events.where((e) => e.eventId == r'$future'), hasLength(1));
    } finally {
      timeline.cancelSubscriptions();
      await client.dispose();
    }
  });

  test('backward page uses previous token and preserves next token', () async {
    final client = Client('fragment-backward-token',
        httpClient: MockClient((request) async {
      expect(request.url.queryParameters['dir'], 'b');
      expect(request.url.queryParameters['from'], 'context-prev');
      return http.Response(
          '{"start":"context-prev","end":"older","chunk":[]}', 200);
    }))
      ..homeserver = Uri.parse('https://matrix.fixture.test')
      ..accessToken = 'fixture-token';
    final room = Room(id: '!fragment:synthetic', client: client);
    final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(
            prevBatch: 'context-prev',
            nextBatch: 'context-next',
            events: [],
            isFragment: true));
    try {
      await timeline.requestHistory();
      expect(timeline.chunk.prevBatch, 'older');
      expect(timeline.chunk.nextBatch, 'context-next');
    } finally {
      timeline.cancelSubscriptions();
      await client.dispose();
    }
  });

  test('same-page duplicate redaction never reports a detached change index',
      () async {
    final changed = <int>[];
    final client = Client('fragment-page-duplicate-redaction',
        httpClient: MockClient((_) async {
      return http.Response(
          r'{"start":"context-next-2","end":"","chunk":['
                  .replaceAll(r'\"', '"') +
              r'{"event_id":"$page-duplicate","type":"m.room.message","sender":"@sender:synthetic","origin_server_ts":1,"content":{"msgtype":"m.text","body":"original"}},'
                  .replaceAll(r'\"', '"') +
              r'{"event_id":"$page-duplicate","type":"m.room.message","sender":"@sender:synthetic","origin_server_ts":1,"content":{"msgtype":"m.text","body":"original"},"unsigned":{"redacted_because":{"event_id":"$redaction","type":"m.room.redaction","sender":"@sender:synthetic","origin_server_ts":2,"content":{}}}}]}'
                  .replaceAll(r'\"', '"'),
          200);
    }))
      ..homeserver = Uri.parse('https://matrix.fixture.test')
      ..accessToken = 'fixture-token';
    final room = Room(id: '!fragment:synthetic', client: client);
    final timeline = Timeline(
      room: room,
      onChange: changed.add,
      chunk: TimelineChunk(
          prevBatch: 'context-prev', nextBatch: 'context-next', events: []),
    );
    try {
      await timeline.requestFuture();
      expect(changed, isNot(contains(-1)));
      expect(timeline.events.single.redacted, isTrue);
      expect(timeline.events.single.body, isNot('original'));
    } finally {
      timeline.cancelSubscriptions();
      await client.dispose();
    }
  });

  test(
      'a forward request is deferred while a backward request owns timeline updates',
      () async {
    final backwardReply = Completer<http.Response>();
    var requests = 0;
    final client = Client(
      'fragment-direction-flags',
      httpClient: MockClient((_) async {
        requests++;
        if (requests == 1) return backwardReply.future;
        return http.Response(
            '{"start":"context-next","end":"","chunk":[]}', 200);
      }),
    )
      ..homeserver = Uri.parse('https://matrix.fixture.test')
      ..accessToken = 'fixture-token';
    final room = Room(id: '!fragment:synthetic', client: client);
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(
        prevBatch: 'context-prev',
        nextBatch: 'context-next',
        events: [Event.fromJson(event(r'$fragment-event', 'loaded'), room)],
      ),
    );
    try {
      final backward = timeline.requestHistory();
      while (requests == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(timeline.isRequestingHistory, isTrue);

      await timeline.requestFuture();
      expect(timeline.isRequestingHistory, isTrue);
      expect(requests, 1,
          reason: 'both directions share one history-update collector');

      backwardReply.complete(
          http.Response('{"start":"context-prev","end":"","chunk":[]}', 200));
      await backward;
      expect(timeline.isRequestingHistory, isFalse);
      await timeline.requestFuture();
      expect(requests, 2,
          reason:
              'a later caller can explicitly retry after the owner finishes');
    } finally {
      timeline.cancelSubscriptions();
      await client.dispose();
    }
  });

  test('limited live sync keeps a disconnected history fragment intact',
      () async {
    final timeline = fragmentedTimeline(prevBatch: 'context-prev');
    timeline.chunk.nextBatch = 'context-next';
    timeline.allowNewEvent = false;
    try {
      timeline.room.client.onSync.add(SyncUpdate(
        nextBatch: 'live-next',
        rooms: RoomsUpdate(
          join: {
            timeline.room.id: JoinedRoomUpdate(
              timeline: TimelineUpdate(limited: true),
            ),
          },
        ),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(timeline.events.single.eventId, r'$fragment-event');
    } finally {
      timeline.cancelSubscriptions();
      await timeline.room.client.dispose();
    }
  });

  test('a loaded fragment accepts updates but blocks unrelated live appends',
      () async {
    final timeline = fragmentedTimeline(prevBatch: 'context-prev');
    timeline.chunk.nextBatch = 'context-next';
    timeline.allowNewEvent = false;
    try {
      timeline.room.client.onEvent.add(EventUpdate(
        roomID: timeline.room.id,
        type: EventUpdateType.timeline,
        content: event(r'$fragment-event', 'updated'),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(timeline.events.single.body, 'updated');

      timeline.room.client.onEvent.add(EventUpdate(
        roomID: timeline.room.id,
        type: EventUpdateType.timeline,
        content: {
          'event_id': r'$recall',
          'type': EventTypes.Redaction,
          'sender': '@sender:synthetic',
          'origin_server_ts': 2,
          'content': {'redacts': r'$fragment-event'},
        },
      ));
      await Future<void>.delayed(Duration.zero);
      expect(
          timeline.events
              .singleWhere((item) => item.eventId == r'$fragment-event')
              .redacted,
          isTrue);

      timeline.room.client.onEvent.add(EventUpdate(
        roomID: timeline.room.id,
        type: EventUpdateType.timeline,
        content: event(r'$unrelated-live', 'must stay outside the fragment'),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(
          timeline.events.where((item) => item.eventId == r'$unrelated-live'),
          isEmpty);
    } finally {
      timeline.cancelSubscriptions();
      await timeline.room.client.dispose();
    }
  });

  test('a fragment redacts a loaded event without inserting the redaction',
      () async {
    final timeline = fragmentedTimeline(prevBatch: 'context-prev');
    timeline.chunk.nextBatch = 'context-next';
    timeline.allowNewEvent = false;
    try {
      timeline.room.client.onEvent.add(EventUpdate(
        roomID: timeline.room.id,
        type: EventUpdateType.timeline,
        content: {
          'event_id': r'$recall-only',
          'type': EventTypes.Redaction,
          'sender': '@sender:synthetic',
          'origin_server_ts': 2,
          'content': {'redacts': r'$fragment-event'},
        },
      ));
      await Future<void>.delayed(Duration.zero);
      expect(timeline.events.map((item) => item.eventId), [r'$fragment-event']);
      expect(timeline.events.single.redacted, isTrue);

      timeline.room.client.onEvent.add(EventUpdate(
        roomID: timeline.room.id,
        type: EventUpdateType.history,
        content: event(r'$fragment-event', 'stale history replay'),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(timeline.events.single.redacted, isTrue);
    } finally {
      timeline.cancelSubscriptions();
      await timeline.room.client.dispose();
    }
  });

  test('a non-redaction event cannot use redacts to enter a fragment',
      () async {
    final timeline = fragmentedTimeline(prevBatch: 'context-prev');
    timeline.chunk.nextBatch = 'context-next';
    timeline.allowNewEvent = false;
    try {
      final malformed = event(r'$not-a-redaction', 'must stay outside')
        ..['content'] = {
          'msgtype': 'm.text',
          'body': 'must stay outside',
          'redacts': r'$fragment-event',
        };
      timeline.room.client.onEvent.add(EventUpdate(
        roomID: timeline.room.id,
        type: EventUpdateType.timeline,
        content: malformed,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(timeline.events.map((item) => item.eventId), [r'$fragment-event']);
    } finally {
      timeline.cancelSubscriptions();
      await timeline.room.client.dispose();
    }
  });
}
