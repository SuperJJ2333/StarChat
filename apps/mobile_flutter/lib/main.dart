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
import 'features/matrix/call_ui_manager.dart' show callNavigatorKey;
import 'features/matrix/matrix_client_factory.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'features/matrix/matrix_home_page.dart';
import 'ui/foundation/changliao_icons.dart';
import 'session_gate.dart';
import 'ui/theme/wechat_theme.dart';
import 'ui/theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.loadRuntimeVersion();
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
  final matrixFactory = MatrixClientFactory(
    sessionStore: store,
    homeserver: Uri.parse(AppConfig.matrixHomeserver),
  );
  final sdkClient = await matrixFactory.create();
  final matrix = MatrixSdkE2eeClient(
    sdkClient,
    homeserver: Uri.parse(AppConfig.matrixHomeserver),
    reopenClient: matrixFactory.reopen,
    resetClient: matrixFactory.reset,
  );
  final session = SessionBootstrapController(business: api, matrix: matrix);
  final gate = SessionGate(
    controller: session,
    cachedMessagesBuilder: (_) => CupertinoTabScaffold(
      tabBar: CupertinoTabBar(items: const [
        BottomNavigationBarItem(
            icon: Icon(ChangliaoIcons.messagesFilled), label: '消息'),
        BottomNavigationBarItem(
            icon: Icon(ChangliaoIcons.contacts), label: '通讯录'),
        BottomNavigationBarItem(
            icon: Icon(ChangliaoIcons.discover), label: '发现'),
        BottomNavigationBarItem(icon: Icon(ChangliaoIcons.me), label: '我'),
      ]),
      tabBuilder: (_, index) => MatrixHomePage(
        api: api,
        matrix: matrix,
        themeController: themeController,
        onCreateGroup: () {},
        previewOnly: true,
      ),
    ),
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

final class LiuhetongApp extends StatefulWidget {
  const LiuhetongApp({
    super.key,
    required this.home,
    required this.themeController,
  });

  final Widget home;
  final ThemeController themeController;

  @override
  State<LiuhetongApp> createState() => _LiuhetongAppState();
}

/// Rebuilds the app shell whenever the system brightness changes so the
/// `system` theme preference tracks the OS dark-mode switch live.
final class _LiuhetongAppState extends State<LiuhetongApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.themeController,
        builder: (context, _) => CupertinoApp(
          navigatorKey: callNavigatorKey,
          title: '畅聊 ChatFlow',
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          theme: WeChatTheme.build(
            widget.themeController.resolve(
              WidgetsBinding.instance.platformDispatcher.platformBrightness,
            ),
          ),
          home: widget.home,
        ),
      );
}

final class ClientComposition {
  ClientComposition({required this.sessionStore, required this.matrixClient});
  final SecureSessionStore sessionStore;
  final MatrixE2eeClient matrixClient;
}
