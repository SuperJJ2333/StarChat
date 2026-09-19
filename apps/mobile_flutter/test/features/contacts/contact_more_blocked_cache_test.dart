import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/permissions/blocked_contacts.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';

/// 微信级加载模型（2026-09-19 审计）：好友设置页的黑名单开关原先只由网络
/// `blockList()` 决定 —— 断网或请求未回来时 `blocked == null`，开关被禁用，
/// 明明本地已经有服务端来源的投影却不让用户看到真实状态。
final class _BlockGateway implements ContactsGateway {
  @override
  Future<Map<String, dynamic>> blockList() async =>
      throw StateError('offline');

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<dynamic>.value();
}

/// 权威接口长期不返回（弱网/在途）：用来验证"首次展示"不依赖网络往返。
final class _PendingBlockGateway implements ContactsGateway {
  @override
  Future<Map<String, dynamic>> blockList() =>
      Completer<Map<String, dynamic>>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<dynamic>.value();
}

const _contact = ContactDetails(
    userId: 'u1',
    username: 'xiaohong',
    matrixUserId: '@x:example',
    nickname: '小鸿');

void main() {
  setUp(blockedContacts.clear);
  tearDown(blockedContacts.clear);

  testWidgets('已有服务端黑名单投影：断网时开关仍是已知状态（可用且为开）',
      (tester) async {
    blockedContacts.replaceAll(const ['u1'], fromServer: true);

    await tester.pumpWidget(CupertinoApp(
        home: ContactMorePage(api: _BlockGateway(), contact: _contact)));
    await tester.pumpAndSettle();

    final toggle = tester
        .widget<CupertinoSwitch>(find.byKey(const Key('contact-block-switch')));
    expect(toggle.value, isTrue, reason: '本地投影已拉黑 → 开关应为开');
    expect(toggle.onChanged, isNotNull, reason: '已知状态 → 允许继续操作');
  });

  testWidgets('从未读过服务端：断网时不冒充已知状态（开关仍禁用）',
      (tester) async {    await tester.pumpWidget(CupertinoApp(
        home: ContactMorePage(api: _BlockGateway(), contact: _contact)));
    await tester.pumpAndSettle();

    final toggle = tester
        .widget<CupertinoSwitch>(find.byKey(const Key('contact-block-switch')));
    expect(toggle.value, isFalse);
    expect(toggle.onChanged, isNull, reason: '没有权威/投影来源时不得用默认 false 冒充');
  });

  testWidgets('权威接口在途：有投影时立即显示已知状态（不等网络往返）',
      (tester) async {
    blockedContacts.replaceAll(const ['u1'], fromServer: true);

    await tester.pumpWidget(CupertinoApp(
        home: ContactMorePage(api: _PendingBlockGateway(), contact: _contact)));
    await tester.pump();

    final toggle = tester
        .widget<CupertinoSwitch>(find.byKey(const Key('contact-block-switch')));
    expect(toggle.value, isTrue,
        reason: '请求还没回来时也要先用本地投影显示"已拉黑"');
    expect(toggle.onChanged, isNotNull);
  });
}
