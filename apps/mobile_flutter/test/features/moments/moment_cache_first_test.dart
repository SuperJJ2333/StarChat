import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/moments/moment_detail_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/features/moments/moments_privacy_changes.dart';
import 'package:liuhetong_mobile/features/moments/personal_moments_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'moments_flow_test.dart' as fixtures;

/// 微信级加载模型（2026-09-19 审计）：
/// - 个人朋友圈原先刷新失败就 `_items = []` + 整页错误，把已经看到的动态丢掉；
///   可见性变化还会先清空再加载（闪白）。
/// - 动态详情在收到可见性变化通知时**预先**把已知动态隐藏成"动态暂不可见"，
///   若随后的刷新只是一次瞬时失败，用户就再也看不到这条动态了。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  MomentItem item() =>
      MomentItem.fromJson(fixtures.momentJson(liked: false, likeCount: 0));

  testWidgets('个人朋友圈：刷新失败保留已展示的动态，不显示整页错误', (tester) async {
    final api = await fixtures.momentsApi(
        (request) async => throw StateError('offline'));

    await tester.pumpWidget(CupertinoApp(
        home: PersonalMomentsPage(
            api: api,
            userId: 'u1',
            displayName: 'Alice',
            initialItems: [item()])));
    await tester.pumpAndSettle();

    expect(find.text('朋友圈正文'), findsOneWidget, reason: '失败不得清空已展示的动态');
    expect(find.text('朋友圈加载失败，请重试'), findsNothing,
        reason: '有内容时的刷新失败不显示整页错误');
  });

  testWidgets('个人朋友圈：可见性变化不预先清空内容（不闪白）', (tester) async {
    final api = await fixtures.momentsApi(
        (request) async => throw StateError('offline'));

    await tester.pumpWidget(CupertinoApp(
        home: PersonalMomentsPage(
            api: api,
            userId: 'u1',
            displayName: 'Alice',
            initialItems: [item()])));
    await tester.pumpAndSettle();

    momentsPrivacyChanges.changed();
    await tester.pumpAndSettle();

    expect(find.text('朋友圈正文'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing,
        reason: '有内容时可见性变化不得切换成整页加载圈');
  });

  testWidgets('动态详情：可见性变化后的瞬时失败不清掉已知动态', (tester) async {
    final api = await fixtures.momentsApi(
        (request) async => throw StateError('offline'));

    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api, initialItem: item(), currentUsername: 'Alice')));
    await tester.pumpAndSettle();

    momentsPrivacyChanges.changed();
    await tester.pumpAndSettle();

    expect(find.text('动态暂不可见，请重试'), findsNothing,
        reason: '只有服务端明确 401/403/404 才允许判定不可见');
    expect(find.text('朋友圈正文'), findsOneWidget);
  });
}
