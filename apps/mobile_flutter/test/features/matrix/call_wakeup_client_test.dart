import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/call_wakeup_client.dart';

void main() {
  test(
      'failed claim never calls media answer, explicit legacy missing record may',
      () async {
    var status = 503;
    var answered = 0;
    final client = CallWakeupClient(
        baseUrl: Uri.parse('https://example.test/ios-call/'),
        accessToken: () => 'session',
        httpClient: MockClient((_) async => http.Response('{}', status)));
    await expectLater(
        client.answerAndConnect(
            roomId: '!r:h',
            callId: 'c',
            isCurrent: () => true,
            connect: () async {
              answered++;
            }),
        throwsStateError);
    expect(answered, 0);
    status = 404;
    await client.answerAndConnect(
        roomId: '!r:h',
        callId: 'c',
        isCurrent: () => true,
        connect: () async {
          answered++;
        });
    expect(answered, 1);
  });
  test('old client retains its original credential when session getter changes',
      () async {
    String? token = 'old-session';
    final auth = <String?>[];
    final client = CallWakeupClient(
        baseUrl: Uri.parse('https://example.test/ios-call/'),
        accessToken: () => token,
        httpClient: MockClient((r) async {
          auth.add(r.headers['authorization']);
          return http.Response('{}', 200);
        }));
    token = 'new-session';
    await client.unregister();
    expect(auth, ['Bearer old-session']);
  });
  test('wake uses Matrix identity and only opaque call metadata', () async {
    late http.Request sent;
    final client = CallWakeupClient(
      baseUrl: Uri.parse('https://example.test/ios-call/'),
      accessToken: () => 'test-session',
      httpClient: MockClient((req) async {
        sent = req;
        return http.Response('{}', 200);
      }),
    );
    await client.invite(
        roomId: '!r:h', callId: 'c', recipient: '@b:h', video: false);
    expect(sent.url.path, '/ios-call/v1/calls');
    expect(sent.headers['authorization'], 'Bearer test-session');
    expect(jsonDecode(sent.body), {
      'room_id': '!r:h',
      'call_id': 'c',
      'recipient': '@b:h',
      'video': false
    });
  });
  test('missing session never sends a request; no authentication bypass',
      () async {
    var requests = 0;
    final client = CallWakeupClient(
      baseUrl: Uri.parse('https://example.test/ios-call/'),
      accessToken: () => null,
      httpClient: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    expect(await client.register({'voipToken': 'a' * 64}), false);
    expect(requests, 0);
  });
  test('invalid tokens are not sent and identical registrations are coalesced',
      () async {
    var requests = 0;
    final client = CallWakeupClient(
      baseUrl: Uri.parse('https://example.test/ios-call/'),
      accessToken: () => 'session',
      httpClient: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    expect(await client.register({'voipToken': 'invalid'}), false);
    await client.register({'voipToken': 'a' * 64, 'apnsToken': 'b' * 64});
    await client.register({'voipToken': 'a' * 64, 'apnsToken': 'b' * 64});
    expect(requests, 1);
    await client.unregister();
    expect(requests, 2);
  });
  test('gateway error stays observable as false without exposing its response',
      () async {
    final client = CallWakeupClient(
      baseUrl: Uri.parse('https://example.test/ios-call/'),
      accessToken: () => 'session',
      httpClient:
          MockClient((_) async => http.Response('private response', 503)),
    );
    expect(
        await client.invite(
            roomId: '!r:h', callId: 'c', recipient: '@b:h', video: true),
        false);
  });
  test(
      'answer conflict is distinguishable from an older client without a wake record',
      () async {
    var status = 409;
    final client = CallWakeupClient(
        baseUrl: Uri.parse('https://example.test/ios-call/'),
        accessToken: () => 'session',
        httpClient: MockClient((_) async => http.Response('{}', status)));
    expect(await client.answer(roomId: '!r:h', callId: 'c'),
        CallAnswerDisposition.alreadyEnded);
    status = 404;
    expect(await client.answer(roomId: '!r:h', callId: 'c'),
        CallAnswerDisposition.noWakeRecord);
  });
  test('cancel waits for invite admission to avoid a late ringing orphan',
      () async {
    final admitted = Completer<http.Response>();
    final paths = <String>[];
    final client = CallWakeupClient(
        baseUrl: Uri.parse('https://example.test/ios-call/'),
        accessToken: () => 'session',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/calls')) return admitted.future;
          return http.Response('{}', 200);
        }));
    final invite = client.invite(
        roomId: '!r:h', callId: 'c', recipient: '@b:h', video: false);
    await Future<void>.delayed(Duration.zero);
    final end = client.end(roomId: '!r:h', callId: 'c');
    await Future<void>.delayed(Duration.zero);
    expect(paths, ['/ios-call/v1/calls']);
    admitted.complete(http.Response('{}', 200));
    await invite;
    await end;
    expect(paths.last, '/ios-call/v1/calls/end');
  });
}
