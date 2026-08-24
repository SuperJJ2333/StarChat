import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_visibility_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_visibility_people_page.dart';

void main() {
  testWidgets('people selector has tabs search multi-select and completion',
      (tester) async {
    final sessionStore = SecureSessionStore(_MemoryStore());
    await sessionStore.saveSession(
      accessToken: 'access',
      refreshToken: 'refresh',
    );
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: sessionStore,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/friends')) {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'user_id': 'u1',
                  'username': 'alice',
                  'nickname': 'Alice',
                  'remark': '项目小艾',
                  'matrix_user_id': '@alice:test',
                }
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/contact-tags')) {
          return http.Response(
            jsonEncode({
              'items': [
                {'id': 'tag-1', 'name': '项目组', 'friend_count': 3}
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        throw StateError('Unexpected ${request.url}');
      }),
    );
    MomentVisibilitySelection? completed;
    await tester.pumpWidget(CupertinoApp(
      home: Builder(builder: (context) {
        return CupertinoButton(
          child: const Text('打开'),
          onPressed: () async {
            completed = await Navigator.push<MomentVisibilitySelection>(
              context,
              CupertinoPageRoute(
                builder: (_) => MomentVisibilityPeoplePage(
                  api: api,
                  mode: 'INCLUDE',
                  initialSelection: const MomentVisibilitySelection.include(),
                ),
              ),
            );
          },
        );
      }),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoSearchTextField), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    expect(find.text('朋友'), findsOneWidget);
    expect(find.text('项目组'), findsOneWidget);
    await tester.tap(find.text('项目组'));
    await tester.pump();
    expect(find.text('完成(1)'), findsOneWidget);
    await tester.tap(find.text('朋友'));
    await tester.pump();
    expect(find.text('项目小艾'), findsOneWidget);
    await tester.tap(find.text('项目小艾'));
    await tester.pump();
    await tester.tap(find.text('完成(2)'));
    await tester.pumpAndSettle();

    expect(completed?.visibility, 'INCLUDE');
    expect(completed?.tagIds, {'tag-1'});
    expect(completed?.userIds, {'u1'});
  });
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
