import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/gallery_save_access.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_qr_exporter.dart';
import 'package:liuhetong_mobile/ui/components/wechat_gradient_divider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

/// 充值页 5 项 UI/交互修正（2026-09-18）：
/// 1. 删除「查看本次充值」；2. 地址压缩展示 + 文字靠左 + 复制仍为完整地址；
/// 3. 二维码「保存到本地」真实可用（权限/成功/失败可见）；4. 收款地址上方加
/// 共享渐隐分割线。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 进入态 Store 是进程内共享的：用例之间必须清空，否则缓存会泄漏。
    WalletEntryStores.disposeAll();
  });

  final official = fixtures.syntheticTronAddress();
  final source = 'T${'2' * 33}';
  final compactOfficial =
      '${official.substring(0, 8)}…${official.substring(official.length - 6)}';
  final compactSource =
      '${source.substring(0, 8)}…${source.substring(source.length - 6)}';

  Map<String, dynamic> depositBody() => {
        ...fixtures.intent,
        'source_address': source,
        'official_address': official,
        'expires_at': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .toIso8601String(),
      };

  Future<_FakeQrExporter> openDeposit(WidgetTester tester,
      {_FakeQrExporter? exporter}) async {
    final fake = exporter ?? _FakeQrExporter();
    final api = await flow.client(
        (request) async => flow.json(request.url.path.endsWith('/binding')
            ? {
                ...fixtures.binding,
                'address': source,
              }
            : request.method == 'POST'
                ? depositBody()
                : {}));
    await tester.pumpWidget(
        CupertinoApp(home: ManualWalletPage(client: api, qrExporter: fake)));
    await tester.pumpAndSettle();
    await flow.openDeposit(tester);
    await tester.enterText(
        find.byKey(const Key('manual-deposit-amount')), '10');
    await flow.tap(tester, find.byKey(const Key('manual-deposit-create')));
    return fake;
  }

  testWidgets('需求1：已生成的充值申请不再有「查看本次充值」按钮', (tester) async {
    await openDeposit(tester);
    expect(find.byKey(const Key('manual-deposit-hero')), findsOneWidget);
    expect(find.text('查看本次充值'), findsNothing,
        reason: '「查看本次充值」必须删除，且不得换名字变相保留');
    expect(find.text('下一步'), findsNothing,
        reason: '申请已在页面内自动恢复展示，不需要再点一次「查看/下一步」');
  });

  testWidgets('需求1补充：结果未确认的草稿仍可用同一幂等键重试（不是「查看」）',
      (tester) async {
    final posts = <String>[];
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/binding')) return flow.json(fixtures.binding);
      if (request.method == 'POST') {
        posts.add(request.headers['Idempotency-Key'] ?? '');
        throw Exception('offline');
      }
      return flow.json({});
    });
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.openDeposit(tester);
    await tester.enterText(
        find.byKey(const Key('manual-deposit-amount')), '10');
    await flow.tap(tester, find.byKey(const Key('manual-deposit-create')));
    expect(find.text('查看本次充值'), findsNothing);
    expect(find.text('重试本次充值'), findsOneWidget);
    await flow.tap(tester, find.text('重试本次充值'));
    expect(posts, hasLength(2));
    expect(posts[0], posts[1], reason: '重试必须复用同一幂等键');
  });

  testWidgets('需求2：地址压缩展示、文字靠左对齐、复制仍是完整地址', (tester) async {
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

    await openDeposit(tester);

    // 展示为压缩地址；完整 34 位地址不再作为一行文字出现。
    expect(find.text(compactSource), findsOneWidget);
    expect(find.text(compactOfficial), findsOneWidget);
    expect(find.text(source), findsNothing,
        reason: '完整地址不再撑开一行文本（复制 icon 因此能对齐）');
    expect(find.text(official), findsNothing);

    // 两行文字左对齐到同一列，并且都是左对齐排版（不再靠右/被截断）。
    final sourceText = tester.getRect(find.text(compactSource));
    final officialText = tester.getRect(find.text(compactOfficial));
    expect(sourceText.left, closeTo(officialText.left, 0.5),
        reason: '「转出钱包」「收款地址」文字必须靠左对齐同一列');
    expect(
        tester.widget<Text>(find.text(compactOfficial)).textAlign,
        TextAlign.left,
        reason: '地址文字必须左对齐');
    expect(officialText.left,
        greaterThanOrEqualTo(tester.getRect(find.text('收款地址')).right - 0.5));

    // 两处复制 icon 落在同一列（此前因地址长度不同而错位）。
    final sourceCopy = tester.getRect(find.byKey(const Key('manual-source-copy')));
    final officialCopy =
        tester.getRect(find.byKey(const Key('manual-official-copy')));
    expect(sourceCopy.left, closeTo(officialCopy.left, 0.5),
        reason: '复制 icon 必须对齐');

    await tester.ensureVisible(find.byKey(const Key('manual-official-copy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-official-copy')));
    await tester.pumpAndSettle();
    expect(copied, official, reason: '复制动作必须仍然是完整地址');
  });

  testWidgets('需求4：收款地址与上方文字信息之间是共享渐隐分割线', (tester) async {
    await openDeposit(tester);
    final divider = find.byKey(const Key('manual-deposit-address-divider'));
    expect(divider, findsOneWidget);
    expect(tester.widget(divider), isA<WeChatGradientDivider>(),
        reason: '必须复用仓库统一的渐隐分割线共享组件');
    expect(tester.getRect(divider).top,
        greaterThan(tester.getRect(find.text('转出钱包')).bottom));
    expect(tester.getRect(divider).bottom,
        lessThan(tester.getRect(find.text(compactOfficial)).top));
  });

  testWidgets('需求3：二维码保存到相册成功，保存的是完整收款地址', (tester) async {
    final fake = await openDeposit(tester);
    expect(find.byKey(const Key('manual-deposit-qr-save')), findsOneWidget);
    expect(find.text('保存到本地'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.square_arrow_down), findsOneWidget,
        reason: '保存到本地必须是图形 icon 可点的控件');

    await flow.tap(tester, find.byKey(const Key('manual-deposit-qr-save')));
    expect(fake.calls, [official]);
    expect(find.text('收款二维码已保存到相册'), findsOneWidget);
  });

  testWidgets('需求3：保存失败与无权限都必须给出可读原因，不静默', (tester) async {
    final fake = _FakeQrExporter();
    await openDeposit(tester, exporter: fake);

    fake.error = const WalletQrExportException('保存失败，请稍后重试');
    await flow.tap(tester, find.byKey(const Key('manual-deposit-qr-save')));
    expect(find.text('保存失败，请稍后重试'), findsOneWidget);
    expect(find.byKey(const Key('manual-feedback')), findsOneWidget);

    fake.error = GallerySavePermissionDenied();
    await flow.tap(tester, find.byKey(const Key('manual-deposit-qr-save')));
    expect(find.textContaining('相册写入权限'), findsOneWidget,
        reason: '没有权限时不得静默失败，必须给出可读原因');
  });

  testWidgets('需求3：保存过程中显示 loading 且控件禁用', (tester) async {
    final gate = Completer<void>();
    final fake = _FakeQrExporter(onSave: (_) => gate.future);
    await openDeposit(tester, exporter: fake);

    await tester.ensureVisible(find.byKey(const Key('manual-deposit-qr-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-deposit-qr-save')));
    await tester.pump();
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('manual-deposit-qr-save')))
            .onPressed,
        isNull,
        reason: '保存中必须禁用，避免重复写入相册');
    expect(
        find.descendant(
            of: find.byKey(const Key('manual-deposit-qr-save')),
            matching: find.byType(CupertinoActivityIndicator)),
        findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('收款二维码已保存到相册'), findsOneWidget);
  });

  testWidgets('窄屏不溢出：iPhone SE 宽度下充值申请页无异常', (tester) async {
    tester.view.physicalSize = const Size(640, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await openDeposit(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('manual-deposit-qr-save')), findsOneWidget);
  });
}

final class _FakeQrExporter implements WalletQrExporter {
  _FakeQrExporter({this.onSave});

  final Future<void> Function(String data)? onSave;
  final List<String> calls = [];
  Object? error;

  @override
  Future<void> saveQrCode(String data) async {
    calls.add(data);
    final failure = error;
    if (failure != null) throw failure;
    await onSave?.call(data);
  }
}
