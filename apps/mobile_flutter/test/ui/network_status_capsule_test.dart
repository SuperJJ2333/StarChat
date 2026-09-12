import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:liuhetong_mobile/core/app_connection_status.dart';
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/ui/components/network_status_capsule.dart';
import 'package:liuhetong_mobile/ui/components/operation_failure_dialog.dart';
import 'package:liuhetong_mobile/ui/components/wechat_scaffold.dart';

void main() {
  testWidgets('scaffold retains its cached child while showing offline status',
      (tester) async {
    final hub = AppConnectionStatusHub.shared;
    final owner = Object();
    hub.bind(
        owner, ValueNotifier(AppConnectionStatus.offline), (value) => value);
    await tester.pumpWidget(CupertinoApp(
        home: WeChatPageScaffold(title: '聊天', child: Text('已缓存会话'))));
    expect(find.text('已缓存会话'), findsOneWidget);
    expect(find.text('网络不可用，联网后自动重试'), findsOneWidget);
    hub.unbind(owner);
  });
  testWidgets('network explicit operation offers one cancel and retry dialog',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                onPressed: () => showRetryableOperationFailure(
                    context, const SocketException('offline')),
                child: const Text('操作')))));
    await tester.tap(find.text('操作'));
    await tester.pumpAndSettle();
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
  testWidgets('duplicate explicit operations share one root dialog only',
      (tester) async {
    Future<bool>? initiating;
    Future<bool>? duplicate;
    await tester.pumpWidget(CupertinoApp(
        home: Navigator(
            onGenerateRoute: (_) => CupertinoPageRoute(
                builder: (nestedContext) => CupertinoButton(
                    onPressed: () {
                      initiating = showRetryableOperationFailure(
                          nestedContext, const SocketException('offline'));
                      duplicate = showRetryableOperationFailure(
                          nestedContext, const SocketException('offline'));
                    },
                    child: const Text('发起操作'))))));
    await tester.tap(find.text('发起操作'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(await duplicate, isFalse);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(await initiating, isTrue);
  });
  testWidgets('offline capsule wraps at a narrow large-text width',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(CupertinoApp(
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(320, 640), textScaler: TextScaler.linear(1.5)),
            child: NetworkStatusCapsule(
                onRetry: () {}, label: '网络不可用，联网后自动重试'))));
    expect(find.text('网络不可用，联网后自动重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('permission and authentication failures are not labelled offline', () {
    expect(
        classifyOperationFailure(const BusinessApiException(
            statusCode: 403, code: 'FORBIDDEN', message: 'forbidden')),
        OperationFailureKind.other);
    expect(
        classifyOperationFailure(const BusinessApiException(
            statusCode: 401, code: 'UNAUTHENTICATED', message: 'auth')),
        OperationFailureKind.other);
    expect(
        classifyOperationFailure(const BusinessApiException(
            statusCode: 503, code: 'UNAVAILABLE', message: 'server')),
        OperationFailureKind.service);
    expect(
        classifyOperationFailure(const HttpExceptionWithStatus(403, 'expired')),
        OperationFailureKind.other);
    expect(classifyOperationFailure(const HttpExceptionWithStatus(404, 'gone')),
        OperationFailureKind.other);
    expect(classifyOperationFailure(const HttpExceptionWithStatus(503, 'down')),
        OperationFailureKind.service);
  });
}
