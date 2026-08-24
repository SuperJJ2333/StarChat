import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/session_gate.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/ui/components/network_status_capsule.dart';

final class GateBusiness implements BusinessSessionGateway {
  GateBusiness(this.result);
  BusinessSessionRestore result;
  @override
  Future<String?> currentMatrixUserId() async => '@alice:matrix.localhost';
  @override
  Future<void> logout() async {}
  @override
  Future<BusinessSessionRestore> restoreSession() async => result;
}

final class GateMatrix implements MatrixSessionGateway {
  GateMatrix(this.isLoggedIn);
  @override
  bool isLoggedIn;
  @override
  String? get userId => '@alice:matrix.localhost';
  @override
  String? get deviceId => 'DEVICE';
  @override
  Future<void> suspend() async {}
  @override
  Future<void> resetLocalStore() async => isLoggedIn = false;
  Future<void> logout() async => isLoggedIn = false;
  @override
  Future<void> sync() async {}
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Widget appFor(SessionBootstrapController controller) => CupertinoApp(
      home: SessionGate(
        controller: controller,
        unauthenticatedBuilder: (_) => const Text('LOGIN'),
        authenticatedBuilder: (_) => const Text('HOME'),
      ),
    );

void main() {
  testWidgets('loading state never flashes the login form', (tester) async {
    final controller = SessionBootstrapController(
      business: GateBusiness(BusinessSessionRestore.absent),
      matrix: GateMatrix(false),
    );
    await tester.pumpWidget(appFor(controller));
    expect(find.text('正在恢复登录状态…'), findsOneWidget);
    expect(find.text('LOGIN'), findsNothing);
  });

  testWidgets('authenticated state directly renders home', (tester) async {
    final controller = SessionBootstrapController(
      business: GateBusiness(BusinessSessionRestore.authenticated),
      matrix: GateMatrix(true),
    );
    await controller.bootstrap();
    await tester.pumpWidget(appFor(controller));
    expect(find.text('HOME'), findsOneWidget);
    expect(find.text('LOGIN'), findsNothing);
  });

  testWidgets('offline authenticated state keeps home and shows banner',
      (tester) async {
    final business = GateBusiness(BusinessSessionRestore.offline);
    final controller = SessionBootstrapController(
      business: business,
      matrix: GateMatrix(true),
    );
    await controller.bootstrap();
    await tester.pumpWidget(appFor(controller));
    expect(find.text('HOME'), findsOneWidget);
    expect(find.byType(Stack), findsWidgets);
    expect(find.byType(NetworkStatusCapsule), findsOneWidget);
    final offlinePosition = tester.getTopLeft(find.text('HOME'));

    business.result = BusinessSessionRestore.authenticated;
    await tester.tap(find.byType(NetworkStatusCapsule));
    await tester.pumpAndSettle();
    expect(find.byType(NetworkStatusCapsule), findsNothing);
    expect(tester.getTopLeft(find.text('HOME')), offlinePosition);
  });

  testWidgets('unauthenticated state renders login content', (tester) async {
    final controller = SessionBootstrapController(
      business: GateBusiness(BusinessSessionRestore.absent),
      matrix: GateMatrix(false),
    );
    await controller.bootstrap();
    await tester.pumpWidget(appFor(controller));
    expect(find.text('LOGIN'), findsOneWidget);
  });

  testWidgets('explicit logout requires confirmation', (tester) async {
    var logoutCalls = 0;
    await tester.pumpWidget(CupertinoApp(
      home: SettingsPage(
        api: BusinessApiClient(
          baseUri: Uri.parse('https://api.example.test'),
          sessionStore: SecureSessionStore(_MemoryStore()),
        ),
        onLogout: () async => logoutCalls++,
      ),
    ));

    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    await tester.tap(find.text('退出登录').last);
    await tester.pumpAndSettle();

    expect(logoutCalls, 1);
  });
}
