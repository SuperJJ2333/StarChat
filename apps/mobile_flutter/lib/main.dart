import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_home.dart';
import 'core/app_config.dart';
import 'core/business_api_client.dart';
import 'core/performance_metrics.dart';
import 'core/media_resource_policy.dart';
import 'features/matrix/media_cache.dart';
import 'core/installation_container_probe.dart';
import 'core/installation_marker.dart';
import 'core/installation_reconciler.dart';
import 'core/installation_startup_gate.dart';
import 'core/session_bootstrap_controller.dart';
import 'core/session_store.dart';
import 'features/auth/login_controller.dart';
import 'features/auth/authentication_flow.dart';
import 'features/matrix/call_ui_manager.dart' show callNavigatorKey;
import 'features/matrix/matrix_client_factory.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'features/matrix/matrix_home_page.dart';
import 'ui/foundation/changliao_icons.dart';
import 'features/matrix/matrix_recovery_service.dart';
import 'session_gate.dart';
import 'ui/theme/wechat_theme.dart';
import 'ui/theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaResourcePolicy(clearEncoded: clearMediaMemoryCaches).install();
  PerformanceMetrics.instance.startFrameObservation();
  await AppConfig.loadRuntimeVersion();
  final themeController = ThemeController(
    store: SharedPreferencesThemePreferenceStore(
      await SharedPreferences.getInstance(),
    ),
  );
  await themeController.load();
  final store = SecureSessionStore();
  final installationReconciler = InstallationReconciler(
    marker: SharedPreferencesInstallationMarker(
      await SharedPreferences.getInstance(),
    ),
    probe: FileSystemInstallationContainerProbe(),
    store: store,
  );

  Future<Widget> startApplication() async {
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
      suspendClient: matrixFactory.suspend,
      resumeClient: matrixFactory.create,
      selectClientAccount: matrixFactory.selectAccount,
      clearClientData: matrixFactory.clearLocalChatData,
      readContinuityMetadata: matrixFactory.continuityMetadata,
    );
    final session = SessionBootstrapController(
      business: api,
      matrix: matrix,
      securityLogger: matrix.securityLogger,
    );
    final recovery = MatrixRecoveryService(matrix);
    final installationDeviceKey = await store.registrationDeviceKey();
    final login = DualDomainLoginService(
      business: api,
      matrix: matrix,
      deviceKey: () => installationDeviceKey,
      retainedHomeserver: Uri.parse(AppConfig.matrixHomeserver),
      completeMatrixSession: () async {
        final credentials = await matrix.currentSessionCredentials();
        await api.completeMatrixSession(
            matrixAccessToken: credentials.token,
            matrixDeviceId: credentials.deviceId);
      },
    );
    final gate = SessionGate(
      controller: session,
      cachedMessagesBuilder: (_) => CupertinoTabScaffold(
        tabBar: CupertinoTabBar(
          items: const [
            BottomNavigationBarItem(
              icon: Icon(ChangliaoIcons.messagesFilled),
              label: '消息',
            ),
            BottomNavigationBarItem(
              icon: Icon(ChangliaoIcons.contacts),
              label: '通讯录',
            ),
            BottomNavigationBarItem(
              icon: Icon(ChangliaoIcons.discover),
              label: '发现',
            ),
            BottomNavigationBarItem(
                icon: Icon(ChangliaoIcons.me), label: '我'),
          ],
        ),
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
        onLogin: login.login,
        onConfirmMatrixAccountSwitch: login.confirmAccountSwitchAndLogin,
        onCancelMatrixAccountSwitch: login.cancelAccountSwitch,
        onAuthenticated: session.bootstrap,
      ),
      authenticatedBuilder: (_) => AppHome(
        api: api,
        matrix: matrix,
        onLogout: session.logout,
        themeController: themeController,
      ),
    );
    final bootstrap = session.bootstrap();
    unawaited(() async {
      try {
        await bootstrap;
        await session.runAuthenticatedBackground(
          prepare: () => recovery.restoreFromLocalSecureStorage(store),
          complete: matrix.syncIfActive,
        );
      } catch (_) {
        // The encrypted database and secure-store records remain intact. The
        // recovery UI can present a retry/import flow without exposing secrets.
      }
    }());
    return gate;
  }

  runApp(LiuhetongApp(
    home: InstallationStartupGate(
      reconcile: () async {
        final outcome = await installationReconciler.reconcile();
        if (outcome == InstallationResetOutcome.failed && kDebugMode) {
          debugPrint('[installation] generation reset did not settle');
        }
        return outcome;
      },
      start: startApplication,
    ),
    themeController: themeController,
  ));
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
