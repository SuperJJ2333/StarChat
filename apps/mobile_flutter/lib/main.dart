import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_home.dart';
import 'core/app_config.dart';
import 'core/business_api_client.dart';
import 'core/session_bootstrap_controller.dart';
import 'core/session_store.dart';
import 'features/auth/login_controller.dart';
import 'features/auth/authentication_flow.dart';
import 'features/matrix/matrix_client_factory.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'session_gate.dart';
import 'ui/theme/wechat_theme.dart';
import 'ui/theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final themeController = ThemeController(
    store: SharedPreferencesThemePreferenceStore(
      await SharedPreferences.getInstance(),
    ),
  );
  await themeController.load();
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
    unauthenticatedBuilder: (_) => AuthenticationFlow(
      api: api,
      onLogin: (username, password) async {
        final login = DualDomainLoginService(
          business: api,
          matrix: matrix,
          deviceKey: () => 'flutter-${DateTime.now().millisecondsSinceEpoch}',
        );
        await login.login(username, password);
      },
      onAuthenticated: session.bootstrap,
    ),
    authenticatedBuilder: (_) => AppHome(
      api: api,
      matrix: matrix,
      onLogout: session.logout,
      themeController: themeController,
    ),
  );
  runApp(LiuhetongApp(home: gate, themeController: themeController));
  unawaited(session.bootstrap());
}

final class LiuhetongApp extends StatelessWidget {
  const LiuhetongApp({
    super.key,
    required this.home,
    required this.themeController,
  });

  final Widget home;
  final ThemeController themeController;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: themeController,
        builder: (context, _) => CupertinoApp(
          title: '畅聊',
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          theme: WeChatTheme.build(themeController.resolve(
            WidgetsBinding.instance.platformDispatcher.platformBrightness,
          )),
          builder: (context, child) => CupertinoTheme(
            data: WeChatTheme.build(
              themeController.resolve(MediaQuery.platformBrightnessOf(context)),
            ),
            child: child!,
          ),
          home: home,
        ),
      );
}

final class ClientComposition {
  ClientComposition({required this.sessionStore, required this.matrixClient});
  final SecureSessionStore sessionStore;
  final MatrixE2eeClient matrixClient;
}
