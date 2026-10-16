import 'core/startup_projection/startup_projection.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matrix/matrix.dart' show Client;

import 'app_home.dart';
import 'core/app_config.dart';
import 'core/chat_diagnostics.dart';
import 'core/chat_diagnostics_scope.dart';
import 'core/chat_diagnostics_spool_store.dart';
import 'core/business_api_client.dart';
import 'core/performance_metrics.dart';
import 'core/performance_trace.dart';
import 'core/media_resource_policy.dart';
import 'core/matrix_startup_client.dart';
import 'features/matrix/media_cache.dart';
import 'features/moments/moment_publish_coordinator.dart';
import 'core/installation_container_probe.dart';
import 'core/installation_marker.dart';
import 'core/installation_reconciler.dart';
import 'core/installation_startup_gate.dart';
import 'core/session_bootstrap_controller.dart';
import 'core/outbox/outbox_store.dart';
import 'core/session_store.dart';
import 'core/startup_failure_metadata.dart';
import 'core/startup_diagnostics.dart';
import 'core/startup_diagnostics_spool.dart';
import 'core/startup_diagnostics_transport.dart';
import 'features/auth/login_controller.dart';
import 'features/auth/login_stage_diagnostics.dart';
import 'features/auth/authentication_flow.dart';
import 'features/matrix/call_ui_manager.dart' show callNavigatorKey;
import 'features/matrix/duplicate_room_registry.dart';
import 'features/matrix/matrix_client_factory.dart';
import 'features/matrix/matrix_security_logger.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'features/matrix/matrix_home_page.dart';
import 'session_gate.dart';
import 'ui/motion/motion_preferences.dart';
import 'features/settings/voice_auto_play_preferences.dart';
import 'ui/theme/wechat_theme.dart';
import 'ui/theme/theme_controller.dart';

/// Bottom-level startup adapters for isolated native/host acceptance fixtures.
/// The production entry point, gates, composition and pages remain unchanged.
class StartupDependencies {
  const StartupDependencies(
      {required this.store,
      required this.matrixFactory,
      required this.api,
      required this.reconcile,
      this.outboxStoreFactory});
  final SecureSessionStore store;
  final MatrixClientFactory Function(Future<void> resumeBackground)
      matrixFactory;
  final BusinessApiClient api;
  final Future<InstallationResetOutcome> Function() reconcile;
  final OutboxStore Function()? outboxStoreFactory;
}

Future<void> main({StartupDependencies? dependencies}) async {
  final startupClock = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();
  final startupDiagnostics = StartupDiagnostics(
    spool: FileStartupDiagnosticsSpool(),
    transport: HttpStartupDiagnosticsTransport(
        Uri.parse(AppConfig.businessApiBaseUrl)
            .resolve('/api/v1/startup-diagnostics')),
    appVersion: AppConfig.appVersionName.split('-').first,
    buildNumber: AppConfig.appBuildNumber,
    osVersion: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? (RegExp(r'^Version ([0-9]{1,3}(?:\.[0-9]{1,3}){0,2})(?: |$)')
                .firstMatch(Platform.operatingSystemVersion)
                ?.group(1) ??
            'unknown')
        : 'unknown',
    enabled: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS,
  );
  // Memory recording exists before the first platform/storage await. Queue and
  // transport failures never participate in local session startup decisions.
  unawaited(
      startupDiagnostics.initialize().then((_) => startupDiagnostics.flush()));
  void recordStartupFailure(StartupFailureMetadata failure) {
    startupDiagnostics.record(startupStageForFailure(failure), failure);
    unawaited(startupDiagnostics.flush());
  }

  WidgetsBinding.instance
      .addObserver(_StartupDiagnosticsLifecycle(startupDiagnostics));
  try {
    await _startApplicationShell(
        startupDiagnostics, recordStartupFailure, dependencies, startupClock);
  } catch (error) {
    recordStartupFailure(safeStartupFailure(error,
        boundary: StartupFailureBoundary.preferencesLoad));
    rethrow;
  }
}

Future<void> _startApplicationShell(
    StartupDiagnostics startupDiagnostics,
    StartupFailureObserver recordStartupFailure,
    StartupDependencies? dependencies,
    Stopwatch startupClock) async {
  scheduleAppStartupFirstFrame();
  installChatErrorReporter();
  MediaResourcePolicy(clearEncoded: trimOptionalMediaMemoryCaches).install();
  PerformanceMetrics.instance.startFrameObservation();
  late ThemeController themeController;
  late SharedPreferencesChatDiagnosticSpoolStore diagnosticsSpool;
  late SecureSessionStore store;
  late InstallationReconciler installationReconciler;
  var shellPrepared = false;

  Future<void> prepareApplication() async {
    // Package metadata is optional presentation/diagnostics information. The
    // compiled version remains accurate while the platform plugin responds;
    // it must not serialize installation, key and account safety checks.
    unawaited(observeStartupOperation(AppConfig.loadRuntimeVersion,
            boundary: StartupFailureBoundary.versionLoad)
        .then((_) {
      startupDiagnostics.updateVersion(
          AppConfig.appVersionName.split('-').first, AppConfig.appBuildNumber);
    }).catchError((Object error) {
      recordStartupFailure(safeStartupFailure(error,
          boundary: StartupFailureBoundary.versionLoad));
    }));
    final preferences = await SharedPreferences.getInstance();
    final loadedThemeController = ThemeController(
      store: SharedPreferencesThemePreferenceStore(
        preferences,
      ),
    );
    await loadedThemeController.load();
    // BUG-08：「减少动态效果」是本地设置，启动即读取，并由根组件投影到
    // MediaQuery，使所有动效组件与页面转场在首帧就遵循该设置。
    motionPreferences.attachStore(SharedPreferencesMotionPreferenceStore(
      preferences,
    ));
    await motionPreferences.load();
    // BUG-40：「语音自动连播」（默认开）本地设置启动即读取。
    voiceAutoPlayPreferences.attachStore(SharedPreferencesVoiceAutoPlayStore(
      preferences,
    ));
    await voiceAutoPlayPreferences.load();
    diagnosticsSpool = SharedPreferencesChatDiagnosticSpoolStore(preferences);
    store = dependencies?.store ?? SecureSessionStore();
    installationReconciler = InstallationReconciler(
      marker: SharedPreferencesInstallationMarker(
        preferences,
      ),
      probe: FileSystemInstallationContainerProbe(),
      store: store,
      onFailure: recordStartupFailure,
    );
    themeController = loadedThemeController;
    shellPrepared = true;
  }

  Future<Widget> startApplication() async {
    final api = dependencies?.api ??
        BusinessApiClient(
          baseUri: Uri.parse(AppConfig.businessApiBaseUrl),
          sessionStore: store,
        );
    // 本地生命周期诊断只记录加盐哈希后的标识，原始 Matrix user/device id 与
    // token 永远不出现在日志里。
    // Optional diagnostics must not serialize the cache content frame.
    const MatrixDiagnosticHasher? diagnosticHasher = null;

    final firstLocalFrame = Completer<void>();
    void resumeInitialization() {
      if (!firstLocalFrame.isCompleted) firstLocalFrame.complete();
    }

    final matrixFactory = dependencies?.matrixFactory(firstLocalFrame.future) ??
        MatrixClientFactory(
          startupBackgroundResume: firstLocalFrame.future,
          sessionStore: store,
          homeserver: Uri.parse(AppConfig.matrixHomeserver),
          diagnosticHasher: diagnosticHasher,
        );
    matrixFactory.startupClock = startupClock;
    // Read/create the installation identifier before opening a DB handle so a
    // locked keychain cannot leave an initialized client behind on startup retry.
    final startupClient = await observeStartupOperation(() async {
      StartupFailureMetadata? databaseFailure;
      try {
        return await openStartupMatrixClient(
          openRetained: () => matrixFactory.createForStartup(
              onFailure: (failure) => databaseFailure = failure),
          createSafeShell: () => Client(MatrixClientFactory.clientName),
        );
      } catch (_) {
        // Passive factory breadcrumbs preserve the original error type for
        // recovery decisions. Only terminal app composition gets wrapped.
        if (databaseFailure != null) {
          throw StartupFailureException(databaseFailure!);
        }
        rethrow;
      }
    }, boundary: StartupFailureBoundary.databaseOpen);
    final installationDeviceKey =
        matrixFactory.startupAdmission?.registrationKey ??
            await observeStartupOperation<String>(store.registrationDeviceKey,
                boundary: StartupFailureBoundary.installationIdentity);
    final sdkClient = startupClient.client;
    final matrix = MatrixSdkE2eeClient(
      sdkClient,
      secureSessionStore: store,
      startupProjection: matrixFactory.startupProjection,
      startupAdmission: matrixFactory.startupAdmission,
      startupClock: startupClock,
      migrateRecoveryArchives: matrixFactory.migrateRecoveryArchives,
      refreshRecoveryBusinessSession: () async {
        await api.refreshSession();
      },
      homeserver: Uri.parse(AppConfig.matrixHomeserver),
      suspendClient: matrixFactory.suspend,
      resumeClient: matrixFactory.create,
      selectClientAccount: matrixFactory.selectAccount,
      prepareNewDeviceStorage: (homeserver, userId) =>
          matrixFactory.prepareFreshDeviceForConfirmedRecovery(
        expectedHomeserver: homeserver,
        expectedUserId: userId,
      ),
      clearClientData: matrixFactory.clearLocalChatData,
      readContinuityMetadata: guardStartupContinuityReader(
          startupClient, matrixFactory.continuityMetadata),
      rotateDeviceBinding: matrixFactory.rotateDeviceBinding,
      diagnosticHasher: diagnosticHasher,
      // 历史孤儿房间登记簿：primary 规则数据源 + 收敛台账（只记录不删除）。
      duplicateRooms: DuplicateRoomRegistry(),
    );
    unawaited(firstLocalFrame.future.then((_) async {
      final salt = await loadStartupDiagnosticSalt(store);
      if (salt == null) return;
      final hasher = MatrixDiagnosticHasher(salt);
      matrixFactory.diagnosticHasher = hasher;
      matrix.installDiagnosticHasher(hasher);
    }).catchError((Object _) {}));
    late final DualDomainLoginService login;
    final session = SessionBootstrapController(
      business: api,
      matrix: matrix,
      onLocalProjectionEligibility: (eligible) {
        if (!eligible) resumeInitialization();
      },
      securityLogger: matrix.securityLogger,
      onFailure: (failure) {
        startupDiagnostics.record(
            StartupFailureStage.sessionBootstrap, failure);
        unawaited(startupDiagnostics.flush());
      },
      restoreLocalMatrixSession: (identity) async {
        await observeStartupOperation(
            () => validateLocalLoginStorageForAuthentication(store),
            boundary: StartupFailureBoundary.accountStorage,
            loginStage: StartupLoginStage.accountStorage);
        await login.restoreAuthenticatedSession(identity);
      },
    );
    login = DualDomainLoginService(
      prepareLocalLogin: () =>
          validateLocalLoginStorageForAuthentication(store),
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
    MatrixHomeHandoff? startupHandoff;
    MatrixHomeHandoff? currentStartupHandoff() {
      if (!session.canShowCachedMessages) {
        startupHandoff?.retire();
        return null;
      }
      if (startupHandoff?.isCurrent != true) {
        startupHandoff = MatrixHomeHandoff(
            api: api,
            matrix: matrix,
            eligible: () => session.canShowCachedMessages,
            onPublished: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!firstLocalFrame.isCompleted) {
                  markStartupProjection(
                      StartupProjectionPhase.firstProjectionContentFrame,
                      startupClock);
                }
                resumeInitialization();
              });
              WidgetsBinding.instance.scheduleFrame();
            });
      }
      return startupHandoff;
    }

    final verifiedSession = ValueNotifier<bool>(false);
    session.addListener(() {
      verifiedSession.value = switch (session.state.status) {
        SessionBootstrapStatus.authenticated ||
        SessionBootstrapStatus.offlineAuthenticated =>
          true,
        _ => false,
      };
      if (session.state.status == SessionBootstrapStatus.authenticated) {
        final cache = matrixFactory.projectionStore;
        if (cache != null) {
          unawaited(
              matrix.primeStartupProjection(cache).catchError((Object _) {}));
        }
      }
      startupHandoff?.invalidateIfUnavailable();
      if (session.state.status != SessionBootstrapStatus.loading &&
          !session.canShowCachedMessages) {
        resumeInitialization();
      }
    });
    final gate = SessionGate(
      controller: session,
      unauthenticatedBuilder: (_) => AuthenticationFlow(
        api: api,
        onLogin: login.login,
        onPhoneLogin: login.loginPhone,
        onPhoneInvitationContinue: login.continuePhoneInvitation,
        onConfirmMatrixAccountSwitch: login.confirmAccountSwitchAndLogin,
        onCancelMatrixAccountSwitch: login.cancelAccountSwitch,
        onConfirmNewDeviceRecovery: login.confirmNewDeviceAndLogin,
        onCancelNewDeviceRecovery: login.cancelNewDeviceRecovery,
        onAuthenticated: session.bootstrap,
      ),
      onConfirmNewDeviceRecovery: login.confirmNewDeviceAndLogin,
      authenticatedBuilder: (_) => const SizedBox.shrink(),
      localSessionBuilder: (_, verified) =>
          Stack(fit: StackFit.expand, children: [
        AppHome(
          key: ValueKey(
              (matrix, matrix.userId, matrix.deviceId, api.sessionEpoch)),
          localOnly: !verified,
          outboxStoreFactory: dependencies?.outboxStoreFactory,
          verifiedSession: verifiedSession,
          startupHandoff: currentStartupHandoff(),
          api: api,
          matrix: matrix,
          onLogout: () async {
            ChatDiagnostics.instance.stopSession();
            try {
              await MomentPublishQueues.revoke(api);
            } catch (_) {}
            await session.logout();
          },
          themeController: themeController,
        ),
        if (verified)
          ChatDiagnosticsScope(
            sessionEpoch: api.sessionEpoch,
            version:
                '${AppConfig.appVersionName.split('-').first}+${AppConfig.appBuildNumber}',
            platform: switch (defaultTargetPlatform) {
              TargetPlatform.android => ChatDiagnosticPlatform.android,
              TargetPlatform.iOS => ChatDiagnosticPlatform.ios,
              _ => ChatDiagnosticPlatform.other,
            },
            upload: api.uploadChatDiagnostics,
            spool: diagnosticsSpool,
            spoolScope: api.diagnosticSpoolScope,
            child: const SizedBox.shrink(),
          ),
      ]),
    );
    final bootstrap = session.bootstrap();
    unawaited(() async {
      try {
        await bootstrap;
        await session.runAuthenticatedBackground(
          prepare: () async => true,
          complete: matrix.syncIfActive,
        );
      } catch (error) {
        startupDiagnostics.record(
            StartupFailureStage.localRestore,
            safeStartupFailure(error,
                boundary: StartupFailureBoundary.localRestore));
        unawaited(startupDiagnostics.flush());
        // The encrypted database and secure-store records remain intact. The
        // recovery UI can present a retry/import flow without exposing secrets.
      }
    }());
    return gate;
  }

  runApp(InstallationStartupGate(
    prepare: prepareApplication,
    shellBuilder: (child) => shellPrepared
        ? LiuhetongApp(home: child, themeController: themeController)
        : CupertinoApp(title: '畅聊 ChatFlow', home: child),
    reconcile: () async {
      final outcome = await (dependencies?.reconcile() ??
          installationReconciler.reconcile());
      if (outcome == InstallationResetOutcome.failed && kDebugMode) {
        debugPrint('[installation] generation reset did not settle');
      }
      return outcome;
    },
    start: startApplication,
    onFailure: recordStartupFailure,
  ));
}

final class _StartupDiagnosticsLifecycle extends WidgetsBindingObserver {
  _StartupDiagnosticsLifecycle(this.diagnostics);
  final StartupDiagnostics diagnostics;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(diagnostics.flush());
  }
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
      timestampedFrameAttribution: true,
      enabled: () => metrics.enabled,
    );
  }
  if (!active.recordingEnabled) return null;
  final trace = active.start(PerformanceOperationType.appStartup);
  void finishVisibleFrame(Duration _) {
    // Deferred frames perform layout but never reach the engine. Waiting for
    // the shell budget must remain part of startup latency, not disappear from
    // the metric because an invisible frame was built first.
    if (!WidgetsBinding.instance.sendFramesToEngine) {
      WidgetsBinding.instance.addPostFrameCallback(finishVisibleFrame);
      return;
    }
    trace.mark(PerformanceStage.firstFrameRendered);
    trace.finish();
  }

  WidgetsBinding.instance.addPostFrameCallback(finishVisibleFrame);
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
