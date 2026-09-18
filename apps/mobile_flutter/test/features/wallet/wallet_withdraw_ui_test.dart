import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:liuhetong_mobile/ui/components/wechat_secondary_button.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:liuhetong_mobile/ui/theme/wechat_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

/// 提现页 8 项 UI/交互修正（2026-09-18）：5 步骤指示器保留 + 进度动效；
/// 6 输入框与「全部提现」间距 ≥12dp；7 余额放大分层；8 删除「查看本次提现」；
/// 9 地址压缩靠左；10 删除「查看详情」并直接展示订单码 + 复制；
/// 11 确认前提现金额可改且与「全部提现」联动、提交以最终输入为准；
/// 12 确认有效期与本地过期校验都只认服务端 `expires_at`；
/// 13 确认后同一笔只以「处理中」订单呈现一次。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 进入态 Store 是进程内共享的：用例之间必须清空，否则缓存会泄漏。
    WalletEntryStores.disposeAll();
  });

  final target = fixtures.syntheticTronAddress();
  final compactTarget =
      '${target.substring(0, 8)}…${target.substring(target.length - 6)}';

  /// 打开提现页并捕获每次报价请求的金额。
  Future<List<String>> pumpPayout(
    WidgetTester tester, {
    Map<String, dynamic>? quoteBody,
    Brightness brightness = Brightness.light,
    bool reduceMotion = false,
    Map<String, dynamic>? binding,
  }) async {
    final quoteAmounts = <String>[];
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return flow.json(binding ?? fixtures.binding);
      }
      if (request.url.path.contains('/payout-quotes/')) {
        return flow.json(quoteBody ?? fixtures.quote);
      }
      if (request.url.path.endsWith('/payout-quotes')) {
        final body = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map<String, dynamic>);
        quoteAmounts.add('${body['amount']}');
        return flow.json(quoteBody ?? fixtures.quote);
      }
      return flow.json(fixtures.payout);
    });
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(brightness),
      builder: reduceMotion
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!)
          : null,
      home:
          ManualWalletPage(client: api, section: ManualWalletSection.payout),
    ));
    await tester.pumpAndSettle();
    return quoteAmounts;
  }

  Future<void> createQuote(WidgetTester tester, String amount) async {
    await tester.enterText(
        find.byKey(const Key('manual-payout-amount')), amount);
    await flow.tap(tester, find.byKey(const Key('manual-quote-create')));
  }

  testWidgets('需求5：点「下一步」后步骤指示器保留，并带进度动效', (tester) async {
    await pumpPayout(tester);
    expect(find.byKey(const Key('manual-payout-step-dot-0')), findsOneWidget);
    await createQuote(tester, '10');

    // 保留：三步指示器仍在，且进入第 2 步（确认报价）。
    expect(find.byKey(const Key('manual-quote-digest')), findsOneWidget);
    for (final label in ['填写金额', '确认报价', '到账']) {
      expect(find.text(label), findsOneWidget);
    }
    final step0 = tester.widget<AnimatedContainer>(
        find.byKey(const Key('manual-payout-step-dot-0')));
    final step1 = tester.widget<AnimatedContainer>(
        find.byKey(const Key('manual-payout-step-dot-1')));
    final step2 = tester.widget<AnimatedContainer>(
        find.byKey(const Key('manual-payout-step-dot-2')));
    expect((step0.decoration! as BoxDecoration).color,
        WeChatColors.brandPrimary,
        reason: '已完成步骤必须高亮');
    expect((step1.decoration! as BoxDecoration).color,
        WeChatColors.brandPrimary,
        reason: '当前步骤高亮');
    expect((step2.decoration! as BoxDecoration).color,
        isNot(WeChatColors.brandPrimary));
    expect(find.byKey(const Key('manual-payout-step-check-0')), findsOneWidget,
        reason: '已完成步骤显示勾号');
    expect(step0.duration, WeChatMotion.actionPressDuration,
        reason: '进度变化必须带过渡动效');
    expect(
        tester
            .widget<AnimatedContainer>(
                find.byKey(const Key('manual-payout-step-bar-0')))
            .duration,
        WeChatMotion.actionPressDuration);
  });

  testWidgets('需求5：系统「减少动态效果」下步骤动效时长为零', (tester) async {
    await pumpPayout(tester, reduceMotion: true);
    expect(
        tester
            .widget<AnimatedContainer>(
                find.byKey(const Key('manual-payout-step-dot-0')))
            .duration,
        Duration.zero,
        reason: '遵守系统减少动态效果设置');
    await createQuote(tester, '10');
    expect(
        tester
            .widget<AnimatedContainer>(
                find.byKey(const Key('manual-payout-step-dot-0')))
            .duration,
        Duration.zero);
  });

  testWidgets('需求6：「输入点钻金额」与「全部提现」之间有 ≥12dp 间距', (tester) async {
    await pumpPayout(tester);
    final field = tester.getRect(find.byKey(const Key('manual-payout-amount')));
    final all = tester
        .getRect(find.widgetWithText(WeChatSecondaryButton, '全部提现'));
    expect(all.left - field.right, greaterThanOrEqualTo(WeChatSpacing.md - 0.5),
        reason: '按设计网格至少 12dp，不能让按钮贴着输入框');
  });

  testWidgets('需求7：点钻余额放大展示，副信息用次级色（浅色）', (tester) async {
    await pumpPayout(tester);
    final hero = find.byKey(const Key('manual-payout-points-balance'));
    expect(hero, findsOneWidget);
    final amount = tester.widget<Text>(
        find.byKey(const Key('manual-payout-points-value')));
    expect(amount.data, '100.00');
    expect(amount.style!.fontSize,
        greaterThanOrEqualTo(WeChatTypography.display),
        reason: '余额数字必须明显放大（微信式层级）');
    expect(amount.style!.fontWeight, FontWeight.w700);
    expect(amount.style!.color, WeChatColors.lightTextPrimary);
    final label = tester.widget<Text>(
        find.descendant(of: hero, matching: find.text('当前点钻余额')));
    expect(label.style!.fontSize, lessThan(amount.style!.fontSize!));
    expect(label.style!.color, WeChatColors.textSecondary);
  });

  testWidgets('需求7：深色下余额与副信息取深色主题色', (tester) async {
    await pumpPayout(tester, brightness: Brightness.dark);
    final amount = tester.widget<Text>(
        find.byKey(const Key('manual-payout-points-value')));
    expect(amount.style!.color, WeChatColors.darkTextPrimary,
        reason: '深色下不得继续用浅色文字色');
    final label = tester.widget<Text>(find.descendant(
        of: find.byKey(const Key('manual-payout-points-balance')),
        matching: find.text('当前点钻余额')));
    expect(label.style!.color, const Color(0xFF999999),
        reason: '副信息用次级色（深色解析值 #999999）');
  });

  testWidgets('需求8：已生成报价后没有「查看本次提现」按钮', (tester) async {
    await pumpPayout(tester);
    await createQuote(tester, '10');
    expect(find.text('查看本次提现'), findsNothing,
        reason: '「查看本次提现」必须删除，且不得换名字变相保留');
  });

  testWidgets('需求9：收款地址压缩展示、靠左对齐，复制仍是完整地址', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpPayout(tester,
        quoteBody: {...fixtures.quote, 'target_address': target});
    await createQuote(tester, '10');

    expect(find.text(compactTarget), findsOneWidget);
    expect(find.text(target), findsNothing,
        reason: '完整地址不再撑开一行文本（复制 icon 因此能对齐）');
    final address = tester.getRect(find.text(compactTarget));
    expect(
        tester.widget<Text>(find.text(compactTarget)).textAlign, TextAlign.left,
        reason: '地址文字必须左对齐');
    expect(address.left,
        greaterThanOrEqualTo(tester.getRect(find.text('收款地址')).right - 0.5));
    final copy = find.byKey(const Key('manual-target-copy'));
    expect(copy, findsOneWidget);
    await tester.ensureVisible(copy);
    await tester.pumpAndSettle();
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copied, target, reason: '复制动作必须仍然是完整地址');
  });

  testWidgets('需求10：删除「查看详情」，订单码直接展示且可复制完整值', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpPayout(tester);
    await createQuote(tester, '10');

    expect(find.text('查看详情'), findsNothing);
    expect(find.text('收起详情'), findsNothing);
    final digest = fixtures.quote['digest']! as String;
    final compact =
        '${digest.substring(0, 10)}…${digest.substring(digest.length - 8)}';
    final code = tester.widget<Text>(
        find.byKey(const Key('manual-quote-digest-display')));
    expect(code.data, compact, reason: '订单展示码必须直接展示出来');
    expect(code.style!.fontSize, lessThanOrEqualTo(WeChatTypography.caption),
        reason: '订单展示码字号更小');
    await tester.ensureVisible(find.byKey(const Key('manual-quote-digest')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-quote-digest')));
    await tester.pumpAndSettle();
    expect(copied, digest, reason: '复制的是完整订单码');
  });

  testWidgets('需求11：确认前金额可改；改动后旧报价不参与提交，按最终输入重新报价',
      (tester) async {
    final quoteAmounts = await pumpPayout(tester);
    await createQuote(tester, '10');
    expect(quoteAmounts, ['10.000000']);

    // 输入框在确认前始终可编辑。
    expect(
        tester
            .widget<CupertinoTextField>(
                find.byKey(const Key('manual-payout-amount')))
            .enabled,
        isTrue,
        reason: '确认前不得把金额输入框设为只读/禁用');
    expect(find.byKey(const Key('manual-payout-confirm')), findsOneWidget);
    expect(find.byKey(const Key('manual-quote-digest')), findsOneWidget);

    // 「全部提现」仍与输入框联动（填满可提现余额）。
    await flow.tap(tester, find.byKey(const Key('manual-payout-all')));
    expect(
        tester
            .widget<CupertinoTextField>(
                find.byKey(const Key('manual-payout-amount')))
            .controller!
            .text,
        '100.00');

    // 金额与报价不一致时：旧报价不再展示，也不允许确认提交。
    await tester.enterText(
        find.byKey(const Key('manual-payout-amount')), '20');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manual-payout-confirm')), findsNothing,
        reason: '提交必须以最终输入为准：旧报价不得被用来提交');
    expect(find.textContaining('金额已修改'), findsOneWidget);

    await flow.tap(tester, find.byKey(const Key('manual-quote-create')));
    expect(quoteAmounts, ['10.000000', '20.000000'],
        reason: '重新报价必须按最终输入金额请求服务端');
    expect(find.byKey(const Key('manual-payout-confirm')), findsOneWidget);
  });

  testWidgets('需求12：确认有效期与过期校验都只认服务端 expires_at（含 24 小时档）',
      (tester) async {
    final now = DateTime.now().toUtc();
    final almost24h = now.add(const Duration(hours: 23, minutes: 59));
    await pumpPayout(tester, quoteBody: {
      ...fixtures.quote,
      'created_at': now.toIso8601String(),
      'expires_at': almost24h.toIso8601String(),
    });
    await createQuote(tester, '10');
    expect(find.text('确认有效期'), findsOneWidget);
    final formatted = almost24h
        .toLocal()
        .toIso8601String()
        .substring(0, 16)
        .replaceFirst('T', ' ');
    expect(find.text(formatted), findsOneWidget,
        reason: '页面只展示服务端权威的过期时间，不自己编造 5 分钟/24 小时');
    final confirm = tester.widget<CupertinoButton>(
        find.byKey(const Key('manual-payout-confirm')));
    expect(confirm.onPressed, isNotNull,
        reason: '未过期就不能被本地 5 分钟假设提前拦下');
  });

  testWidgets('需求12：过期报价展示一致且不能确认', (tester) async {
    final expires = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await pumpPayout(tester, quoteBody: {
      ...fixtures.quote,
      'created_at':
          expires.subtract(const Duration(minutes: 5)).toIso8601String(),
      'expires_at': expires.toIso8601String(),
    });
    await createQuote(tester, '10');
    expect(find.textContaining('本次报价已过期'), findsOneWidget);
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('manual-payout-confirm')))
            .onPressed,
        isNull,
        reason: '过期的服务端有效期必须与「不能确认」严格一致');
  });

  testWidgets('需求13：确认提现后只以「处理中」订单呈现一次', (tester) async {
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return flow.json(fixtures.binding);
      }
      if (request.url.path.contains('/payout-quotes/')) {
        return flow.json(fixtures.quote);
      }
      if (request.method == 'POST') return flow.json(fixtures.payout);
      return flow.json({});
    });
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin('payout', {'quote_id': 'quote'});
    await tester.pumpWidget(CupertinoApp(
        home: ManualWalletPage(
            client: api, section: ManualWalletSection.payout)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('manual-quote-digest')), findsOneWidget,
        reason: '确认前展示确认订单');
    await flow.tap(tester, find.byKey(const Key('manual-payout-confirm')));

    // 确认后：确认订单消失，只留下一条「处理中」订单。
    expect(find.byKey(const Key('manual-payout-hero')), findsNothing);
    expect(find.byKey(const Key('manual-quote-digest')), findsNothing);
    expect(find.text('收款地址'), findsNothing);
    expect(find.byKey(const Key('manual-payout-status-hero')), findsOneWidget);
    expect(find.text('状态'), findsOneWidget,
        reason: '同一笔只能呈现一次（此前确认订单与处理中订单会同时出现）');
    expect(find.text('requested'), findsOneWidget);
    expect(find.byKey(const Key('manual-payout-confirm')), findsNothing);
  });

  testWidgets('窄屏不溢出：iPhone SE 宽度下提现页无异常', (tester) async {
    tester.view.physicalSize = const Size(640, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpPayout(tester);
    await createQuote(tester, '10');
    expect(tester.takeException(), isNull);
  });
}
