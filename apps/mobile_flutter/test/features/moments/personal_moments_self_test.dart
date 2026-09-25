import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/personal_moments_page.dart';

class _Store implements SecureKeyValueStore {
  final values = <String, String>{};
  bool failSessionReads = false;
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async {
    if (failSessionReads && key == 'liuhetong.business_session.v1') {
      throw StateError('temporary secure-store failure');
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

http.Response _json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _moment(String id, String authorId, String status) => {
      'id': id,
      'author': {'user_id': authorId, 'username': authorId},
      'text': id,
      'image_urls': <String>[],
      'created_at': '2026-09-24T00:00:00Z',
      'status': status,
      'comments': <Object>[],
    };

void main() {
  testWidgets(
      'self More remains available after a temporary identity read error',
      (tester) async {
    final keys = _Store();
    final store = SecureSessionStore(keys);
    await store.saveSession(
        accessToken: 'e30.eyJzdWIiOiJ1MSJ9.test', refreshToken: 'synthetic');
    keys.failSessionReads = true;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: store,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/moments/users/u1')) {
            return _json({'items': <Object>[]});
          }
          if (request.url.path.endsWith('/moments/notifications')) {
            return _json({'items': <Object>[], 'next_cursor': null});
          }
          return _json({});
        }));
    await tester.pumpWidget(CupertinoApp(
        home: PersonalMomentsPage(
            api: api,
            userId: 'u1',
            displayName: 'Alice',
            publishedOnly: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('personal-moments-more')), findsOneWidget);

    keys.failSessionReads = false;
    await tester.tap(find.byKey(const Key('personal-moments-more')));
    await tester.pumpAndSettle();
    expect(find.text('全部互动消息'), findsOneWidget);
  });

  testWidgets('self More verifies the live account before opening inbox',
      (tester) async {
    final store = SecureSessionStore(_Store());
    await store.saveSession(
        accessToken: 'e30.eyJzdWIiOiJ1MSJ9.test', refreshToken: 'synthetic');
    final requests = <String>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: store,
        client: MockClient((request) async {
          requests.add(request.url.path);
          return _json({'items': <Object>[]});
        }));
    await tester.pumpWidget(CupertinoApp(
        home: PersonalMomentsPage(
            api: api, userId: 'u2', displayName: 'Bob', publishedOnly: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('personal-moments-more')));
    await tester.pumpAndSettle();
    expect(find.text('全部互动消息'), findsNothing);
    expect(requests, isNot(contains('/api/v1/moments/notifications')));
  });

  testWidgets('self route shows only published own posts and opens inbox',
      (tester) async {
    final store = SecureSessionStore(_Store());
    await store.saveSession(
        accessToken: 'e30.eyJzdWIiOiJ1MSJ9.test', refreshToken: 'synthetic');
    final requests = <String>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: store,
        client: MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path.endsWith('/moments/users/u1')) {
            return _json({
              'items': [
                _moment('published-own', 'u1', 'PUBLISHED'),
                _moment('pending-own', 'u1', 'PENDING_REVIEW'),
                _moment('published-friend', 'u2', 'PUBLISHED'),
                {
                  'kind': 'AD',
                  'id': 'ad',
                  'ad': {
                    'advertiser_name': 'ad',
                    'text': 'ad',
                    'image_urls': [],
                    'link_url': 'https://example.test'
                  }
                }
              ]
            });
          }
          if (request.url.path.endsWith('/moments/notifications')) {
            return _json({'items': <Object>[], 'next_cursor': null});
          }
          return _json({});
        }));
    await tester.pumpWidget(CupertinoApp(
        home: PersonalMomentsPage(
            api: api,
            userId: 'u1',
            displayName: 'Alice',
            publishedOnly: true)));
    await tester.pumpAndSettle();
    expect(find.text('我的朋友圈'), findsOneWidget);
    expect(find.text('published-own'), findsOneWidget);
    expect(find.text('pending-own'), findsNothing);
    expect(find.text('published-friend'), findsNothing);
    expect(find.text('ad'), findsNothing);
    await tester.tap(find.byKey(const Key('personal-moments-more')));
    await tester.pumpAndSettle();
    expect(find.text('全部互动消息'), findsOneWidget);
    expect(requests, contains('/api/v1/moments/notifications'));
  });
}
