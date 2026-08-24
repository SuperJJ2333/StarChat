import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_composer_page.dart';

void main() {
  testWidgets('composer keeps only approved WeChat-style option rows',
      (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/moments/draft')) {
          return http.Response(jsonEncode({}), 200,
              headers: {'content-type': 'application/json'});
        }
        throw StateError('Unexpected ${request.method} ${request.url}');
      }),
    );
    await tester.pumpWidget(
      CupertinoApp(home: MomentComposerPage(api: api)),
    );
    await tester.pumpAndSettle();

    expect(find.text('这一刻的想法…'), findsOneWidget);
    expect(find.text('谁可以看'), findsOneWidget);
    expect(find.text('公开'), findsOneWidget);
    expect(find.text('添加链接'), findsOneWidget);
    expect(find.text('所在位置'), findsNothing);
    expect(find.text('提醒谁看'), findsNothing);
    expect(find.byKey(const Key('moment-compose-publish')), findsOneWidget);
    expect(find.byKey(const Key('moment-pick-images')), findsOneWidget);
  });

  testWidgets('publish failure retains text and shows a retryable error',
      (tester) async {
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/moments/draft') &&
            request.method == 'GET') {
          return http.Response(jsonEncode({}), 200,
              headers: {'content-type': 'application/json'});
        }
        if (request.url.path.endsWith('/moments') && request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'error': {
                'code': 'MOMENT_UNAVAILABLE',
                'message': '暂时无法发表',
              }
            }),
            503,
            headers: {'content-type': 'application/json'},
          );
        }
        throw StateError('Unexpected ${request.method} ${request.url}');
      }),
    );
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).first, '保留的内容');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pumpAndSettle();

    expect(find.text('保留的内容'), findsOneWidget);
    expect(find.text('暂时无法发表'), findsOneWidget);
    expect(find.byType(MomentComposerPage), findsOneWidget);
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
