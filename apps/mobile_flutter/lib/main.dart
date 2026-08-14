import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';

import 'app_home.dart';
import 'core/app_config.dart';
import 'core/business_api_client.dart';
import 'core/session_bootstrap_controller.dart';
import 'core/session_store.dart';
import 'features/auth/login_page.dart';
import 'features/matrix/matrix_client_factory.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'session_gate.dart';
import 'ui/theme/wechat_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = SecureSessionStore();
  final api = BusinessApiClient(
    baseUri: Uri.parse(AppConfig.businessApiBaseUrl),
    sessionStore: store,
  );
  final matrixFactory = MatrixClientFactory(sessionStore: store);
  final sdkClient = await matrixFactory.create();
  final matrix = MatrixSdkE2eeClient(
    sdkClient,
    homeserver: Uri.parse(AppConfig.matrixHomeserver),
    resetClient: matrixFactory.reset,
  );
  final session = SessionBootstrapController(business: api, matrix: matrix);
  final gate = SessionGate(
    controller: session,
    unauthenticatedBuilder: (_) => LoginPage(
      api: api,
      onLogin: (username, password) async {
        await api.login(
          username: username,
          password: password,
          deviceKey: 'flutter-${DateTime.now().millisecondsSinceEpoch}',
          deviceName: '六合通移动端',
        );
        try {
          await matrix.login('@$username:matrix.localhost', password);
          await matrix.sync();
        } on MatrixException {
          await api.logout();
          rethrow;
        }
      },
      onAuthenticated: session.bootstrap,
    ),
    authenticatedBuilder: (_) => AppHome(
      api: api,
      matrix: matrix,
      onLogout: session.logout,
    ),
  );
  runApp(LiuhetongApp(home: gate));
  unawaited(session.bootstrap());
}

final class LiuhetongApp extends StatelessWidget {
  const LiuhetongApp({super.key, required this.home});

  final Widget home;

  @override
  Widget build(BuildContext context) => CupertinoApp(
        title: '六合通',
        theme: WeChatTheme.build(Brightness.light),
        builder: (context, child) => CupertinoTheme(
          data: WeChatTheme.build(MediaQuery.platformBrightnessOf(context)),
          child: child!,
        ),
        home: home,
      );
}

final class ClientComposition {
  ClientComposition({required this.sessionStore, required this.matrixClient});
  final SecureSessionStore sessionStore;
  final MatrixE2eeClient matrixClient;
}
