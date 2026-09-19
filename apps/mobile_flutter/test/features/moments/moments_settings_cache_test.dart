import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moments_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../wallet/manual_wallet_api_test.dart' as fixtures;

/// 微信级加载模型（2026-09-19 审计）：朋友圈权限页原先要等 `momentsPreferences()`
/// 回来才渲染表单，失败时整页只有"权限加载失败"——断网时连看都看不到自己当前的
/// 权限设置。朋友圈首页早已把这份负载写进本地快照，这里先用快照渲染。
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

Future<void> _seedSnapshot() async {
  final cache =
      (await CacheRepository.instance()).momentsFor('matrix:@alice:example');
  await cache.savePreferences(const {
    'history_range': 'THREE_DAYS',
    'personalized_recommendations': false,
    'profile_entry_enabled': true,
    'excluded_user_ids': ['u1', 'u2'],
  });
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
    // 生产里由启动序列建立；测试里显式建立，页面才能读到本地快照。
    await CacheRepository.instance();
  });
  tearDown(() async {
    await CacheRepository.resetForTest();
  });

  testWidgets('断网 + 本地快照：权限表单照常渲染、不显示整页错误', (tester) async {
    final api =
        await _client((request) async => throw StateError('offline'));
    await _seedSnapshot();

    await tester.pumpWidget(CupertinoApp(home: MomentsSettingsPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('权限加载失败，请重试'), findsNothing,
        reason: '有本地快照时的刷新失败不显示整页错误');
    expect(find.byKey(const Key('moments-privacy-retry')), findsNothing);
    expect(find.text('2人'), findsOneWidget,
        reason: '「不给谁看」应显示快照里的 2 人，而不是未设置');
    expect(find.text('允许朋友查看朋友圈的范围'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
  });

  testWidgets('没有本地快照且加载失败：显示失败与重试（不假装已加载）',
      (tester) async {
    final api =
        await _client((request) async => throw StateError('offline'));

    await tester.pumpWidget(CupertinoApp(home: MomentsSettingsPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('权限加载失败，请重试'), findsOneWidget);
    expect(find.byKey(const Key('moments-privacy-retry')), findsOneWidget);
  });

  testWidgets('加载成功：把最新权限回写本地快照', (tester) async {
    final api = await _client((request) async => http.Response(
        jsonEncode({
          'history_range': 'ONE_MONTH',
          'personalized_recommendations': true,
          'profile_entry_enabled': false,
          'excluded_user_ids': ['u9'],
        }),
        200,
        headers: {'content-type': 'application/json'}));

    await tester.pumpWidget(CupertinoApp(home: MomentsSettingsPage(api: api)));
    await tester.pumpAndSettle();

    final cache = CacheRepository.current!.momentsFor('matrix:@alice:example');
    expect(cache.preferencesSnapshot?['history_range'], 'ONE_MONTH');
    expect(cache.preferencesSnapshot?['excluded_user_ids'], ['u9']);
  });
}
