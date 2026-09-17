import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/call_wakeup_client.dart';

/// Task G：wakeup HTTP 只负责 push 唤醒/跨进程 tombstone 协调，
/// **绝不**成为正常前台 WebRTC media setup 的同步前置条件。
void main() {
  test('accept after an 8s wakeup HTTP delay still answers locally first',
      () async {
    final claim = Completer<http.Response>();
    final events = <String>[];
    final client = CallWakeupClient(
      baseUrl: Uri.parse('https://example.test/ios-call/'),
      accessToken: () => 'session',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/calls/answer')) {
          events.add('http-answer-started');
          return claim.future;
        }
        return http.Response('{}', 200);
      }),
    );

    final pending = client.answerAndConnect(
      roomId: '!r:h',
      callId: 'c',
      isCurrent: () => true,
      connect: () async {
        events.add('media-answer');
      },
    );

    // The media answer completes while the HTTP call is still outstanding:
    // this is the assertion that matters, because it proves the answer did not
    // wait on the wakeup service at all.
    await pending.timeout(const Duration(seconds: 2));
    expect(events, contains('media-answer'));
    expect(claim.isCompleted, isFalse, reason: 'HTTP 仍在等待时 media 已经接听');
    // The side channel is fire-and-forget, so let it reach the socket.
    await Future<void>.delayed(Duration.zero);
    expect(events, contains('http-answer-started'),
        reason: 'wakeup HTTP 必须与 media answer 并行发出');

    claim.complete(http.Response('{}', 200));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('wakeup HTTP unavailable does not block an active Matrix session',
      () async {
    var answered = 0;
    final client = CallWakeupClient(
      baseUrl: Uri.parse('https://example.test/ios-call/'),
      accessToken: () => 'session',
      httpClient: MockClient((_) async => http.Response('{}', 503)),
    );
    await client.answerAndConnect(
      roomId: '!r:h',
      callId: 'c',
      isCurrent: () => true,
      connect: () async {
        answered++;
      },
    );
    expect(answered, 1, reason: 'wakeup 服务不可用不得阻断已校验的 Matrix 会话接听');
  });

  test('wakeup HTTP timeout does not block the answer', () async {
    var answered = 0;
    final client = CallWakeupClient(
      baseUrl: Uri.parse('https://example.test/ios-call/'),
      accessToken: () => 'session',
      httpClient: MockClient((_) => Completer<http.Response>().future),
    );
    await client
        .answerAndConnect(
          roomId: '!r:h',
          callId: 'c',
          isCurrent: () => true,
          connect: () async {
            answered++;
          },
        )
        .timeout(const Duration(seconds: 2));
    expect(answered, 1);
  });

  test('a vanished call session never answers media', () async {
    var answered = 0;
    final client = CallWakeupClient(
      baseUrl: Uri.parse('https://example.test/ios-call/'),
      accessToken: () => 'session',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    await client.answerAndConnect(
      roomId: '!r:h',
      callId: 'c',
      isCurrent: () => false,
      connect: () async {
        answered++;
      },
    );
    expect(answered, 0, reason: 'native action 必须与当前会话精确匹配');
  });

  test('legacy client without a wake record still answers', () async {
    var answered = 0;
    final client = CallWakeupClient(
      baseUrl: Uri.parse('https://example.test/ios-call/'),
      accessToken: () => 'session',
      httpClient: MockClient((_) async => http.Response('{}', 404)),
    );
    await client.answerAndConnect(
      roomId: '!r:h',
      callId: 'c',
      isCurrent: () => true,
      connect: () async {
        answered++;
      },
    );
    expect(answered, 1);
  });

  group('alreadyEnded tombstone 精确匹配', () {
    test('matching old call is ended; the callback sees the exact ids',
        () async {
      final ended = <String>[];
      final client = CallWakeupClient(
        baseUrl: Uri.parse('https://example.test/ios-call/'),
        accessToken: () => 'session',
        httpClient: MockClient((_) async => http.Response('{}', 409)),
      )..onExplicitlyEnded =
            ({required String roomId, required String callId}) async {
          ended.add('$roomId|$callId');
        };
      await client.answerAndConnect(
        roomId: '!r:h',
        callId: 'old',
        isCurrent: () => true,
        connect: () async {},
      );
      // The tombstone arrives after the media answer already started.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ended, ['!r:h|old'], reason: '显式 tombstone 只允许结束完全匹配的旧 callId');
    });

    test('a late old-call HTTP reply cannot end a newer live call', () async {
      final claims = <String, Completer<http.Response>>{};
      final ended = <String>[];
      final client = CallWakeupClient(
        baseUrl: Uri.parse('https://example.test/ios-call/'),
        accessToken: () => 'session',
        httpClient: MockClient((request) {
          if (request.url.path.endsWith('/calls/answer')) {
            // Each answer request resolves on its own, keyed by call_id.
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return claims
                .putIfAbsent(
                    body['call_id'] as String, () => Completer<http.Response>())
                .future;
          }
          return Future.value(http.Response('{}', 200));
        }),
      )..onExplicitlyEnded =
            ({required String roomId, required String callId}) async {
          ended.add('$roomId|$callId');
        };

      await client.answerAndConnect(
        roomId: '!r:h',
        callId: 'old',
        isCurrent: () => true,
        connect: () async {},
      );
      // The new call answers while the old call's HTTP request is still pending.
      await client.answerAndConnect(
        roomId: '!r:h',
        callId: 'new',
        isCurrent: () => true,
        connect: () async {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(claims.keys, containsAll(['old', 'new']));

      // The OLD request finally returns an explicit tombstone. The combinator
      // must route it to the caller's exact-match check for 'old' only.
      claims['old']!.complete(http.Response('{}', 409));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ended, ['!r:h|old'],
          reason: '晚到的旧 callId tombstone 只允许结束旧的 callId');

      // The new call is untouched and its own reply is honoured separately.
      claims['new']!.complete(http.Response('{}', 200));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ended, ['!r:h|old'], reason: 'accepted 的新通话不得被旧 tombstone 结束');
    });

    test('a matching tombstone carried by the same call id is never reused',
        () async {
      final ended = <String>[];
      final client = CallWakeupClient(
        baseUrl: Uri.parse('https://example.test/ios-call/'),
        accessToken: () => 'session',
        httpClient: MockClient((_) async => http.Response('{}', 409)),
      )..onExplicitlyEnded =
            ({required String roomId, required String callId}) async {
          ended.add('$roomId|$callId');
        };
      await client.answerAndConnect(
        roomId: '!r:h',
        callId: 'a',
        isCurrent: () => true,
        connect: () async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // A brand new call with a different id is answered later; the earlier
      // tombstone must not have been cached and replayed onto it.
      await client.answerAndConnect(
        roomId: '!r:h',
        callId: 'b',
        isCurrent: () => true,
        connect: () async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ended, ['!r:h|a', '!r:h|b'], reason: '两通不同的通话各自只结束自己的 callId');
    });

    test('a failed side channel never disturbs the live call', () async {
      var answered = 0;
      var ended = 0;
      final client = CallWakeupClient(
        baseUrl: Uri.parse('https://example.test/ios-call/'),
        accessToken: () => 'session',
        httpClient: MockClient((_) async => throw StateError('socket closed')),
      )..onExplicitlyEnded =
            ({required String roomId, required String callId}) async {
          ended++;
        };
      await client.answerAndConnect(
        roomId: '!r:h',
        callId: 'c',
        isCurrent: () => true,
        connect: () async {
          answered++;
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(answered, 1);
      expect(ended, 0);
    });

    test('the answer request still carries only opaque call metadata',
        () async {
      String? body;
      final client = CallWakeupClient(
        baseUrl: Uri.parse('https://example.test/ios-call/'),
        accessToken: () => 'session',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/calls/answer')) body = request.body;
          return http.Response('{}', 200);
        }),
      );
      await client.answerAndConnect(
        roomId: '!r:h',
        callId: 'c',
        isCurrent: () => true,
        connect: () async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(jsonDecode(body!), {'room_id': '!r:h', 'call_id': 'c'});
      for (final forbidden in [
        'sdp',
        'candidate',
        'key',
        'body',
        'plaintext'
      ]) {
        expect(body!, isNot(contains(forbidden)));
      }
    });
  });
}
