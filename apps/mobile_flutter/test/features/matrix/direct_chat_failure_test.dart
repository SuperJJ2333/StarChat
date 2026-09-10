import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_failure.dart';

/// 问题三：好友页“发消息”失败（“无法打开加密会话”兜底文案）。
/// 失败必须按实际类别分级展示，并提供不暴露内部细节的重试入口。
void main() {
  test('同步未完成（TimeoutException）归为 syncPending', () {
    final kind = classifyDirectChatFailure(
        TimeoutException('canonical room has not reached sync'));
    expect(kind, DirectChatFailureKind.syncPending);
    expect(
      describeDirectChatFailure(TimeoutException('lag')),
      '对方会话还在同步中，请稍后重试。',
    );
  });

  test('好友映射缺失（contact is no longer a current friend）归为 contactUnavailable',
      () {
    final kind = classifyDirectChatFailure(
        StateError('The contact is no longer a current friend'));
    expect(kind, DirectChatFailureKind.contactUnavailable);
    expect(
      describeDirectChatFailure(
          StateError('The contact is no longer a current friend')),
      '该好友已不在你的好友列表。',
    );
  });

  test('其它失败归为 networkOrOther，不泄漏内部错误细节', () {
    expect(
      classifyDirectChatFailure(StateError('Canonical room does not match')),
      DirectChatFailureKind.networkOrOther,
    );
    final message = describeDirectChatFailure(Exception('token expired x'));
    expect(message, '网络异常，请稍后重试。');
    expect(message.contains('token'), isFalse);
  });

  testWidgets('失败弹窗按类别展示文案并提供重试', (tester) async {
    var retries = 0;
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(
          child: CupertinoButton(
            onPressed: () => showDirectChatFailureDialog(
              tester.element(find.byType(CupertinoButton)),
              StateError('Direct chat must be encrypted'),
              onRetry: () async => retries++,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('无法打开加密会话'), findsOneWidget, reason: '保留原错误标题以便用户/客服对齐');
    expect(find.text('网络异常，请稍后重试。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget, reason: '可恢复失败必须提供重试入口');

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(retries, 1, reason: '重试先收起弹窗再重新执行打开流程');
    expect(find.text('无法打开加密会话'), findsNothing);
  });

  testWidgets('好友已删除的失败不提供重试（重试必然再失败）', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(
          child: CupertinoButton(
            onPressed: () => showDirectChatFailureDialog(
              tester.element(find.byType(CupertinoButton)),
              StateError('The contact is no longer a current friend'),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('该好友已不在你的好友列表。'), findsOneWidget);
    expect(find.text('重试'), findsNothing, reason: '映射缺失类失败重试无意义');
  });
}
