import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart'
    show MatrixNewDeviceRecoveryRequired;
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/session_gate.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/ui/components/network_status_capsule.dart';

final class GateBusiness implements BusinessSessionGateway {
  GateBusiness(this.result);
  BusinessSessionRestore result;
  String? matrixUserId = '@alice:matrix.localhost';
  @override
  Future<String?> currentMatrixUserId() async => matrixUserId;
  @override
  Future<BusinessSessionRevocation?> clearLocalSession() async => null;
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
  Future<void> clearLocalChatData() async => isLoggedIn = false;
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

Widget appFor(SessionBootstrapController controller,
        {Future<void> Function()? onConfirmNewDeviceRecovery}) =>
    CupertinoApp(
      home: SessionGate(
        controller: controller,
        onConfirmNewDeviceRecovery: onConfirmNewDeviceRecovery,
        unauthenticatedBuilder: (_) => const Text('LOGIN'),
        authenticatedBuilder: (_) => const Text('HOME'),
      ),
    );

void main() {
  testWidgets('retained identity recovery requires a visible confirmation',
      (tester) async {
    final matrix = GateMatrix(false);
    final controller = SessionBootstrapController(
      business: GateBusiness(BusinessSessionRestore.authenticated),
      matrix: matrix,
      restoreLocalMatrixSession: (_) async =>
          throw const MatrixNewDeviceRecoveryRequired(),
    );
    await controller.bootstrap();
    var confirmations = 0;
    await tester
        .pumpWidget(appFor(controller, onConfirmNewDeviceRecovery: () async {
      confirmations++;
      matrix.isLoggedIn = true;
    }));

    expect(find.text('旧聊天数据将保留'), findsOneWidget);
    expect(find.text('保留旧库并建立新设备'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
    expect(confirmations, 0);
    await tester.tap(find.text('保留旧库并建立新设备'));
    await tester.pumpAndSettle();
    expect(confirmations, 1);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('deferring retained recovery keeps Business and Matrix state',
      (tester) async {
    final business = GateBusiness(BusinessSessionRestore.authenticated);
    final matrix = GateMatrix(false);
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
      restoreLocalMatrixSession: (_) async =>
          throw const MatrixNewDeviceRecoveryRequired(),
    );
    await controller.bootstrap();
    var confirmations = 0;
    await tester.pumpWidget(appFor(controller,
        onConfirmNewDeviceRecovery: () async => confirmations++));

    await tester.tap(find.text('暂不恢复'));
    await tester.pumpAndSettle();
    expect(find.text('旧数据已保留，您可以稍后继续恢复。'), findsOneWidget);
    expect(confirmations, 0);
    expect(business.result, BusinessSessionRestore.authenticated);
    expect(matrix.isLoggedIn, isFalse);
    await tester.tap(find.text('继续恢复'));
    await tester.pumpAndSettle();
    expect(find.text('保留旧库并建立新设备'), findsOneWidget);
    expect(confirmations, 0);
  });

  testWidgets('system back does not confirm cold-start identity recovery',
      (tester) async {
    final matrix = GateMatrix(false);
    final controller = SessionBootstrapController(
      business: GateBusiness(BusinessSessionRestore.authenticated),
      matrix: matrix,
      restoreLocalMatrixSession: (_) async =>
          throw const MatrixNewDeviceRecoveryRequired(),
    );
    await controller.bootstrap();
    var confirmations = 0;
    await tester.pumpWidget(appFor(controller,
        onConfirmNewDeviceRecovery: () async => confirmations++));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(confirmations, 0);
    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);
    expect(matrix.isLoggedIn, isFalse);
    expect(find.text('保留旧库并建立新设备'), findsOneWidget);
  });

  testWidgets('retry uses original identity without confirming a new device',
      (tester) async {
    final matrix = GateMatrix(false);
    var restores = 0;
    final controller = SessionBootstrapController(
      business: GateBusiness(BusinessSessionRestore.authenticated),
      matrix: matrix,
      restoreLocalMatrixSession: (_) async {
        if (++restores == 1) throw const MatrixNewDeviceRecoveryRequired();
        matrix.isLoggedIn = true;
      },
    );
    await controller.bootstrap();
    var confirmations = 0;
    await tester.pumpWidget(appFor(controller,
        onConfirmNewDeviceRecovery: () async => confirmations++));

    await tester.tap(find.text('重试原身份'));
    await tester.pumpAndSettle();

    expect(restores, 2);
    expect(confirmations, 0);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets(
      'failed new-device completion cannot turn retry into authenticated chat',
      (tester) async {
    final matrix = GateMatrix(false);
    var restores = 0;
    final controller = SessionBootstrapController(
      business: GateBusiness(BusinessSessionRestore.authenticated),
      matrix: matrix,
      restoreLocalMatrixSession: (_) async {
        if (++restores == 1) throw const MatrixNewDeviceRecoveryRequired();
      },
    );
    addTearDown(controller.dispose);
    await controller.bootstrap();
    await tester
        .pumpWidget(appFor(controller, onConfirmNewDeviceRecovery: () async {
      matrix.isLoggedIn = true;
      throw StateError('broker completion failed after Matrix token login');
    }));

    await tester.tap(find.text('保留旧库并建立新设备'));
    await tester.pumpAndSettle();
    expect(find.text('HOME'), findsNothing);
    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);

    await tester.tap(find.text('重试原身份'));
    await tester.pumpAndSettle();
    expect(restores, 2);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('failed Business binding keeps confirmation available on retry',
      (tester) async {
    final business = GateBusiness(BusinessSessionRestore.authenticated);
    final matrix = GateMatrix(false);
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
      restoreLocalMatrixSession: (_) async =>
          throw const MatrixNewDeviceRecoveryRequired(),
    );
    addTearDown(controller.dispose);
    await controller.bootstrap();
    await tester
        .pumpWidget(appFor(controller, onConfirmNewDeviceRecovery: () async {
      matrix.isLoggedIn = true;
      business.matrixUserId = null;
      throw StateError('Business binding failed');
    }));

    await tester.tap(find.text('保留旧库并建立新设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试原身份'));
    await tester.pumpAndSettle();

    expect(controller.state.status, SessionBootstrapStatus.recoveryRequired);
    expect(find.text('保留旧库并建立新设备'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
  });

  testWidgets('loading state never flashes the login form', (tester) async {
    final controller = SessionBootstrapController(
      business: GateBusiness(BusinessSessionRestore.absent),
      matrix: GateMatrix(false),
    );
    await tester.pumpWidget(appFor(controller));
    expect(find.text('消息'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
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
    expect(logoutCalls, 0);
    expect(find.text('是否删除本机聊天记录？'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(logoutCalls, 1);
  });
}
