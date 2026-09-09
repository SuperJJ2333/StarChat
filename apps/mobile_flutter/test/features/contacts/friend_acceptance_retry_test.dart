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
          sessionStore: SecureSessionStore(),
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
        sessionStore: SecureSessionStore(),
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
}
