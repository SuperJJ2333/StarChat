import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/features/moments/moment_visibility_page.dart';
import 'package:liuhetong_mobile/ui/components/wechat_gradient_divider.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';
import 'package:liuhetong_mobile/ui/theme/wechat_theme.dart';

/// 需求 1（2026-09-19）：朋友圈分割线统一为共享渐隐分割线。
///
/// 朋友圈此前在 `WeChatMomentTile` 上画「实心 1px `Border(bottom:)`」，与好友
/// 列表的共享 `WeChatGradientDivider` 不是同一实现；本测试锁定统一后的契约：
/// 同一个共享组件、同一套 `WeChatDividerTokens`（两端 alpha 0 / 中段 0.5 /
/// stops 0·0.18·0.82·1）、色源 `divider` token、深浅色都在 build 时解析，
/// 并且行高不因画线改变（线画在行内，不额外占高）。
void main() {
  testWidgets('朋友圈动态行改用共享渐隐分割线，不再保留实心底边', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: WeChatMomentTile(item: _post()),
    ));

    final divider = find.byKey(const Key('moment-tile-divider'));
    expect(divider, findsOneWidget,
        reason: '朋友圈动态行必须由共享 WeChatGradientDivider 画分隔线');
    expect(tester.widget(divider), isA<WeChatGradientDivider>());

    final gradient = _gradient(tester, divider);
    expect(gradient.stops, const [
      WeChatDividerTokens.edgeStartStop,
      WeChatDividerTokens.coreStart,
      WeChatDividerTokens.coreEnd,
      WeChatDividerTokens.edgeEndStop,
    ]);
    expect(gradient.colors.first.a, WeChatDividerTokens.edgeAlpha);
    expect(gradient.colors.last.a, WeChatDividerTokens.edgeAlpha);
    expect(gradient.colors[1].a, WeChatDividerTokens.centerAlpha);
    // 色源仍是 divider token（浅色 #D9D9D9）。
    expect(gradient.colors[1].r, closeTo(217 / 255, 0.01));

    // 行表面装饰里不得再留实心底边（否则就是第二套实心分割线实现）。
    final decoration = _tileDecoration(tester);
    expect(decoration.border, isNull,
        reason: '朋友圈动态行不得再画实心 Border(bottom:)');
    expect(decoration.color, WeChatColors.lightElevated);
  });

  testWidgets('朋友圈动态行深色下按 darkDivider 解析', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.dark),
      home: WeChatMomentTile(item: _post()),
    ));

    final gradient = _gradient(
        tester, find.byKey(const Key('moment-tile-divider')));
    expect(gradient.colors.first.a, WeChatDividerTokens.edgeAlpha);
    expect(gradient.colors[1].a, WeChatDividerTokens.centerAlpha);
    expect(gradient.colors[1].r, closeTo(44 / 255, 0.01));
    expect(gradient.colors[1].g, closeTo(44 / 255, 0.01));
    expect(gradient.colors[1].b, closeTo(44 / 255, 0.01));
    expect(_tileDecoration(tester).color, WeChatColors.darkElevated);
  });

  testWidgets('朋友圈可见范围页的组内行分隔线同样使用共享渐隐分割线', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: MomentVisibilityPage(
        api: _api(),
        initialSelection: const MomentVisibilitySelection.public(),
      ),
    ));

    for (final key in const [
      'visibility-divider-primary',
      'visibility-divider-submenu',
    ]) {
      final finder = find.byKey(Key(key));
      expect(finder, findsOneWidget, reason: '$key 必须存在');
      expect(tester.widget(finder), isA<WeChatGradientDivider>(),
          reason: '$key 必须使用共享渐隐分割线，而不是实心 ColoredBox');
    }

    // 原有左缩进 16dp 保留（缩进由共享组件的 indent 参数承担，行高不变）。
    final visible = tester.getRect(find.descendant(
        of: find.byKey(const Key('visibility-divider-primary')),
        matching: find.byType(DecoratedBox)));
    expect(visible.left, WeChatSpacing.lg);
  });

  testWidgets('朋友圈互动面板内部的区块分隔线也复用同一共享组件', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: WeChatMomentTile(item: _post()),
    ));

    for (final key in const [
      'moment-likes-divider',
      'moment-comment-divider-two',
    ]) {
      final finder = find.byKey(Key(key));
      expect(finder, findsOneWidget, reason: '$key 必须存在');
      expect(tester.widget(finder), isA<WeChatGradientDivider>(),
          reason: '$key 不得再自行实现一条实心分割线');
    }
  });
}

MomentItem _post() => MomentItem.fromJson({
      'id': 'post',
      'text': 'Body',
      'created_at': '2026-09-09T00:00:00Z',
      'author': {'user_id': 'owner', 'nickname': 'Owner'},
      'like_users': [
        {'user_id': 'friend', 'nickname': 'Friend'}
      ],
      'comments': [
        {
          'id': 'one',
          'text': 'First comment',
          'author': {'user_id': 'self', 'nickname': 'Me'},
        },
        {
          'id': 'two',
          'text': 'Reply text',
          'author': {'user_id': 'friend', 'nickname': 'Friend'},
          'parent_author': {'user_id': 'self', 'nickname': 'Me'},
        },
      ],
    });

BusinessApiClient _api() => BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 200)),
    );

BoxDecoration _tileDecoration(WidgetTester tester) => tester
    .widget<Container>(find
        .descendant(
            of: find.byType(WeChatMomentTile), matching: find.byType(Container))
        .first)
    .decoration! as BoxDecoration;

LinearGradient _gradient(WidgetTester tester, Finder divider) =>
    (tester
            .widget<DecoratedBox>(find.descendant(
                of: divider, matching: find.byType(DecoratedBox)))
            .decoration as BoxDecoration)
        .gradient! as LinearGradient;
