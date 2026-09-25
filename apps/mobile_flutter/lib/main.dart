import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_home.dart';
import 'core/app_config.dart';
import 'core/chat_diagnostics.dart';
import 'core/chat_diagnostics_scope.dart';
import 'core/business_api_client.dart';
import 'core/performance_metrics.dart';
import 'core/performance_trace.dart';
import 'core/media_resource_policy.dart';
import 'features/matrix/media_cache.dart';
import 'core/installation_container_probe.dart';
import 'core/installation_marker.dart';
import 'core/installation_reconciler.dart';
import 'core/installation_startup_gate.dart';
import 'core/session_bootstrap_controller.dart';
import 'core/session_store.dart';
import 'features/auth/login_controller.dart';
import 'features/auth/login_stage_diagnostics.dart';
import 'features/auth/authentication_flow.dart';
import 'features/matrix/call_ui_manager.dart' show callNavigatorKey;
import 'features/matrix/duplicate_room_registry.dart';
import 'features/matrix/matrix_client_factory.dart';
import 'features/matrix/matrix_security_logger.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'features/matrix/matrix_home_page.dart';
import 'ui/foundation/changliao_icons.dart';
import 'features/matrix/matrix_recovery_service.dart';
import 'session_gate.dart';
import 'ui/motion/motion_preferences.dart';
import 'features/settings/voice_auto_play_preferences.dart';
import 'ui/theme/wechat_theme.dart';
import 'ui/theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  scheduleAppStartupFirstFrame();
  installChatErrorReporter();
  MediaResourcePolicy(clearEncoded: clearMediaMemoryCaches).install();
  PerformanceMetrics.instance.startFrameObservation();
  await AppConfig.loadRuntimeVersion();
  final themeController = ThemeController(
    store: SharedPreferencesThemePreferenceStore(
      await SharedPreferences.getInstance(),
    ),
  );
  await themeController.load();
  // BUG-08：「减少动态效果」是本地设置，启动即读取，并由根组件投影到
  // MediaQuery，使所有动效组件与页面转场在首帧就遵循该设置。
  motionPreferences.attachStore(SharedPreferencesMotionPreferenceStore(
    await SharedPreferences.getInstance(),
  ));
  await motionPreferences.load();
  // BUG-40：「语音自动连播」（默认开）本地设置启动即读取。
  voiceAutoPlayPreferences.attachStore(SharedPreferencesVoiceAutoPlayStore(
    await SharedPreferences.getInstance(),
  ));
  await voiceAutoPlayPreferences.load();
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
    // 本地生命周期诊断只记录加盐哈希后的标识，原始 Matrix user/device id 与
    // token 永远不出现在日志里。
    final diagnosticHasher =
        MatrixDiagnosticHasher(await store.diagnosticSalt());
    final matrixFactory = MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse(AppConfig.matrixHomeserver),
      diagnosticHasher: diagnosticHasher,
    );
    // Read/create the installation identifier before opening a DB handle so a
    // locked keychain cannot leave an initialized client behind on startup retry.
    final installationDeviceKey = await store.registrationDeviceKey();
    final sdkClient = await matrixFactory.create();
    final matrix = MatrixSdkE2eeClient(
      sdkClient,
      homeserver: Uri.parse(AppConfig.matrixHomeserver),
      suspendClient: matrixFactory.suspend,
      resumeClient: matrixFactory.create,
      selectClientAccount: matrixFactory.selectAccount,
      clearClientData: matrixFactory.clearLocalChatData,
      readContinuityMetadata: matrixFactory.continuityMetadata,
      rotateDeviceBinding: matrixFactory.rotateDeviceBinding,
      diagnosticHasher: diagnosticHasher,
      // 历史孤儿房间登记簿：primary 规则数据源 + 收敛台账（只记录不删除）。
      duplicateRooms: DuplicateRoomRegistry(),
    );
    late final DualDomainLoginService login;
    final session = SessionBootstrapController(
      business: api,
      matrix: matrix,
      securityLogger: matrix.securityLogger,
      restoreLocalMatrixSession: (identity) async {
        await store.validateLocalLoginStorage();
        await login.restoreAuthenticatedSession(identity);
      },
    );
    final recovery = MatrixRecoveryService(matrix);
    login = DualDomainLoginService(
      prepareLocalLogin: store.validateLocalLoginStorage,
      business: api,
      matrix: matrix,
      deviceKey: () => installationDeviceKey,
      retainedHomeserver: Uri.parse(AppConfig.matrixHomeserver),
      completeMatrixSession: () async {
        final credentialsWatch = kDebugMode ? (Stopwatch()..start()) : null;
        late final ({String token, String deviceId}) credentials;
        try {
          credentials = await matrix.currentSessionCredentials();
        } catch (error) {
          recordMatrixSessionFailure(
              MatrixSessionFailureBoundary.credentialsRead, error,
              durationMs: credentialsWatch?.elapsedMilliseconds);
          rethrow;
        }
        if (credentialsWatch != null) {
          recordMatrixSessionSuccess(
              MatrixSessionFailureBoundary.credentialsRead,
              durationMs: credentialsWatch.elapsedMilliseconds);
        }
        final requestWatch = kDebugMode ? (Stopwatch()..start()) : null;
        try {
          await api.completeMatrixSession(
              matrixAccessToken: credentials.token,
              matrixDeviceId: credentials.deviceId);
        } catch (error) {
          recordMatrixSessionFailure(
              MatrixSessionFailureBoundary.confirmationRequest, error,
              durationMs: requestWatch?.elapsedMilliseconds);
          rethrow;
        }
        if (requestWatch != null) {
          recordMatrixSessionSuccess(
              MatrixSessionFailureBoundary.confirmationRequest,
              durationMs: requestWatch.elapsedMilliseconds);
        }
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
            BottomNavigationBarItem(icon: Icon(ChangliaoIcons.me), label: '我'),
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
        onPhoneLogin: login.loginPhone,
        onConfirmMatrixAccountSwitch: login.confirmAccountSwitchAndLogin,
        onCancelMatrixAccountSwitch: login.cancelAccountSwitch,
        onAuthenticated: session.bootstrap,
      ),
      authenticatedBuilder: (_) => ChatDiagnosticsScope(
          sessionEpoch: api.sessionEpoch,
          version:
              '${AppConfig.appVersionName.split('-').first}+${AppConfig.appBuildNumber}',
          platform: switch (defaultTargetPlatform) {
            TargetPlatform.android => ChatDiagnosticPlatform.android,
            TargetPlatform.iOS => ChatDiagnosticPlatform.ios,
            _ => ChatDiagnosticPlatform.other,
          },
          upload: api.uploadChatDiagnostics,
          child: AppHome(
            api: api,
            matrix: matrix,
            onLogout: () {
              ChatDiagnostics.instance.stopSession();
              return session.logout();
            },
            themeController: themeController,
          )),
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

/// Starts at the first app-controlled boundary after Flutter binding setup.
/// A post-frame callback marks only the first rendered shell frame; content
/// readiness is tracked by each page where a real content signal exists.
/// Startup stays local to PerformanceMetrics because the authenticated
/// ChatDiagnostics session may change before the first frame. This also keeps
/// pre-login timing out of account-scoped diagnostic uploads.
@visibleForTesting
PerformanceTrace? scheduleAppStartupFirstFrame({
  PerformanceTraceRecorder? recorder,
  PerformanceMetrics? localMetrics,
}) {
  final PerformanceTraceRecorder active;
  if (recorder != null) {
    active = recorder;
  } else {
    final metrics = localMetrics ?? PerformanceMetrics.instance;
    if (!metrics.enabled) return null;
    active = PerformanceTraceRecorder(
      metrics: metrics,
      enabled: () => metrics.enabled,
    );
  }
  if (!active.recordingEnabled) return null;
  final trace = active.start(PerformanceOperationType.appStartup);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    trace.mark(PerformanceStage.firstFrameRendered);
    trace.finish();
  });
  return trace;
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
        animation:
            Listenable.merge([widget.themeController, motionPreferences]),
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
          // 「减少动态效果」投影：动效组件（菜单/点赞/按钮/图片帧）读
          // MediaQuery.disableAnimations；页面转场由 MotionPageRoute 读取
          // 同一份 MediaQuery。系统开关为真时保持为真，不会反向关闭。
          builder: (context, child) {
            final data = MediaQuery.of(context);
            if (!motionPreferences.reduceMotion || data.disableAnimations) {
              return child!;
            }
            return MediaQuery(
              data: data.copyWith(disableAnimations: true),
              child: child!,
            );
          },
          home: widget.home,
        ),
      );
}

final class ClientComposition {
  ClientComposition({required this.sessionStore, required this.matrixClient});
  final SecureSessionStore sessionStore;
  final MatrixE2eeClient matrixClient;
}
