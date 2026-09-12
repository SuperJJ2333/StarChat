import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';

void main() {
  for (final oldReply in [_Reply.success, _Reply.error]) {
    test('late ${oldReply.name} sync cannot replace a newer active sync',
        () async {
      final transport = _HeldSyncTransport();
      final client = _clientFor(transport);
      final statuses = <SyncStatus>[];
      final subscription = client.onSyncStatus.stream
          .listen((update) => statuses.add(update.status));
      try {
        final first = client.oneShotSync();
        await transport.waitForRequests(1);
        expect(client.syncPending, isTrue);

        await client.abortSync();
        expect(client.syncPending, isFalse,
            reason: 'abort must settle before the replacement starts');

        final replacement = client.oneShotSync();
        await transport.waitForRequests(2);
        client.backgroundSync = true;
        statuses.clear();

        transport.requests[0].release(oldReply);
        await first;
        await _settle();

        expect(client.syncPending, isTrue,
            reason: 'the old completion must not clear the replacement future');
        expect(transport.requests, hasLength(2),
            reason: 'the old completion must not launch another sync loop');
        expect(statuses, isEmpty,
            reason: 'the old completion must not publish sync status');
        if (oldReply == _Reply.error) {
          expect(client.isLogged(), isTrue,
              reason:
                  'a stale unknown-token error cannot clear the new session');
        }

        client.backgroundSync = false;
        transport.requests[1].release(_Reply.success);
        await replacement;
        expect(client.syncPending, isFalse);
      } finally {
        await subscription.cancel();
        await client.dispose();
      }
    });
  }

  test('a disposed client ignores a late sync response', () async {
    final transport = _HeldSyncTransport();
    final client = _clientFor(transport);
    final statuses = <SyncStatus>[];
    final subscription = client.onSyncStatus.stream
        .listen((update) => statuses.add(update.status));
    try {
      final sync = client.oneShotSync();
      await transport.waitForRequests(1);
      await client.dispose();
      statuses.clear();

      transport.requests.single.release(_Reply.success);
      await sync;
      await _settle();

      expect(client.syncPending, isFalse);
      expect(transport.requests, hasLength(1));
      expect(statuses, isEmpty,
          reason: 'a disposed client must not publish a late success');
    } finally {
      await subscription.cancel();
      await client.dispose();
    }
  });

  test('an aborted loop waiting for retry cannot issue a stale sync request',
      () async {
    final transport = _HeldSyncTransport();
    final client = _clientFor(transport)..syncErrorTimeoutSec = 1;
    try {
      final failed = client.oneShotSync();
      await transport.waitForRequests(1);
      transport.requests.single.release(_Reply.transientError);
      await failed;

      final stale = client.oneShotSync();
      await _settle();
      await client.abortSync();
      final replacement = client.oneShotSync();
      await transport.waitForRequests(2);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(transport.requests, hasLength(2),
          reason: 'only the replacement may leave the shared retry delay');
      transport.requests[1].release(_Reply.success);
      await Future.wait([stale, replacement]);
    } finally {
      await client.dispose();
    }
  });
}

Client _clientFor(_HeldSyncTransport transport) => Client(
      'sync-recovery-fixture',
      httpClient: transport.client,
    )
      ..homeserver = Uri.parse('https://matrix.fixture.test')
      ..accessToken = 'fixture-token'
      ..backgroundSync = false
      ..syncErrorTimeoutSec = 0;

Future<void> _settle() => Future<void>.delayed(Duration.zero);

enum _Reply { success, error, transientError }

final class _HeldSyncTransport {
  _HeldSyncTransport() {
    client = MockClient(_handle);
  }

  late final http.Client client;
  final requests = <_HeldRequest>[];

  Future<http.Response> _handle(http.Request request) {
    if (!request.url.path.endsWith('/sync')) {
      return Future.value(http.Response('not found', 404));
    }
    final held = _HeldRequest();
    requests.add(held);
    return held.response.future;
  }

  Future<void> waitForRequests(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (requests.length < count) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
            'expected $count /sync requests, got ${requests.length}');
      }
      await _settle();
    }
  }
}

final class _HeldRequest {
  final response = Completer<http.Response>();

  void release(_Reply reply) => response.complete(http.Response(
        jsonEncode(reply == _Reply.success
            ? _successfulSync
            : reply == _Reply.error
                ? {
                    'errcode': 'M_UNKNOWN_TOKEN',
                    'error': 'late synthetic token error',
                  }
                : {
                    'errcode': 'M_UNKNOWN',
                    'error': 'synthetic retryable sync error',
                  }),
        reply == _Reply.success ? 200 : 400,
        headers: const {'content-type': 'application/json'},
      ));
}

const _successfulSync = <String, Object>{
  'next_batch': 'replacement-batch',
  'rooms': <String, Object>{},
  'presence': <String, Object>{'events': <Object>[]},
  'account_data': <String, Object>{'events': <Object>[]},
  'to_device': <String, Object>{'events': <Object>[]},
  'device_lists': <String, Object>{'changed': <Object>[], 'left': <Object>[]},
  'device_one_time_keys_count': <String, Object>{},
};
