import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import '../friendship/friend_acceptance_coordinator_test.dart'
    show MemoryProfileStore;
import '../wallet/manual_wallet_api_test.dart' as fixtures;

Future<SecureSessionStore> _currentSession(
    {String matrixUserId = '@me:test'}) async {
  final session = SecureSessionStore(fixtures.MemoryStore());
  await session.saveSession(
      accessToken: 'e30.eyJzdWIiOiJtZSJ9.test',
      refreshToken: 'refresh',
      matrixUserId: matrixUserId);
  return session;
}

void main() {
  for (final stillFriends in [true, false]) {
    testWidgets(
        'accepted request reopens after restart only for a current friend ($stillFriends)',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      var writes = 0;
      var opened = 0;
      final request = {
        'id': 'persisted-r1',
        'user_id': 'bob-id',
        'username': 'bob',
        'nickname': 'Bob',
        'matrix_user_id': '@bob:test',
        'message': 'Original context',
        'status': 'ACCEPTED',
        'direction': 'INCOMING'
      };
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://business.test'),
          sessionStore: await _currentSession(),
          client: MockClient((call) async {
            if (call.method != 'GET') writes++;
            final items = call.url.path.endsWith('/requests') || stillFriends
                ? [request]
                : [];
            return http.Response(jsonEncode({'items': items}), 200,
                headers: {'content-type': 'application/json'});
          }));
      await tester.pumpWidget(CupertinoApp(
          home: FriendRequestsPage(
              api: api,
              identityCache: ProfileRepository.forTesting(
                  accountKey: 'matrix:@me:test', store: MemoryProfileStore()),
              onEstablishDirectChatWithRequest:
                  (peer, id, name, context) async {
                opened++;
                expect(context['id'], 'persisted-r1');
                expect(context['message'], 'Original context');
              })));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('friend-request-open-chat')), findsOneWidget);
      await tester.tap(find.byKey(const Key('friend-request-open-chat')));
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(opened, stillFriends ? 1 : 0);
    });
  }
  testWidgets('initialization retry preserves acceptance and original context',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    var accepts = 0;
    var initializations = 0;
    final request = {
      'id': 'r1',
      'user_id': 'bob-id',
      'username': 'bob',
      'nickname': 'Bob',
      'matrix_user_id': '@bob:test',
      'message': 'Hi',
      'status': 'PENDING',
      'direction': 'INCOMING'
    };
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.test'),
        sessionStore: await _currentSession(),
        client: MockClient((call) async {
          if (call.url.path.endsWith('/accept')) accepts++;
          return http.Response(
              jsonEncode(call.method == 'GET'
                  ? {
                      'items': [request]
                    }
                  : {}),
              200,
              headers: {'content-type': 'application/json'});
        }));
    final cache = ProfileRepository.forTesting(
        accountKey: 'matrix:@me:test', store: MemoryProfileStore());
    await tester.pumpWidget(CupertinoApp(
        home: FriendRequestsPage(
            api: api,
            identityCache: cache,
            onEstablishDirectChatWithRequest:
                (peer, businessId, name, context) async {
              initializations++;
              expect(context['id'], 'r1');
              expect(context['message'], 'Hi');
              if (initializations == 1) throw StateError('offline');
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('friend-request-accept')));
    await tester.pumpAndSettle();
    expect(accepts, 1);
    expect(cache.contacts.single.userId, 'bob-id');
    expect(find.text('已添加好友'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(accepts, 1, reason: 'Only encrypted chat initialization is retried');
    expect(initializations, 2);
    expect(find.text('已添加好友'), findsNothing);
  });

  testWidgets('in-flight acceptance cannot finish in a switched account',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final entered = Completer<void>();
    final resume = Completer<void>();
    var changes = 0;
    var writesA = 0;
    var writesB = 0;
    final request = {
      'id': 'r-switch',
      'user_id': 'bob-id',
      'username': 'bob',
      'nickname': 'Bob',
      'matrix_user_id': '@bob:test',
      'status': 'PENDING',
      'direction': 'INCOMING',
    };
    BusinessApiClient client(
            SecureSessionStore session, void Function() onWrite) =>
        BusinessApiClient(
            baseUri: Uri.parse('https://business.test'),
            sessionStore: session,
            client: MockClient((call) async {
              if (call.method != 'GET') onWrite();
              return http.Response(
                  jsonEncode(call.method == 'GET'
                      ? {
                          'items': [request]
                        }
                      : <String, Object>{}),
                  200,
                  headers: {'content-type': 'application/json'});
            }));
    final sessionA = await _currentSession();
    final sessionB = await _currentSession(matrixUserId: '@bea:test');
    final apiA = client(sessionA, () => writesA++);
    final apiB = client(sessionB, () => writesB++);
    final cacheA = ProfileRepository.forTesting(
        accountKey: 'matrix:@me:test', store: MemoryProfileStore());
    final cacheB = ProfileRepository.forTesting(
        accountKey: 'matrix:@bea:test', store: MemoryProfileStore());
    var activeApi = apiA;
    var activeCache = cacheA;
    late StateSetter setHostState;
    await tester.pumpWidget(
        CupertinoApp(home: StatefulBuilder(builder: (context, setState) {
      setHostState = setState;
      return FriendRequestsPage(
          api: activeApi,
          identityCache: activeCache,
          onRequestsChanged: () => changes++,
          onEstablishDirectChatWithRequest: (peer, id, name, context) async {
            entered.complete();
            await resume.future;
          });
    })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('friend-request-accept')));
    for (var i = 0; i < 20 && !entered.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(writesA, 1);
    expect(entered.isCompleted, isTrue);

    setHostState(() {
      activeApi = apiB;
      activeCache = cacheB;
    });
    await tester.pumpAndSettle();
    resume.complete();
    await tester.pumpAndSettle();
    expect(writesA, 1);
    expect(writesB, 0);
    expect(changes, 0,
        reason: 'A completion must not notify the now-active B request page');
  });
}
