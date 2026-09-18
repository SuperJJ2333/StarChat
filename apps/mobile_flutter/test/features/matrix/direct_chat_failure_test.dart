import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/features/matrix/coordinated_direct_chat.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_failure.dart';
import 'package:matrix/matrix.dart';

/// 问题三：好友页“发消息”失败（“无法打开加密会话”兜底文案）。
/// 失败必须按实际类别分级展示，并提供不暴露内部细节的重试入口。
void main() {
  test('known canonical synchronization pending is syncPending', () {
    final kind = classifyDirectChatFailure(const DirectRoomPendingException());
    expect(kind, DirectChatFailureKind.syncPending);
    expect(
      describeDirectChatFailure(const DirectRoomPendingException()),
      '对方会话还在同步中，请稍后重试。',
    );
  });

  test('a generic timeout is a weak-network signal, not sync pending', () {
    final timeout = TimeoutException('request elapsed');
    expect(classifyDirectChatFailure(timeout), DirectChatFailureKind.weak);
    expect(describeDirectChatFailure(timeout), '网络不稳定，请稍候。');
    expect(titleDirectChatFailure(timeout), '网络不稳定');
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
    expect(message, '网络不稳定，请稍候。');
    expect(message.contains('token'), isFalse);
  });

  test('Offline First 分类词表：offline / weak / server / crypto 各自成句', () {
    expect(
      describeDirectChatFailure(const SocketException('network unreachable')),
      '当前没有网络，消息将在恢复后同步。',
    );
    expect(titleDirectChatFailure(const SocketException('unreachable')),
        '当前没有网络');
    expect(describeDirectChatFailure(TimeoutException('slow')),
        '网络不稳定，请稍候。');
    expect(
      describeDirectChatFailure(const BusinessApiException(
          statusCode: 503, code: 'UNAVAILABLE', message: 'down')),
      '服务器连接失败，请稍后重试。',
    );
    expect(titleDirectChatFailure(const BusinessApiException(
        statusCode: 500, code: 'BOOM', message: 'boom')), '服务器连接失败');
    expect(
      describeDirectChatFailure(StateError('Direct chat must be encrypted')),
      '安全会话初始化失败，请稍后重试。',
    );
    expect(titleDirectChatFailure(StateError('规范私聊成员或加密状态尚未就绪')),
        '安全会话初始化失败');
    // 产品要求：任何分类都不再出现旧的“无法打开加密会话”口径。
    for (final error in <Object>[
      const SocketException('x'),
      TimeoutException('x'),
      StateError('Direct chat must be encrypted'),
      const BusinessApiException(statusCode: 500, code: 'X', message: 'x'),
      Exception('other'),
    ]) {
      expect(titleDirectChatFailure(error).contains('无法打开加密会话'), isFalse);
      expect(describeDirectChatFailure(error).contains('无法打开加密会话'), isFalse);
    }
  });

  test('only transport failures are presented as offline', () {
    expect(
      classifyDirectChatFailure(const SocketException('network unreachable')),
      DirectChatFailureKind.offline,
    );
    expect(
      describeDirectChatFailure(const SocketException('network unreachable')),
      '当前没有网络，消息将在恢复后同步。',
    );
    expect(
      classifyDirectChatFailure(http.ClientException('connection refused')),
      DirectChatFailureKind.offline,
    );
    for (final status in [401, 403]) {
      final matrixError =
          MatrixException(http.Response('{"errcode":"M_FORBIDDEN"}', status));
      expect(
        classifyDirectChatFailure(matrixError),
        status == 401
            ? DirectChatFailureKind.authenticationRequired
            : DirectChatFailureKind.permissionDenied,
        reason: 'HTTP authorization failures are not evidence of offline',
      );
    }
  });

  test('business authorization failures are specific and not retryable', () {
    final auth = const BusinessApiException(
        statusCode: 401, code: 'AUTH_REQUIRED', message: 'auth');
    final denied = const BusinessApiException(
        statusCode: 403, code: 'FORBIDDEN', message: 'forbidden');
    expect(classifyDirectChatFailure(auth),
        DirectChatFailureKind.authenticationRequired);
    expect(describeDirectChatFailure(auth), '登录状态已失效，请重新登录。');
    expect(classifyDirectChatFailure(denied),
        DirectChatFailureKind.permissionDenied);
    expect(describeDirectChatFailure(denied), '你没有权限打开此会话。');
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

    // 加密会话未就绪 → 专门的“安全会话初始化失败”，且不再使用旧口径。
    expect(find.text('安全会话初始化失败'), findsOneWidget);
    expect(find.text('安全会话初始化失败，请稍后重试。'), findsOneWidget);
    expect(find.text('无法打开加密会话'), findsNothing,
        reason: '产品要求禁止再显示旧标题');
    expect(find.text('重试'), findsOneWidget, reason: '可恢复失败必须提供重试入口');

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(retries, 1, reason: '重试先收起弹窗再重新执行打开流程');
    expect(find.text('安全会话初始化失败'), findsNothing);
  });

  testWidgets('离线失败给出“等待恢复同步”的说明并保留重试', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(
          child: CupertinoButton(
            onPressed: () => showDirectChatFailureDialog(
              tester.element(find.byType(CupertinoButton)),
              const SocketException('no route to host'),
              onRetry: () async {},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('当前没有网络'), findsOneWidget);
    expect(find.text('当前没有网络，消息将在恢复后同步。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
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

  testWidgets('authentication and permission failures do not offer retry',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(
          child: CupertinoButton(
            onPressed: () => showDirectChatFailureDialog(
              tester.element(find.byType(CupertinoButton)),
              const BusinessApiException(
                  statusCode: 403, code: 'FORBIDDEN', message: 'forbidden'),
              onRetry: () async {},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('你没有权限打开此会话。'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });
}
