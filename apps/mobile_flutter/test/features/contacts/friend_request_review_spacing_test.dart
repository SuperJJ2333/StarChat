import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/friend_request_review_page.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:liuhetong_mobile/ui/theme/wechat_theme.dart';

/// 需求 2（2026-09-19）：「通过朋友验证」页的「已添加」徽标与「打开聊天」
/// 按钮必须留出明确间距（设计网格 md = 12dp 起），同时不得破坏徽标醒目度与
/// 按钮规范（`brandPrimary` 填充 / 白字 16sp / 48dp 高 / 12dp 圆角 / busy 加载态），
/// 深浅色、长文本换行与 iPhone SE 窄屏都不得溢出。
void main() {
  testWidgets('已添加徽标与打开聊天按钮之间至少留出一个 md 网格间距', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: FriendRequestReviewPage(
        request: _accepted,
        onAccept: () async {},
        onReject: () async {},
        onOpenAccepted: () async {},
      ),
    ));
    await tester.pumpAndSettle();

    final badge = tester.getRect(find.byKey(const Key('friend-request-status')));
    final button =
        tester.getRect(find.byKey(const Key('friend-request-open-chat')));
    final gap = button.top - badge.bottom;
    expect(gap, greaterThanOrEqualTo(WeChatSpacing.md),
        reason: '徽标与按钮之间的实际间距是 ${gap.toStringAsFixed(1)}dp，'
            '必须 ≥ WeChatSpacing.md(${WeChatSpacing.md})');
    expect(button.top, greaterThan(badge.bottom),
        reason: '按钮必须排在徽标下方，两者不得重叠');
    // 与设计网格对齐：间距必须是 4dp 网格的整数倍。
    expect(gap % 4, 0,
        reason: '间距 ${gap.toStringAsFixed(1)}dp 必须落在 4dp 设计网格上');
  });

  testWidgets('间距调整不得削弱徽标醒目度与按钮规范', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: FriendRequestReviewPage(
        request: _accepted,
        onAccept: () async {},
        onReject: () async {},
        onOpenAccepted: () async {},
      ),
    ));
    await tester.pumpAndSettle();

    // 徽标：品牌淡底 + 品牌色粗体文字。
    final badge = tester.widget<Container>(
        find.byKey(const Key('friend-request-status')));
    final background = (badge.decoration! as BoxDecoration).color!;
    expect(background, WeChatColors.brandTint);
    expect(background.a, greaterThan(0.05));
    final label = tester.widget<Text>(find.text('已添加'));
    expect(label.style!.color, WeChatColors.brandPrimary);
    expect(label.style!.fontWeight, FontWeight.w600);

    // 按钮：品牌填充、白字 16sp、48dp 高、12dp 圆角。
    final button = tester.widget<CupertinoButton>(find
        .ancestor(
            of: find.text('打开聊天'), matching: find.byType(CupertinoButton))
        .first);
    expect(button.color, WeChatColors.brandPrimary);
    expect(button.borderRadius, BorderRadius.circular(WeChatRadius.dialog));
    expect(WeChatRadius.dialog, 12);
    expect(tester.getSize(find.byKey(const Key('friend-request-open-chat'))).height,
        48);
    final text = tester.widget<Text>(find.text('打开聊天'));
    expect(text.style!.color, CupertinoColors.white);
    expect(text.style!.fontSize, 16);
  });

  testWidgets('busy 时按钮显示加载态且不可点击（间距不变）', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: FriendRequestReviewPage(
        request: _accepted,
        onAccept: () async {},
        onReject: () async {},
        onOpenAccepted: () async {},
        busy: true,
      ),
    ));
    await tester.pump();

    expect(
        find.descendant(
            of: find.byKey(const Key('friend-request-open-chat')),
            matching: find.byType(CupertinoActivityIndicator)),
        findsOneWidget);
    final button = tester.widget<CupertinoButton>(find
        .ancestor(
            of: find.byType(CupertinoActivityIndicator),
            matching: find.byType(CupertinoButton))
        .first);
    expect(button.onPressed, isNull, reason: 'busy 期间不得重复触发打开聊天');

    final badge = tester.getRect(find.byKey(const Key('friend-request-status')));
    final box =
        tester.getRect(find.byKey(const Key('friend-request-open-chat')));
    expect(box.top - badge.bottom, greaterThanOrEqualTo(WeChatSpacing.md));
  });

  testWidgets('深色 + iPhone SE 宽度 + 超长状态文案：无溢出，徽标文字换行', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(brightness),
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: 2,
          maxScaleFactor: 2,
          child: FriendRequestReviewPage(
            request: _longestStatus,
            onAccept: () async {},
            onReject: () async {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: '$brightness 下 320dp 宽 + 2× 字号不得溢出');
      expect(find.text('对方已撤销申请'), findsOneWidget);
      final badge = tester.getRect(find.byKey(const Key('friend-request-status')));
      expect(badge.right, lessThanOrEqualTo(320),
          reason: '徽标右边界 ${badge.right} 超出 320dp 屏幕');
    }
  });

  testWidgets('极窄容器下徽标文字换行且不溢出（无按钮态）', (tester) async {
    // 极窄视口 + 2× 字号：强制徽标文字换行。
    tester.view.physicalSize = const Size(200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: 2,
        maxScaleFactor: 2,
        child: const FriendRequestReviewPage(
          request: _longestStatus,
          onAccept: _noop,
          onReject: _noop,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '窄容器下徽标不得溢出');
    final badge = tester.getRect(find.byKey(const Key('friend-request-status')));
    expect(badge.right, lessThanOrEqualTo(200),
        reason: '徽标右边界 ${badge.right} 超出 200dp 容器');
    // 2× 字号下 7 个字在 136dp 文本宽度里必须折行（单行约 30dp 高）。
    expect(tester.getSize(find.text('对方已撤销申请')).height, greaterThan(40),
        reason: '长状态文案必须换行显示而不是被裁切或溢出');
  });

  testWidgets('窄屏 + ACCEPTED 且有按钮时徽标与按钮仍不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: 1.4,
        maxScaleFactor: 1.4,
        child: FriendRequestReviewPage(
          request: _accepted,
          onAccept: () async {},
          onReject: () async {},
          onOpenAccepted: () async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final badge = tester.getRect(find.byKey(const Key('friend-request-status')));
    final button =
        tester.getRect(find.byKey(const Key('friend-request-open-chat')));
    expect(button.top - badge.bottom, greaterThanOrEqualTo(WeChatSpacing.md));
    expect(button.right, lessThanOrEqualTo(320));
    expect(button.height, 48);
  });
}

Future<void> _noop() async {}

const _accepted = <String, dynamic>{
  'id': 'req-1',
  'user_id': 'bob',
  'username': 'bob',
  'nickname': 'Bob',
  'avatar_url': null,
  'matrix_user_id': '@bob:test',
  'message': '我是Bob，很高兴认识你',
  'status': 'ACCEPTED',
  'direction': 'INCOMING',
};

const _longestStatus = <String, dynamic>{
  'id': 'req-2',
  'user_id': 'bob',
  'username': 'bob',
  'nickname': 'Bob',
  'avatar_url': null,
  'matrix_user_id': '@bob:test',
  'message': '我是Bob，很高兴认识你',
  'status': 'CANCELLED',
  'direction': 'INCOMING',
};
