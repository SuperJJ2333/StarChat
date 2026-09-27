import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'account_credentials_client_test.dart' show MemoryStore;

const securityJson = '{"masked_email":"a***@example.test",'
    '"masked_phone":"138****0001","email_bound":true,"phone_bound":true,'
    '"email_verified":true,"phone_verified":true}';

Future<SecureSessionStore> signedInStore() async {
  final store = SecureSessionStore(MemoryStore());
  await store.saveSession(
      accessToken: 'old', refreshToken: 'old-r', matrixUserId: '@old:test');
  return store;
}

void main() {
  test('warm account security reads reuse the confirmed summary', () async {
    var reads = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          reads++;
          return http.Response(securityJson, 200);
        }));
    final first = await api.loadAccountSecurity();
    final second = await api.loadAccountSecurity();
    expect(second.maskedEmail, first.maskedEmail);
    expect(reads, 1);
  });

  test('concurrent account summary reads share one transport', () async {
    var reads = 0;
    final sent = Completer<void>();
    final response = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          reads++;
          if (!sent.isCompleted) sent.complete();
          return response.future;
        }));
    final first = api.loadAccountSecurity();
    final second = api.loadAccountSecurity();
    await sent.future;
    await Future<void>.delayed(Duration.zero);
    response.complete(http.Response(securityJson, 200));
    await Future.wait([first, second]);
    expect(reads, 1);
  });

  test('read-only account summary refreshes an expired access token', () async {
    var reads = 0, refreshes = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            refreshes++;
            return http.Response(
                '{"access_token":"refreshed","refresh_token":"fresh-r"}', 200);
          }
          reads++;
          if (request.headers['authorization'] == 'Bearer old') {
            return http.Response(
                '{"error":{"code":"ACCESS_TOKEN_EXPIRED","message":"expired"}}',
                401);
          }
          return http.Response(securityJson, 200);
        }));
    expect((await api.loadAccountSecurity()).canUseEmail, isTrue);
    expect(reads, 2);
    expect(refreshes, 1);
  });

  test('warm chat preference reads reuse the confirmed value', () async {
    var reads = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          reads++;
          return http.Response('{"auto_allow_group_join":false}', 200);
        }));
    expect(await api.autoAllowGroupJoin(), isFalse);
    expect(await api.autoAllowGroupJoin(), isFalse);
    expect(reads, 1);
  });

  test('chat preference read waits for an unresolved write', () async {
    var reads = 0;
    final sent = Completer<void>();
    final response = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          if (request.method == 'PUT') {
            sent.complete();
            return response.future;
          }
          reads++;
          return http.Response('{"auto_allow_group_join":true}', 200);
        }));
    final write = api.setAutoAllowGroupJoin(true);
    await sent.future;
    final read = api.autoAllowGroupJoin();
    await Future<void>.delayed(Duration.zero);
    final readsWhilePending = reads;
    response.complete(http.Response('{"auto_allow_group_join":true}', 200));
    await write;
    expect(await read, isTrue);
    expect(readsWhilePending, 0,
        reason: 'pending write must block authority reads');
  });

  test('five minute TTL keeps snapshots visible while expired reads refresh',
      () async {
    var now = DateTime.utc(2026, 9, 26);
    var securityReads = 0, chatReads = 0;
    final refresh = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        clock: () => now,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/account-security')) {
            securityReads++;
            return securityReads == 1
                ? http.Response(securityJson, 200)
                : refresh.future;
          }
          chatReads++;
          return http.Response('{"auto_allow_group_join":false}', 200);
        }));
    await api.loadAccountSecurity();
    await api.autoAllowGroupJoin();
    expect(api.cachedAccountSecurityData!.canUsePhone, isTrue);
    expect(api.cachedAutoAllowGroupJoin, isFalse);
    now = now.add(const Duration(minutes: 4, seconds: 59));
    expect(api.accountSecurityCacheIsFresh, isTrue);
    expect(api.autoAllowGroupJoinCacheIsFresh, isTrue);
    await api.loadAccountSecurity();
    await api.autoAllowGroupJoin();
    expect(securityReads, 1);
    expect(chatReads, 1);
    now = now.add(const Duration(seconds: 1));
    expect(api.accountSecurityCacheIsFresh, isFalse);
    expect(api.autoAllowGroupJoinCacheIsFresh, isFalse);
    final first = api.loadAccountSecurity();
    final second = api.loadAccountSecurity();
    await Future<void>.delayed(Duration.zero);
    expect(api.cachedAccountSecurityData!.canUsePhone, isTrue);
    expect(securityReads, 2);
    refresh.complete(http.Response(securityJson, 200));
    await Future.wait([first, second]);
    await api.autoAllowGroupJoin();
    expect(chatReads, 2);
    expect(api.accountSecurityCacheIsFresh, isTrue);
  });

  test('forced warm reads bypass cache and share their active refresh',
      () async {
    var reads = 0;
    final refresh = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          reads++;
          return reads == 1
              ? http.Response('{"auto_allow_group_join":false}', 200)
              : refresh.future;
        }));
    await api.autoAllowGroupJoin();
    final first = api.autoAllowGroupJoin(forceRefresh: true);
    final second = api.autoAllowGroupJoin(forceRefresh: true);
    await Future<void>.delayed(Duration.zero);
    expect(api.cachedAutoAllowGroupJoin, isFalse);
    expect(reads, 2);
    refresh.complete(http.Response('{"auto_allow_group_join":true}', 200));
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(api.cachedAutoAllowGroupJoin, isTrue);
    expect(await api.autoAllowGroupJoin(), isTrue);
    expect(reads, 2);
  });

  test('binding invalidation stays empty when authoritative refresh fails',
      () async {
    var reads = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          reads++;
          return reads == 1
              ? http.Response(securityJson, 200)
              : http.Response('{}', 503);
        }));
    await api.loadAccountSecurity();
    api.invalidateAccountSecurityCache();
    expect(api.cachedAccountSecurityData, isNull);
    await expectLater(api.loadAccountSecurity(forceRefresh: true),
        throwsA(isA<BusinessApiException>()));
    expect(api.cachedAccountSecurityData, isNull);
    expect(api.accountSecurityCacheIsFresh, isFalse);
  });

  test('invalidated in-flight binding summary cannot republish old eligibility',
      () async {
    final sent = Completer<void>();
    final response = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          sent.complete();
          return response.future;
        }));
    final read = api.loadAccountSecurity();
    final rejected = expectLater(read, throwsA(isA<StateError>()));
    await sent.future;
    api.invalidateAccountSecurityCache();
    response.complete(http.Response(securityJson, 200));
    await rejected;
    expect(api.cachedAccountSecurityData, isNull);
  });

  test('confirmed chat save cannot be overwritten by an older GET', () async {
    final sent = Completer<void>();
    final oldRead = Completer<http.Response>();
    var reads = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          if (request.method == 'PUT') {
            return http.Response('{"auto_allow_group_join":true}', 200);
          }
          reads++;
          sent.complete();
          return oldRead.future;
        }));
    final read = api.autoAllowGroupJoin();
    final rejected = expectLater(read, throwsA(isA<StateError>()));
    await sent.future;
    expect(await api.setAutoAllowGroupJoin(true), isTrue);
    oldRead.complete(http.Response('{"auto_allow_group_join":false}', 200));
    await rejected;
    expect(api.cachedAutoAllowGroupJoin, isTrue);
    expect(await api.autoAllowGroupJoin(), isTrue);
    expect(reads, 1);
  });

  test('trusted same-session refresh preserves both warm snapshots', () async {
    var reads = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            return http.Response(
                '{"access_token":"refreshed","refresh_token":"fresh-r"}', 200);
          }
          reads++;
          return request.url.path.endsWith('/account-security')
              ? http.Response(securityJson, 200)
              : http.Response('{"auto_allow_group_join":false}', 200);
        }));
    await api.loadAccountSecurity();
    await api.autoAllowGroupJoin();
    final epoch = api.sessionEpoch;
    await api.refreshSession();
    expect(api.sessionEpoch, epoch);
    expect(api.cachedAccountSecurityData, isNotNull);
    expect(api.cachedAutoAllowGroupJoin, isFalse);
    await api.loadAccountSecurity();
    await api.autoAllowGroupJoin();
    expect(reads, 2);
  });

  test('login and logout isolate snapshots and reject old-session GET results',
      () async {
    final oldRead = Completer<http.Response>();
    final sent = Completer<void>();
    var holdSummary = false;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/login')) {
            return http.Response(
                '{"access_token":"new","refresh_token":"new-r",'
                '"matrix_user_id":"@new:test"}',
                200);
          }
          if (request.url.path.endsWith('/account-security')) {
            if (holdSummary &&
                request.headers['authorization'] == 'Bearer old') {
              sent.complete();
              return oldRead.future;
            }
            return http.Response(securityJson, 200);
          }
          return http.Response('{"auto_allow_group_join":false}', 200);
        }));
    await api.loadAccountSecurity();
    await api.autoAllowGroupJoin();
    holdSummary = true;
    final read = api.loadAccountSecurity(forceRefresh: true);
    final rejected = expectLater(read, throwsA(isA<BusinessApiException>()));
    await sent.future;
    await api.login(
        username: 'new',
        password: 'new-password-123',
        deviceKey: 'new-device',
        deviceName: 'test');
    expect(api.cachedAccountSecurityData, isNull);
    expect(api.cachedAutoAllowGroupJoin, isNull);
    await api.loadAccountSecurity();
    await api.autoAllowGroupJoin();
    oldRead.complete(http.Response(securityJson, 200));
    await rejected;
    expect(api.cachedAccountSecurityData, isNotNull);
    expect(api.cachedAutoAllowGroupJoin, isFalse);
    await api.clearLocalSession();
    expect(api.cachedAccountSecurityData, isNull);
    expect(api.cachedAutoAllowGroupJoin, isNull);
  });

  for (final channel in ['email', 'phone']) {
    test('$channel binding confirmation invalidates even on an unknown outcome',
        () async {
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://api.test'),
          sessionStore: await signedInStore(),
          client: MockClient((request) async => request.method == 'GET'
              ? http.Response(securityJson, 200)
              : http.Response('{}', 503)));
      await api.loadAccountSecurity();
      final confirm = channel == 'email'
          ? api.confirmEmailRebind(email: 'new@example.test', code: '123456')
          : api.rebindNewConfirm(phone: '13800000002', code: '123456');
      await expectLater(confirm, throwsA(isA<BusinessApiException>()));
      expect(api.cachedAccountSecurityData, isNull);
    });
  }

  test('account security never requests an anonymous display summary',
      () async {
    var requests = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: SecureSessionStore(MemoryStore()),
        client: MockClient((request) async {
          requests++;
          return http.Response(securityJson, 200);
        }));
    await expectLater(
        api.loadAccountSecurity(), throwsA(isA<BusinessApiException>()));
    expect(requests, 0);
    expect(api.cachedAccountSecurityData, isNull);
  });

  test('chat read keeps waiting if another write starts during settlement',
      () async {
    var writes = 0, reads = 0;
    final firstSent = Completer<void>(), secondSent = Completer<void>();
    final firstResponse = Completer<http.Response>();
    final secondResponse = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: await signedInStore(),
        client: MockClient((request) async {
          if (request.method == 'PUT') {
            writes++;
            if (writes == 1) {
              firstSent.complete();
              return firstResponse.future;
            }
            secondSent.complete();
            return secondResponse.future;
          }
          reads++;
          return http.Response('{"auto_allow_group_join":false}', 200);
        }));
    final firstWrite = api.setAutoAllowGroupJoin(true);
    await firstSent.future;
    // This listener starts a second legitimate write before the reader's
    // continuation resumes from the first settlement.
    final secondWrite = api
        .waitForAutoAllowGroupJoinWrite()
        .then((_) => api.setAutoAllowGroupJoin(false));
    final read = api.autoAllowGroupJoin();
    firstResponse
        .complete(http.Response('{"auto_allow_group_join":true}', 200));
    await secondSent.future;
    await Future<void>.delayed(Duration.zero);
    final readsDuringSecondWrite = reads;
    secondResponse
        .complete(http.Response('{"auto_allow_group_join":false}', 200));
    await Future.wait([firstWrite, secondWrite]);
    expect(await read, isFalse);
    expect(readsDuringSecondWrite, 0);
    expect(reads, 1);
  });
}
