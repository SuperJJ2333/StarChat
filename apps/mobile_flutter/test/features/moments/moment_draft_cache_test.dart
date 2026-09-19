import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_composer_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../wallet/manual_wallet_api_test.dart' as fixtures;

/// 微信级加载模型（2026-09-19 审计）：发动态草稿只存在服务端，断网时既读不到
/// 上次的草稿，写了也留不下——发布页一关就全丢。本地草稿（账号作用域）先渲染、
/// 保存时先落盘，服务端只是对齐。
Future<BusinessApiClient> _client(
    Future<http.Response> Function(http.Request) handler) async {
  final session = SecureSessionStore(fixtures.MemoryStore());
  await session.saveSession(
      accessToken: 'e30.eyJzdWIiOiJhbGljZSJ9.test',
      refreshToken: 'refresh',
      matrixUserId: '@alice:example');
  return BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: session,
      client: MockClient(handler));
}

MomentDraftSnapshot _snapshot(String text) => MomentDraftSnapshot(
      scope: 'matrix:@alice:example',
      payload: {
        'text': text,
        'visibility': 'PUBLIC',
        'image_urls': const <String>[],
        'link_url': null,
        'include_user_ids': const <String>[],
        'include_tag_ids': const <String>[],
        'exclude_user_ids': const <String>[],
        'exclude_tag_ids': const <String>[],
      },
      savedAt: DateTime(2026, 9, 19, 9),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MomentDraftStores.reset();
  });
  tearDown(MomentDraftStores.reset);

  testWidgets('断网 + 本地草稿：发布页仍能接着上次写', (tester) async {
    final api = await _client((request) async => throw StateError('offline'));
    final store = InMemoryMomentDraftStore(_snapshot('本地草稿正文'));
    MomentDraftStores.shared = store;

    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('本地草稿正文'), findsOneWidget,
        reason: '断网时必须展示本地草稿而不是空白编辑器');
  });

  testWidgets('没有本地草稿且断网：显示空编辑器与可继续编辑的提示', (tester) async {
    final api = await _client((request) async => throw StateError('offline'));
    MomentDraftStores.shared = InMemoryMomentDraftStore();

    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('这一刻的想法…'), findsOneWidget);
    expect(find.textContaining('草稿加载失败，可继续编辑'), findsOneWidget);
  });

  testWidgets('保存草稿先落本地：服务端失败也不丢', (tester) async {
    final api = await _client((request) async {
      if (request.url.path.endsWith('/moments/draft')) {
        throw StateError('offline');
      }
      throw StateError('Unexpected ${request.method} ${request.url}');
    });
    final store = InMemoryMomentDraftStore();
    MomentDraftStores.shared = store;

    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(CupertinoTextField).first, '离线草稿');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-compose-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();

    expect(store.read()?.payload['text'], '离线草稿',
        reason: '服务端保存失败时本地草稿必须已经留下');
    expect(store.read()?.scope, 'matrix:@alice:example');
  });
}
