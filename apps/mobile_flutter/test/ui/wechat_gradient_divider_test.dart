import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/wechat_contact_tile.dart';
import 'package:liuhetong_mobile/ui/components/wechat_gradient_divider.dart';
import 'package:liuhetong_mobile/ui/components/wechat_list_tile.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:liuhetong_mobile/ui/theme/wechat_theme.dart';

/// 共享渐隐分割线：与朋友圈分割线同几何（1px、整行宽、divider token 取色），
/// 但整体不透明度更低，并且两端渐隐到完全透明；浅色/深色都在 build 时解析。
void main() {
  testWidgets('分割线两端 alpha 为 0，中部低于实心分割线', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: const Center(child: WeChatGradientDivider()),
    ));

    final divider = find.byType(WeChatGradientDivider);
    expect(divider, findsOneWidget);
    expect(tester.getSize(divider).height, WeChatDividerTokens.hairline);

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
    // 「比现在更低不透明度」：低于朋友圈实心分割线的 1.0。
    expect(WeChatDividerTokens.centerAlpha, lessThan(1.0));
    expect(WeChatDividerTokens.centerAlpha, greaterThan(0.0));
    expect(WeChatDividerTokens.coreStart, lessThan(WeChatDividerTokens.coreEnd));
    // 浅色使用 divider token（#D9D9D9）。
    expect(gradient.colors[1].r, closeTo(217 / 255, 0.01));
  });

  testWidgets('深色按 darkDivider 解析，不留下硬编码浅色值', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.dark),
      home: const Center(child: WeChatGradientDivider()),
    ));
    final gradient = _gradient(tester, find.byType(WeChatGradientDivider));
    expect(gradient.colors.first.a, WeChatDividerTokens.edgeAlpha);
    expect(gradient.colors[1].a, WeChatDividerTokens.centerAlpha);
    expect(gradient.colors[1].r, closeTo(44 / 255, 0.01));
    expect(gradient.colors[1].g, closeTo(44 / 255, 0.01));
    expect(gradient.colors[1].b, closeTo(44 / 255, 0.01));
  });

  testWidgets('缩进参数按需生效，默认与朋友圈分割线一致（整行宽）', (tester) async {
    Future<Rect> visibleRect() async {
      await tester.pump();
      return tester.getRect(find.descendant(
          of: find.byType(WeChatGradientDivider),
          matching: find.byType(DecoratedBox)));
    }

    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: const Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 300,
          child: WeChatGradientDivider(indent: 40, endIndent: 8),
        ),
      ),
    ));
    final indented = await visibleRect();
    expect(indented.left, 40);
    expect(indented.right, 292);

    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: const Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(width: 300, child: WeChatGradientDivider()),
      ),
    ));
    final fullWidth = await visibleRect();
    expect(fullWidth.left, 0);
    expect(fullWidth.right, 300);
  });

  testWidgets('列表单元与好友行共用同一个共享分割线组件', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: const Column(children: [
        WeChatListTile(
          key: Key('tile-with-divider'),
          title: Text('新的朋友'),
          leading: Icon(CupertinoIcons.person_add_solid),
          showDivider: true,
        ),
        WeChatListTile(
          key: Key('tile-without-divider'),
          title: Text('标签'),
          leading: Icon(CupertinoIcons.tag_fill),
        ),
        WeChatContactTile(
            key: Key('contact-with-divider'),
            nickname: 'Amy',
            fallbackSeed: 'amy'),
        WeChatContactTile(
            key: Key('contact-without-divider'),
            nickname: 'Ava',
            fallbackSeed: 'ava',
            showDivider: false),
      ]),
    ));

    expect(
      find.descendant(
          of: find.byKey(const Key('tile-with-divider')),
          matching: find.byType(WeChatGradientDivider)),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: find.byKey(const Key('tile-without-divider')),
          matching: find.byType(WeChatGradientDivider)),
      findsNothing,
    );
    expect(
      find.descendant(
          of: find.byKey(const Key('contact-with-divider')),
          matching: find.byType(WeChatGradientDivider)),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: find.byKey(const Key('contact-without-divider')),
          matching: find.byType(WeChatGradientDivider)),
      findsNothing,
    );
    // 行高契约不因分割线改变：好友行仍是 56dp（字母索引偏移依赖它）。
    expect(
      tester.getSize(find.byKey(const Key('contact-with-divider'))).height,
      WeChatDimensions.contactTileHeight,
    );
    expect(
      tester.getSize(find.byKey(const Key('contact-without-divider'))).height,
      WeChatDimensions.contactTileHeight,
    );
  });

  testWidgets('好友行背景色取 surfaceElevated，深浅色都正确', (tester) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(brightness),
        home: const WeChatContactTile(nickname: 'Amy', fallbackSeed: 'amy'),
      ));
      await tester.pumpAndSettle();
      final surface = tester.widget<ColoredBox>(
          find.byKey(const Key('wechat-contact-elevated-surface')));
      expect(
        surface.color,
        brightness == Brightness.dark
            ? WeChatColors.darkElevated
            : WeChatColors.lightElevated,
      );
    }
  });
}

LinearGradient _gradient(WidgetTester tester, Finder divider) =>
    (tester
            .widget<DecoratedBox>(find.descendant(
                of: divider, matching: find.byType(DecoratedBox)))
            .decoration as BoxDecoration)
        .gradient! as LinearGradient;
