import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/session_gate.dart';
import 'package:liuhetong_mobile/ui/motion/motion_page_route.dart';

final class _Business
    implements BusinessSessionGateway, BusinessSessionMonitor {
  BusinessSessionRestore result = BusinessSessionRestore.authenticated;
  String matrixId = '@alice:test';
  final events = StreamController<BusinessSessionInvalidation>.broadcast();
  @override
  Stream<BusinessSessionInvalidation> get sessionInvalidations => events.stream;
  @override
  int get sessionEpoch => 0;
  @override
  Future<void> checkSessionValidity() async {}
  @override
  Future<String?> currentMatrixUserId() async => matrixId;
  @override
  Future<BusinessSessionRevocation?> clearLocalSession() async => null;
  @override
  Future<BusinessSessionRestore> restoreSession() async => result;
}

final class _Matrix implements MatrixSessionGateway {
  @override
  bool isLoggedIn = true;
  @override
  String? userId = '@alice:test';
  @override
  String? get deviceId => 'DEVICE';
  @override
  Future<void> suspend() async {}
  @override
  Future<void> clearLocalChatData() async => isLoggedIn = false;
  @override
  Future<void> sync() async {}
}

Widget _app(SessionBootstrapController session) => CupertinoApp(
      home: SessionGate(
        controller: session,
        authenticatedBuilder: (context) => CupertinoPageScaffold(
          child: Center(
              child: CupertinoButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
                MotionPageRoute<void>(
                    builder: (_) => const CupertinoPageScaffold(
                        child: Center(child: Text('旧账号子页'))))),
            child: const Text('打开子页'),
          )),
        ),
        unauthenticatedBuilder: (_) =>
            const CupertinoPageScaffold(child: Center(child: Text('登录页'))),
      ),
    );

void main() {
  testWidgets('logout clears an authenticated root route before login',
      (tester) async {
    final business = _Business();
    final session =
        SessionBootstrapController(business: business, matrix: _Matrix());
    addTearDown(() {
      session.dispose();
      business.events.close();
    });
    await session.bootstrap();
    await tester.pumpWidget(_app(session));
    await tester.tap(find.text('打开子页'));
    await tester.pumpAndSettle();
    expect(find.text('旧账号子页'), findsOneWidget);

    unawaited(session.logout());
    await tester.pumpAndSettle();
    expect(find.text('旧账号子页'), findsNothing);
    expect(find.text('登录页'), findsOneWidget);
  });

  testWidgets('SESSION_REPLACED clears root route before showing reason',
      (tester) async {
    final business = _Business();
    final matrix = _Matrix();
    final session =
        SessionBootstrapController(business: business, matrix: matrix);
    addTearDown(() {
      session.dispose();
      business.events.close();
    });
    await session.bootstrap();
    await tester.pumpWidget(_app(session));
    await tester.tap(find.text('打开子页'));
    await tester.pumpAndSettle();
    business.events.add(
        const BusinessSessionInvalidation(epoch: 0, code: 'SESSION_REPLACED'));
    await tester.pumpAndSettle();
    expect(find.text('旧账号子页'), findsNothing);
    expect(find.text('账号已退出'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('登录页'), findsOneWidget);
    business.matrixId = '@bob:test';
    matrix.userId = '@bob:test';
    await session.bootstrap();
    await tester.pumpAndSettle();
    expect(find.text('旧账号子页'), findsNothing);
    expect(find.text('打开子页'), findsOneWidget);
    session.setForeground(false);
  });

  testWidgets('offline to online transition keeps the current root page',
      (tester) async {
    final business = _Business()..result = BusinessSessionRestore.offline;
    final session =
        SessionBootstrapController(business: business, matrix: _Matrix());
    addTearDown(() {
      session.dispose();
      business.events.close();
    });
    await session.bootstrap();
    await tester.pumpWidget(_app(session));
    await tester.tap(find.text('打开子页'));
    await tester.pumpAndSettle();
    await session.checkSessionValidity();
    await tester.pumpAndSettle();
    expect(find.text('旧账号子页'), findsOneWidget);
    session.setForeground(false);
  });
}
