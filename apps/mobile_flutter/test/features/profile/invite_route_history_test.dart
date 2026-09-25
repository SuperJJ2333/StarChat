import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/profile/invite_snapshot_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

Future<void> _openInvitePage(WidgetTester tester, BusinessApiClient api) async {
  await tester.pumpWidget(CupertinoApp(
    home: ProfileTabPage(api: api, onLogout: () async {}),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('profile-details-entry')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('profile-invite-entry')));
  await tester.pumpAndSettle();
}

Future<BusinessApiClient> _client(
    List<int> historyOffsets, Map<String, dynamic> Function(int offset) history) async {
  final session = SecureSessionStore(_MemoryStore());
  await session.saveSession(
      accessToken: 'profile-test-access', refreshToken: 'profile-test-refresh');
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.example.test'),
    sessionStore: session,
    client: MockClient((request) async {
      if (request.url.path == '/api/v1/profile/me') {
        return http.Response(jsonEncode({
          'username': 'owner',
          'nickname': '邀请人',
          'masked_email': 'ow***@example.test',
          'avatar_fallback_seed': 'owner',
          'signature': null,
          'avatar_url': null,
        }), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (request.url.path == '/api/v1/invitations/mine') {
        return http.Response(jsonEncode({
          'code': 'AB12CD34',
          'max_uses': 20,
          'use_count': 2,
          'share_url': 'https://example.test/register?code=AB12CD34',
        }), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (request.url.path == '/api/v1/invitations/history') {
        expect(request.headers['authorization'], 'Bearer profile-test-access');
        expect(request.url.queryParameters['limit'], '20');
        final offset = int.parse(request.url.queryParameters['offset']!);
        historyOffsets.add(offset);
        return http.Response(jsonEncode(history(offset)), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response('{"error":"unexpected route"}', 404);
    }),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    InviteSnapshotStores.reset();
  });

  tearDown(InviteSnapshotStores.reset);

  testWidgets('personal info invitation route loads authenticated history and next page',
      (tester) async {
    final offsets = <int>[];
    final api = await _client(offsets, (offset) => offset == 0
        ? {
            'items': [
              {
                'bound_at': '2026-09-24T08:34:00Z',
                'nickname': '小明',
                'username': 'friend_a',
              },
            ],
            'next_offset': 20,
          }
        : {
            'items': [
              {
                'bound_at': '2026-09-23T07:08:00Z',
                'nickname': '小红',
                'username': 'friend_b',
              },
            ],
            'next_offset': null,
          });

    await _openInvitePage(tester, api);

    expect(offsets, [0]);
    expect(find.byKey(const Key('invite-history-friend_a')), findsOneWidget);
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('畅聊号：friend_a'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')),
        findsOneWidget);

    final more = find.byKey(const Key('invite-history-load-more'));
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(offsets, [0, 20]);
    expect(find.byKey(const Key('invite-history-friend_b')), findsOneWidget);
    expect(find.text('小红'), findsOneWidget);
    expect(find.byKey(const Key('invite-history-load-more')), findsNothing);
  });

  testWidgets('personal info invitation route shows explicit empty history',
      (tester) async {
    final offsets = <int>[];
    final api = await _client(
        offsets, (_) => {'items': <Object>[], 'next_offset': null});

    await _openInvitePage(tester, api);

    expect(offsets, [0]);
    expect(find.byKey(const Key('invite-history-empty')), findsOneWidget);
    expect(find.text('暂无邀请记录'), findsOneWidget);
    expect(find.byKey(const Key('invite-history-idle')), findsNothing);
  });
}
