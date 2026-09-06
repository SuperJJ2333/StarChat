import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/turn_credentials_cache.dart';

TurnServerCredentials credentials(String password, {int ttl = 60}) =>
    TurnServerCredentials(
        password: password,
        ttl: ttl,
        uris: ['turn:example.test:3478?transport=udp'],
        username: 'test-only');

void main() {
  test(
      'refreshes credentials before expiry instead of reusing SDK lifetime cache',
      () async {
    var now = DateTime.utc(2026);
    var requests = 0;
    final cache = TurnCredentialsCache(
        fetch: () async => credentials('credential-${++requests}'),
        now: () => now);
    expect((await cache.getIceServers()).single['credential'], 'credential-1');
    now = now.add(const Duration(seconds: 20));
    await cache.getIceServers();
    expect(requests, 1);
    now = now.add(const Duration(seconds: 40));
    expect((await cache.getIceServers()).single['credential'], 'credential-2');
  });

  test('prewarming and simultaneous calls share one request', () async {
    var requests = 0;
    final pending = Completer<TurnServerCredentials>();
    final cache = TurnCredentialsCache(fetch: () {
      requests++;
      return pending.future;
    });
    final warm = cache.getIceServers();
    final call = cache.getIceServers();
    pending.complete(credentials('ephemeral'));
    expect(await call, await warm);
    expect(requests, 1);
  });

  test('expired credentials are never reused when refresh fails', () async {
    var now = DateTime.utc(2026);
    var requests = 0;
    final cache = TurnCredentialsCache(
        now: () => now,
        fetch: () async {
          if (++requests > 1) throw StateError('offline');
          return credentials('expired');
        });
    await cache.getIceServers();
    now = now.add(const Duration(minutes: 2));
    expect(await cache.getIceServers(), isEmpty);
    expect(requests, 2);
  });

  testWidgets(
      'unresponsive discovery is bounded and late result does not poison next call',
      (tester) async {
    final pending = Completer<TurnServerCredentials>();
    var requests = 0;
    final cache = TurnCredentialsCache(
        timeout: const Duration(seconds: 3),
        fetch: () {
          if (++requests == 1) return pending.future;
          return Future.value(credentials('fresh'));
        });
    final first = cache.getIceServers();
    await tester.pump(const Duration(seconds: 3));
    expect(await first, isEmpty);
    expect((await cache.getIceServers()).single['credential'], 'fresh');
    pending.complete(credentials('late'));
    await tester.pump();
    expect((await cache.getIceServers()).single['credential'], 'fresh');
  });
}
