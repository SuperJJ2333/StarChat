import 'features/contacts/contact_actions.dart';
import 'features/matrix/direct_chat_failure.dart';
import 'features/contacts/group_address_list_page.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/business_api_client.dart';
import 'core/app_connection_status.dart';
import 'core/app_config.dart';
import 'core/local_notification_scheduler.dart';
import 'core/notification/app_state_manager.dart';
import 'core/notification/badge_service.dart';
import 'core/notification/foreground_service_arbiter.dart';
import 'core/notification/foreground_sound_service.dart';
import 'core/notification/sync_keepalive_service.dart';
import 'core/notification/haptic_service.dart';
import 'core/notification/in_app_banner_controller.dart';
import 'core/notification/notification_coordinator.dart';
import 'core/notification/notification_deduplicator.dart';
import 'core/notification/notification_diagnostics.dart';
import 'core/notification/notification_feedback.dart';
import 'core/notification/notification_preferences.dart';
import 'core/notification/notification_system_bootstrapper.dart';
import 'core/notification/notification_usage_recorder.dart';
import 'core/notification/system_notification_presenter.dart';
import 'features/caibi/caibi_page.dart';
import 'features/contacts/contacts_page.dart';
import 'features/contacts/scan_qr_page.dart';
import 'features/contacts/contact_models.dart';
import 'features/contacts/user_display_name_resolver.dart';
import 'features/discovery/discovery_page.dart';
import 'features/moments/moments_page.dart';
import 'features/moments/moments_unread_controller.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'features/matrix/matrix_security_logger.dart';
import 'features/matrix/direct_chat_controller.dart';
import 'features/matrix/coordinated_direct_chat.dart';
import 'features/moments/moment_preview_cache.dart';
import 'features/ledger/ledger_pages.dart';
import 'features/ledger/ledger_business_gateway.dart';
import 'features/matrix/direct_room_coordination_storage.dart';
import 'features/matrix/matrix_sync_watchdog.dart';
import 'features/matrix/matrix_sync_recovery_controller.dart';
import 'features/matrix/matrix_home_page.dart' show MatrixHomePage;
import 'features/matrix/room_page.dart';
import 'features/matrix/profile_repository.dart';
import 'features/matrix/group_chat_controller.dart';
import 'features/matrix/call_ui_manager.dart';
import 'features/matrix/group_chat_page.dart';
import 'features/matrix/server_auto_join_group_gateway.dart';
import 'features/matrix/call_alerts.dart';
import 'features/matrix/call_controller.dart';
import 'features/matrix/call_diagnostics.dart';
import 'features/matrix/call_permissions.dart';
import 'features/settings/notification/background_call_permission_prompt.dart';
import 'features/matrix/call_notifications.dart';
import 'features/matrix/call_page.dart';
import 'features/matrix/matrix_call_adapter.dart';
import 'features/matrix/native_call_coordinator.dart';
import 'features/matrix/ios_call_coordinator.dart';
import 'features/matrix/call_wakeup_client.dart';
import 'features/matrix/matrix_message_reminder_backend.dart';
import 'features/matrix/message_reminder_service.dart';
import 'features/push/firebase_push_token_provider.dart';
import 'features/push/native_apns_push_token_provider.dart';
import 'core/privacy_consent.dart';
import 'features/push/firebase_push_wiring.dart';
import 'features/push/getui_push_token_provider.dart';
import 'features/push/matrix_pusher_service.dart';
import 'features/push/native_push_bridge.dart';
import 'features/push/push_status_registry.dart';
import 'features/push/push_tap_router.dart';
import 'features/push/push_token_provider.dart';
import 'features/wallet/wallet_page.dart';
import 'ui/components/wechat_list_tile.dart';
import 'ui/components/messages_tab_icon.dart';
import 'ui/foundation/changliao_icons.dart';
import 'ui/foundation/wechat_tokens.dart';
import 'ui/theme/theme_controller.dart';
import 'ui/theme/theme_picker_sheet.dart';
import 'features/profile/about_page.dart';
import 'features/profile/invite_code_page.dart';
import 'features/profile/my_qr_code_page.dart';
import 'features/profile/invite_controller.dart';
import 'features/profile/profile_controller.dart';
import 'features/profile/profile_page.dart';
import 'features/profile/avatar_source.dart';
import 'features/settings/notification/notification_settings_page.dart';
import 'features/friendship/friend_request_watch.dart';
import 'features/update/app_update.dart';
import 'features/update/update_integrity.dart';
import 'features/update/app_update_dialog.dart';
import 'ui/notification/in_app_banner_overlay.dart';
import 'ui/notification/notification_readiness_banner.dart';

/// Owns asynchronous initialization for one managed Matrix home generation.
/// A replacement generation cannot install platform handlers until old work drains.
@visibleForTesting
final class AppHomeStartupScope {
  int _generation = 0;
  bool _active = false;
  bool _closing = false;
  final Set<Future<void>> _flights = {};

  void open() {
    if (_closing || _flights.isNotEmpty || _active) {
      throw StateError('Previous home initialization has not drained');
    }
    _generation++;
    _active = true;
  }

  bool isCurrent(int generation) => _active && generation == _generation;
  int get generation => _generation;

  Future<void> run(Future<void> Function(int generation) operation) {
    if (!_active) return Future<void>.value();
    final generation = _generation;
    late final Future<void> flight;
    flight = Future<void>.sync(() => operation(generation)).whenComplete(() {
      _flights.remove(flight);
    });
    _flights.add(flight);
    return flight;
  }

  Future<void> close() async {
    _active = false;
    _generation++;
    _closing = true;
    try {
      while (_flights.isNotEmpty) {
        await Future.wait(_flights
            .toList()
            .map((flight) => flight.catchError((Object _) {})));
      }
    } finally {
      _closing = false;
    }
  }
}

final class AppHome extends StatefulWidget {
  const AppHome({
    super.key,
    required this.api,
    required this.matrix,
    required this.onLogout,
    required this.themeController,
    this.profileRepositoryFactory,
    this.syncWatchdogFactory,
  });

  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final Future<void> Function() onLogout;
  final ThemeController themeController;

  /// Test seam for the account-scoped repository; AppHome retains hydration,
  /// preload, ownership checks and disposal of the returned repository.
  final Future<ProfileRepository> Function(
      BusinessApiClient api, String? accountKey)? profileRepositoryFactory;
  final MatrixSyncWatchdog Function(SyncWatchdogTarget target)?
      syncWatchdogFactory;

  @override
  State<AppHome> createState() => _AppHomeState();
}

final class _AppHomeState extends State<AppHome> with WidgetsBindingObserver {
  void _warmMomentPreviewCache() {
    final cache = _chatIdentityCache;
    if (cache == null) return;
    MomentPreviewCache.instance.fetcher ??= (userId) async {
      try {
        return await widget.api.momentProfilePreview(userId);
      } on Exception {
        return null; // 后台预取失败静默：下次进页再试。
      }
    };
    // 冷启动后台预取好友预览（并发 3，TTL 内不重复请求）。
    unawaited(MomentPreviewCache.instance
        .prefetch(cache.contacts.map((contact) => contact.userId)));
  }

  late final DirectChatController directChats = DirectChatController(
    CoordinatedDirectChatGateway(
      coordinator: ApiDirectRoomCoordinator(widget.api),
      intents: PreferencesDirectRoomIntentStore(widget.matrix.userId ?? ''),
      createOnce: widget.matrix.createDirectChatOnce,
      findExisting: widget.matrix.findExistingDirectChat,
      findCached: widget.matrix.findCachedDirectChat,
      businessUserIdOf: (matrixUserId) =>
          _chatIdentityCache?.contactsByMatrixId[matrixUserId]?.userId,
      openExisting: _openCanonicalDirectRoom,
    ),
  );

  /// 打开规范登记的私聊房间：受邀未加入时先加入；对端建的房间我方
  /// m.direct 可能缺失，补写后房间才具备 DM 语义（否则渲染成"群聊"，
  /// 且后续 invite 扫描无法识别）；最后做加密+双人校验。
  Future<DirectChatRoom> _openCanonicalDirectRoom(String roomId, String peer) =>
      widget.matrix.openCanonicalDirectRoom(roomId, matrixUserId: peer);

  /// 通话关键路径诊断：backend（invite/answer/ICE）与 controller
  /// （UI 展示/点击接听）共享同一时间线。
  late final CallDiagnostics callDiagnostics = CallDiagnostics();
  late CallWakeupClient callWakeup;
  late MatrixCallBackend callBackend;
  late final ForegroundSoundService notificationSounds =
      ForegroundSoundService();
  CallController _createCallController() => CallController(
        backend: callBackend,
        // 系统权限 API（permission_handler）——不再用 getUserMedia 探测流。
        permissions: const SystemCallPermissionGateway(),
        diagnostics: callDiagnostics,
        // SE 来电铃声（PRD §9/§10）：语音/视频各自循环铃声，
        // 受"语音/视频通话通知"设置开关约束。
        alerts: CallAlerts(
          driver: SoundServiceCallAlertDriver(
            sound: notificationSounds,
            enabled: () =>
                NotificationSystemHandle
                    .coordinator?.preferences.callNotificationEnabled ??
                true,
            // BUG2 双声去重：后台来电由 calls_ring 渠道系统发声，
            // 应用内循环静音；回前台（或前台来电）恢复应用内铃声。
            audible: () => defaultTargetPlatform == TargetPlatform.iOS
                ? !callBackend.isIncomingCall
                : appResumed || !callUi.ringing,
          ),
        ),
      );
  late CallController calls;
  bool _matrixReady = false;
  final AppHomeStartupScope _startup = AppHomeStartupScope();
  bool _currentStartup(int generation) =>
      mounted && _matrixReady && _startup.isCurrent(generation);
  Future<void> _runStartup(Future<void> Function(int) operation) =>
      _startup.run(operation).catchError((Object _) {
        widget.matrix.securityLogger.record(
          stage: MatrixSecurityStage.lifecycle,
          outcome: MatrixSecurityOutcome.failure,
          eventCode: MatrixSecurityCode.homeResourceDisposeFailed,
        );
      });
  bool callPageVisible = false;
  Object? _outgoingPresentationToken;
  bool _outgoingCallActive = false;

  /// 全局通话 UI 管理器（规格 §一/§三）：唯一有权推/关来电页面的组件
  /// （根 Navigator 之上，任意页面/子路由都盖不住）。AppHome 只保留
  /// 业务钩子（消息提醒抑制/通话摘要），不再自呈通话 UI。
  late final CallUiManager callUi = CallUiManager(
    navigatorKey: callNavigatorKey,
    notifications: callNotifications,
    isAppResumed: () => appResumed,
    displayNameResolver: _sharedDisplayNameResolver,
    onPhaseChanged: _onCallPhaseChangedForBusiness,
    onMinimized: () =>
        unawaited(_nativePresentation('minimizeCallPresentation')),
    onRestored: () => unawaited(_nativePresentation('showCallPage')),
  );
  bool appResumed = true;

  /// 本次通话摘要是否已发送：ended 分支可能随 notifyListeners 多次进入，
  /// 必须去重，确保一次通话只落一条通话状态气泡。
  bool callSummarySent = false;
  late final CallNotifications callNotifications = CallNotifications(
    arbiter: foregroundArbiter,
  );
  MessageReminderService? reminderService;
  MessageReminderSyncBootstrapper? reminderBootstrap;

  // 统一通知系统（PRD §2）：所有声音/震动/角标/系统通知经协调器。
  final AppStateManager notificationAppState = AppStateManager();
  final InAppBannerController notificationBanners = InAppBannerController();
  NotificationCoordinator? _notificationCoordinator;

  /// 前台服务仲裁器：flutter_local_notifications 全局只有一个 Android
  /// ForegroundService，消息保活与通话中服务必须共用同一仲裁器，
  /// 否则通话结束的 stopForegroundService 会把消息同步一起停掉。
  late final ForegroundServiceArbiter foregroundArbiter =
      ForegroundServiceArbiter(backend: FlutterForegroundServiceBackend());

  /// BUG 2 后台/锁屏通知保活：dataSync 前台服务维持 Matrix 同步长连接，
  /// 登录会话期间常驻（AppHome 即登录后的根页面，dispose 即退出登录）。
  /// 注意：Android 14+ 对 dataSync 前台服务有每日时长配额（约 6 小时），
  /// 这是短期缓解而非长期推送方案；长期方案为 Matrix Pusher + Sygnal。
  late final SyncKeepAliveService syncKeepAlive = SyncKeepAliveService(
    backend: ArbiterSyncKeepAliveBackend(arbiter: foregroundArbiter),
  );

  /// BUG（后台通知第四次修复）：SDK 同步循环后台悬挂无自愈——看门狗
  /// 以循环心跳为准，停跳先踢 oneShotSync，仍停跳强制重建循环。
  late MatrixSyncWatchdog syncWatchdog;
  bool _syncWatchdogStarted = false;
  Object? _connectionStatusOwner;
  ManagedMatrixNotificationEventSource? _notificationEventSource;

  /// 通知系统唯一启动器：登录会话内只装配一个 eventSource + coordinator。
  NotificationSystemBootstrapper? _notificationBootstrapper;

  /// 跨进程重启去重（推送已展示的事件，冷启动同步不得二次提醒）。
  NotificationDeduplicator? _sharedDeduplicator;
  NotificationDedupStore? _sharedDedupStore;

  /// 推送（Matrix Pusher，多通道：个推桥接 + Sygnal/FCM）：注册/注销
  /// 与点击冷启动路由。每通道一个 pusher 服务与 token 提供方。
  PushTapRouter? _pushTapRouter;
  final _pusherServices = <MatrixPusherService>[];
  final _pushTokenProviders = <PushTokenProvider>[];

  ProfileRepository? _chatIdentityCache;
  MomentsUnreadController? _momentsUnread;

  Future<void> _initializeMomentsUnread() =>
      _runStartup(_initializeMomentsUnreadFor);

  Future<void> _initializeMomentsUnreadFor(int generation) async {
    final preferences = await SharedPreferences.getInstance();
    if (!_currentStartup(generation)) return;
    final unread = MomentsUnreadController(
      accountKey: widget.matrix.userId ?? '',
      preferences: preferences,
      load: widget.api.momentNewPosts,
    );
    setState(() => _momentsUnread = unread);
    await unread.initialize();
  }

  Future<ProfileRepository>? _chatIdentityCacheLoad;
  late final UserDisplayNameResolver _sharedDisplayNameResolver =
      ContactBackedUserDisplayNameResolver(
    contactFor: (id) {
      for (final contact
          in _chatIdentityCache?.contacts ?? <ContactSummary>[]) {
        if (contact.matrixUserId == id) return contact;
      }
      return null;
    },
    warmContacts: () async {
      await (_chatIdentityCacheLoad ??= _createIdentityCache());
    },
  );
  MatrixMessageReminderBackend? reminderBackend;
  MatrixManagedResource? matrixResources;
  MatrixAppHomeCapability? _matrixHomeCapability;
  Future<void>? _matrixResourceSetup;
  bool _disposed = false;
  int _totalUnreadCount = 0;
  StreamSubscription<void>? _unreadSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _matrixResourceSetup = _initializeMatrixResources();
    unawaited(_matrixResourceSetup);
    unawaited(_identityCache());
    _unreadSubscription = widget.matrix.syncEvents.listen((_) {
      unawaited(_refreshUnreadCount());
    });
  }

  void _startHomeResources() {
    final generation = _startup.generation;
    unawaited(_initializeMomentsUnread().catchError((_) {}));
    // 规格§三：native_call 通道——Telecom/CallActivity 事件与控制入口。
    // 事件语义严格区分（修复"来电事件即自动接听"）：incomingCall 只登记
    // 呈现；只有 callAccepted/callRejected（用户明确动作）才驱动接听/拒接，
    // 全部经 NativeCallCoordinator（含冷启动 ready 握手与待接听仲裁）。
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(_initializeIosCalls());
    } else {
      nativeCalls = _createNativeCalls();
      _nativeCallControl = const MethodChannel('native_call');
      _nativeCallControl?.setMethodCallHandler((call) async {
        if (call.method == 'returnToCall') {
          callUi.restoreCall();
          return true;
        }
        return nativeCalls.handleNativeMessage(call.method, call.arguments);
      });
      unawaited(_runStartup((_) => nativeCalls.restorePendingState()));
    }
    // 通话 UI 归 CallUiManager（唯一监听呈现者）；业务钩子经
    // onPhaseChanged 回调进来（消息提醒抑制/通话摘要）。
    _nativePushBridge = NativePushBridge(
      onPushMessage: () async {
        if (!_currentStartup(generation)) return;
        // Resolve opaque encrypted wakes locally before choosing a message or
        // call notification. Existing in-flight sync is reused by the SDK.
        unawaited(syncWatchdog.target
            .oneShotSync()
            .timeout(const Duration(seconds: 10))
            .catchError((Object error) {
          debugPrint('[push] wake sync deferred: ${error.runtimeType}');
        }));
        final coordinator = NotificationSystemHandle.coordinator;
        if (coordinator != null) {
          await coordinator.showPushWakeNotification();
        }
      },
      onFriendRequest: () async {
        if (!_currentStartup(generation)) return;
        // 好友申请：桌面角标 + 通讯录红点（登录会话内）。
        await NotificationSystemHandle.coordinator?.refreshLauncherBadge();
        if (mounted) await _pollFriendRequests();
      },
    );
    unawaited(_runStartup((_) => _nativePushBridge!.install()));
    // chatflow/call 通道：仅保留 Flutter→原生 dismiss（收起原生前台服务/
    // 通知层）。接听/拒绝动作统一走 native_call 事件（单一通道，避免
    // 双通道重复触发接听）。
    _nativeCallChannel = const MethodChannel('chatflow/call');
    callUi.attach(
      calls,
      mediaBackend: callBackend,
      outgoingCallPageVisible: () => callPageVisible,
    );
    calls.addListener(_handleCallState);
    reminderBootstrap = MessageReminderSyncBootstrapper(
      retries: widget.matrix.syncEvents,
      create: _createReminderSync,
      onReady: (coordinator) {
        if (_currentStartup(generation)) {
          setState(() => reminderService = coordinator.service);
        }
      },
    );
    unawaited(_runStartup((_) async {
      await reminderBootstrap?.start();
    }));
    unawaited(_identityCache());
    unawaited(_verifyDataIntegrity());
    unawaited(_checkForAppUpdate());
    unawaited(_startFriendRequestWatch());
    // 通知系统登录会话内只启动一次（保活/看门狗/引导在其就绪后接力）。
    // 历史缺陷：这里曾并发调用两次 _startNotificationSystem，产生两套
    // eventSource/coordinator/dedup，首套泄漏整个会话（双声/双震/双通知）。
    unawaited(_startNotificationSystem());
  }

  /// 组装并启动统一通知协调器（PRD §2/§22）。
  ///
  /// 启动失败不抛出：bootstrapper 置 needsRetry 并记录诊断，下一次
  /// 生命周期恢复（didChangeAppLifecycleState）重试。
  Future<void> _startNotificationSystem() =>
      _runStartup(_startNotificationSystemFor);

  Future<void> _startNotificationSystemFor(int generation) async {
    if (!_currentStartup(generation)) return;
    unawaited(NotificationDiagnostics.shared.ensureLoaded());
    final bootstrapper =
        _notificationBootstrapper ??= NotificationSystemBootstrapper(
      start: () => _assembleNotificationSystem(generation),
      stop: () async {
        await _notificationEventSource?.stop();
        await _notificationCoordinator?.dispose();
      },
      onReady: () {
        final coordinator = _notificationCoordinator;
        if (coordinator == null || !_currentStartup(generation)) return;
        NotificationFeedback.install(coordinator.playUiSound);
        NotificationSystemHandle.install(coordinator);
      },
    );
    final ready = await bootstrapper.ensureStarted();
    if (!ready || !_currentStartup(generation)) return;
    // 前台服务保活必须在通知系统就绪后启动（权限/渠道先行）。
    await syncKeepAlive.ensureStarted();
    if (!_currentStartup(generation)) return;
    unawaited(() async {
      await _primeBatteryOptimization();
      if (!_currentStartup(generation)) return;
      await _primeNotificationPermission();
      if (!_currentStartup(generation)) return;
      await _primeBackgroundCallPermissions();
    }());
    await _startPushIntegration(generation);
  }

  /// 推送集成（长期后台/被杀可达性）：多通道 pusher 注册。
  ///
  /// 通道优先级与隐私门槛：
  /// - Android 个推通道（getui-bridge，自建网关丢弃一切业务内容，通知只
  ///   显示"您有一条新消息/您有一个来电"）：要求①Android ②用户已持久化
  ///   同意隐私政策（同意前 SDK 仅 preInit，无采集无联网）③网关地址已
  ///   编译注入；CID 即 pushkey（Matrix 设备级绑定，登出=删 pusher，
  ///   绝不做手机号/用户名 alias）。
  /// - FCM/Sygnal 通道（凭据缺失时 Noop 降级，Matrix 同步通道照常）。
  Future<void> _startPushIntegration(int generation) async {
    if (!_currentStartup(generation)) return;
    final capability = _matrixHomeCapability;
    if (capability == null) return;
    // 老用户升级迁移：privacy.agreement_accepted.v1 引入（0.3.34）之前的
    // 已登录用户从未记录过同意——AppHome 挂载即证明用户已通过登录流程
    // 勾选《用户协议和隐私政策》（登录按钮在勾选前禁用），补写同意，
    // 否则升级后个推永远不初始化、pusher 永远不注册。
    final consentStore = SharedPreferencesPrivacyConsentStore();
    final accepted = await consentStore.accepted();
    if (!_currentStartup(generation)) return;
    if (!accepted) {
      await consentStore.accept();
      if (!_currentStartup(generation)) return;
      NotificationDiagnostics.shared.record(
          NotificationDiagStage.push, 'consent migrated for existing session');
    }
    final store = _sharedDedupStore ??=
        await SharedPreferencesNotificationDedupStore.create();
    if (!_currentStartup(generation)) return;
    final deduplicator = _sharedDeduplicator ??= NotificationDeduplicator(
      store: store,
      ttl: SharedPreferencesNotificationDedupStore.defaultTtl,
    );
    final router = _pushTapRouter ??= PushTapRouter(
      openConversation: (roomId) => _currentStartup(generation)
          ? _openConversationFromNotification(roomId)
          : Future.value(),
      deduplicator: deduplicator,
    );
    // 冷启动由通知点击拉起（含常规消息通知与推送兜底通知）。
    unawaited(routeNotificationLaunch(tapRouter: router));

    final pushers = <MatrixPusherService>[];

    // ① Android 个推通道（隐私同意前置；未同意只影响推送，不影响聊天）。
    if (defaultTargetPlatform == TargetPlatform.android &&
        AppConfig.getuiPushGatewayUrl.isNotEmpty &&
        await SharedPreferencesPrivacyConsentStore().accepted()) {
      if (!_currentStartup(generation)) return;
      final getuiGateway = Uri.tryParse(AppConfig.getuiPushGatewayUrl);
      if (getuiGateway != null) {
        final getui = GetuiPushTokenProvider();
        _pushTokenProviders.add(getui);
        await getui.initialize();
        if (!_currentStartup(generation)) return;
        pushers.add(MatrixPusherService(
          gateway: capability.createPusherGateway(),
          tokenProvider: getui,
          appId: MatrixPusherService.appIdGetui,
          gatewayUrl: MatrixPusherService.getuiGatewayUrl(getuiGateway),
          deviceDisplayName: 'ChatFlow Android',
        ));
      }
    }

    // ② Sygnal: iOS uses native APNs tokens; Android uses FCM tokens.
    final gatewayUrl = AppConfig.sygnalPushGatewayUrl.isEmpty
        ? null
        : Uri.tryParse(AppConfig.sygnalPushGatewayUrl);
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      if (gatewayUrl != null) {
        final apns = NativeApnsPushTokenProvider(onTap: router.handleTap);
        _pushTokenProviders.add(apns);
        await apns.initialize();
        if (!_currentStartup(generation)) return;
        pushers.add(MatrixPusherService(
          gateway: capability.createPusherGateway(),
          tokenProvider: apns,
          appId: MatrixPusherService.appIdIOS,
          gatewayUrl: gatewayUrl.resolve('/_matrix/push/v1/notify'),
          deviceDisplayName: 'ChatFlow iOS',
        ));
      }
    } else {
      final firebase = await FirebasePushTokenProvider.tryCreate();
      if (!_currentStartup(generation)) {
        await firebase?.dispose();
        return;
      }
      if (firebase != null) {
        _pushTokenProviders.add(firebase);
        pushers.add(MatrixPusherService(
          gateway: capability.createPusherGateway(),
          tokenProvider: firebase,
          appId: MatrixPusherService.appIdAndroid,
          gatewayUrl: gatewayUrl?.resolve('_matrix/push/v1/notify'),
          deviceDisplayName: 'ChatFlow Android',
        ));
        await configureFirebasePushHandlers(tapRouter: router);
        if (!_currentStartup(generation)) return;
      }
    }
    _pusherServices.addAll(pushers);
    // 诊断页读取：登记全部通道（登出统一 clear）。
    for (final pusher in pushers) {
      PushStatusRegistry.shared.register(pusher);
    }

    for (final pusher in pushers) {
      await pusher.ensureRegistered();
      if (!_currentStartup(generation)) return;
      await pusher.watchTokenRefresh();
      if (!_currentStartup(generation)) return;
    }
    // 推送点击路由就绪：通知系统已装配、主页面已挂载。
    router.markReady();
  }

  Future<void> _assembleNotificationSystem(int generation) async {
    if (!_currentStartup(generation)) return;
    final dedupStore = _sharedDedupStore ??=
        await SharedPreferencesNotificationDedupStore.create();
    if (!_currentStartup(generation)) return;
    final deduplicator = _sharedDeduplicator ??= NotificationDeduplicator(
      store: dedupStore,
      ttl: SharedPreferencesNotificationDedupStore.defaultTtl,
    );
    final eventSource = _matrixHomeCapability!.createNotificationEventSource(
      // 规格#2：通知标题/头像统一经名称解析器（备注优先）。
      displayNameResolver: _sharedDisplayNameResolver,
    );
    final coordinator = NotificationCoordinator(
      preferenceStore: const SharedPreferencesNotificationPreferenceStore(),
      systemNotifications: FlutterLocalSystemNotificationPresenter(
        onConversationTap: _handleNotificationTap,
      ),
      soundService: notificationSounds,
      hapticService: HapticService(),
      badgeGateway: const MethodChannelLauncherBadgeGateway(),
      appState: notificationAppState,
      banners: notificationBanners,
      eventSource: eventSource,
      unreadSource: _matrixHomeCapability!.createUnreadSnapshotSource(),
      deduplicator: deduplicator,
    );
    _notificationEventSource = eventSource;
    _notificationCoordinator = coordinator;
    await eventSource.start();
    if (!_currentStartup(generation)) return;
    await coordinator.start();
    if (!_currentStartup(generation)) return;
    await coordinator.refreshLauncherBadge();
  }

  /// BUG2：息屏后台通知的最后一公里——厂商 ROM 会清理"未加白名单"的
  /// 后台应用，前台服务+唤醒锁都保不住。登录后一次性引导用户把畅聊
  /// 加入电池优化白名单；已加白/已引导过则永不打扰。
  Future<void> _primeBatteryOptimization() async {
    if (!mounted) return;
    final gateway = const KeepAliveBatteryGateway();
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('keepalive.battery_prompted_v1') == true) return;
    if (await gateway.isIgnoringBatteryOptimizations()) {
      await prefs.setBool('keepalive.battery_prompted_v1', true);
      return;
    }
    await prefs.setBool('keepalive.battery_prompted_v1', true);
    if (!mounted) return;
    final goSettings = await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('后台消息保障'),
            content: const Text(
              '为了在锁屏和后台收到消息通知与来电铃声，请在接下来'
              '的系统弹窗中允许畅聊"忽略电池优化"。\n'
              '小米/红米设备另请在 设置→应用管理→畅聊 中开启"自启动"，'
              '并把省电策略设为"无限制"。',
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('暂不'),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('去设置'),
              ),
            ],
          ),
        ) ??
        false;
    if (goSettings && mounted) {
      await gateway.requestIgnoreBatteryOptimizations();
    }
  }

  /// 回前台/设置页返回后的权限状态复核（仅查询，不弹窗）。
  Future<void> _refreshNotificationPermissionState() async {
    final coordinator = _notificationCoordinator;
    if (coordinator == null) return;
    try {
      final status =
          await coordinator.systemNotifications.authorizationStatus();
      NotificationDiagnostics.shared
          .record(NotificationDiagStage.permission, 'status: ${status.name}');
    } catch (_) {
      // 权限查询失败不打扰主流程；诊断层已有记录。
    }
  }

  /// PRD §33：登录完成后上下文式申请通知权限，绝不在冷启动首屏弹。
  ///
  /// 注意：Android 13+ 的 areNotificationsEnabled() 在首次申请前就返回
  /// "未启用"（系统不暴露"未决定"态），不能以状态查询作为是否引导的前置
  /// 条件——只要本机没引导过就弹说明框，再触发系统权限申请。
  Future<void> _primeNotificationPermission() async {
    final coordinator = _notificationCoordinator;
    if (coordinator == null || !mounted) return;
    final recorder = const SharedPreferencesNotificationUsageRecorder();
    try {
      final prefs = await SharedPreferences.getInstance();
      // v2：0.3.27 的引导实现有缺陷（Android 13+ 从未真正申请过权限），
      // 升级到本版的设备需要重新引导一次；已授权设备自动跳过。
      if (prefs.getBool('notification.permission_prompted_v2') == true) return;
      await prefs.setBool('notification.permission_prompted_v2', true);
      final status =
          await coordinator.systemNotifications.authorizationStatus();
      // 已授权（Android 12 及以下安装即启用）无需打扰。
      if (status == NotificationAuthorizationStatus.granted) return;
      if (!mounted) return;
      unawaited(recorder.count(NotificationUsageEvents.permissionPrompted));
      final allow = await showCupertinoDialog<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('开启通知'),
          content: const Text('开启通知后，可以及时收到好友消息和通话邀请。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('暂不开启'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('开启通知'),
            ),
          ],
        ),
      );
      if (allow != true) {
        unawaited(recorder.count(NotificationUsageEvents.permissionDenied));
        return;
      }
      final granted =
          await coordinator.systemNotifications.requestAuthorization();
      unawaited(recorder.count(granted
          ? NotificationUsageEvents.permissionGranted
          : NotificationUsageEvents.permissionDenied));
    } catch (_) {
      // 权限引导失败静默，不打扰主流程。
    }
  }

  DateTime? _lastUpdateCheckAt;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_matrixReady) return;
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        state == AppLifecycleState.resumed) {
      unawaited(_refreshIosCallTokens());
    }
    appResumed = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      unawaited(_momentsUnread?.refresh());
      // 规格§四（后台恢复）：收到电话后回前台（点图标/切回）→ 立即
      // 进入通话页——不再"只响铃无页面"。
      final phase = calls.state.phase;
      if (phase == CallPhase.ringing ||
          phase == CallPhase.connecting ||
          phase == CallPhase.connected) {
        callUi.showIncomingCall(calls);
      }
    }
    // 通知决策的前后台维度（PRD §21）。
    notificationAppState.updateLifecycle(
      switch (state) {
        AppLifecycleState.resumed => AppRunState.foreground,
        AppLifecycleState.inactive => AppRunState.inactive,
        _ => AppRunState.background,
      },
    );
    if (appResumed) {
      syncWatchdog.onAppResumed();
      // 通知系统启动失败的重试（此前 catch 注释承诺了重试但不存在）。
      if (_notificationBootstrapper?.needsRetry ?? false) {
        unawaited(_startNotificationSystem());
      }
      // 回前台：推送注册重检（CID 可能已到、网络已恢复、上次失败可
      // 重试——指数退避状态机防重复注册）。
      for (final pusher in _pusherServices) {
        unawaited(pusher.recheck());
      }
      // 回前台：重新检查通知权限（用户可能刚在系统设置中开启/关闭），
      // 记入诊断；设置页打开时亦会自行刷新。
      unawaited(_refreshNotificationPermissionState());
      // 对齐一次桌面角标（PRD §36 reconcile）+ 静默刷新好友资料
      //（BUG 1：好友头像/昵称变化无需重启即可见）。
      unawaited(_notificationCoordinator?.refreshLauncherBadge());
      unawaited(_chatIdentityCache?.refreshContactsQuietly());
      _warmMomentPreviewCache();
      // BUG 2：前台服务可能被系统配额（Android 14+ dataSync 每日上限）
      // 或厂商 ROM 停止；回前台时幂等补启。
      unawaited(syncKeepAlive.ensureStarted());
    } else if (state == AppLifecycleState.paused) {
      callUi.handleAppPaused();
      // 退后台瞬间重申保活（部分系统在切后台时回收前台服务/唤醒锁）。
      unawaited(syncKeepAlive.ensureStarted());
    }
    // 回到前台且仍在响铃：收起全屏来电通知，改由应用内接听页呈现。
    if (appResumed) {
      callUi.handleAppResumed();
    }
    // 用户从后台回到前台时补一次更新检查（30 分钟节流）：
    // 仅靠冷启动会让长期驻留的会话长时间收不到更新提醒。
    if (state != AppLifecycleState.resumed) return;
    final last = _lastUpdateCheckAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 30)) {
      return;
    }
    _lastUpdateCheckAt = DateTime.now();
    unawaited(_checkForAppUpdate());
  }

  Timer? _backgroundCallPermissionTimer;

  Future<void> _primeBackgroundCallPermissions() async {
    _backgroundCallPermissionTimer?.cancel();
    if (!mounted) return;
    final completed = await maybePromptBackgroundCallPermissions(
      context,
      canPresent: () => mounted && appResumed && !callUi.hasActiveCall,
    );
    if (!completed && mounted) {
      _backgroundCallPermissionTimer = Timer(const Duration(seconds: 15), () {
        unawaited(_primeBackgroundCallPermissions());
      });
    }
  }

  Timer? _friendRequestPollTimer;
  FriendRequestWatch? _friendRequestWatch;
  final ValueNotifier<int> pendingFriendRequests = ValueNotifier<int>(0);

  Future<void> _startFriendRequestWatch() =>
      _runStartup(_startFriendRequestWatchFor);

  Future<void> _startFriendRequestWatchFor(int generation) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_currentStartup(generation)) return;
      final notifier = FriendRequestNotifier();
      _friendRequestWatch = FriendRequestWatch(widget.api, prefs,
          notifier: notifier,
          accountKey: widget.matrix.userId ?? '',
          onOutgoingAcceptedChanged: (_) => _refreshAfterFriendChanges(),
          onPendingCount: (count) {
            if (_currentStartup(generation)) {
              pendingFriendRequests.value = count;
            }
          });
      _friendRequestPollTimer?.cancel();
      _friendRequestPollTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_pollFriendRequests()),
      );
      await _pollFriendRequests();
    } catch (_) {
      // 通知巡检失败不能影响主流程。
    }
  }

  /// 好友关系变化后：身份缓存立即重载 → 通讯录/消息页即时刷新。
  Future<void> _refreshAfterFriendChanges() async {
    try {
      final cache = await _identityCache();
      await cache.refresh();
    } catch (_) {}
    pendingFriendRequests.value = pendingFriendRequests.value; // 触发监听重建
    if (mounted) setState(() {});
  }

  Future<void> _pollFriendRequests() async {
    final watch = _friendRequestWatch;
    if (watch == null) return;
    try {
      pendingFriendRequests.value = await watch.poll();
    } catch (_) {
      // 下个周期重试。
    }
    // BUG 1：好友申请轮询周期（60s）顺带静默刷新好友资料——好友改头像
    // 后通讯录/消息页/朋友圈在下个周期内自动更新，禁止等待重启。
    unawaited(_chatIdentityCache?.refreshContactsQuietly());
  }

  void _openFriendRequests() {
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).push(
      CupertinoPageRoute(
        builder: (_) => FriendRequestsPage(
          api: widget.api,
          pendingRequests: pendingFriendRequests,
          directChats: directChats,
          onRequestsChanged: () => unawaited(_refreshAfterFriendChanges()),
          identityCache: _chatIdentityCache,
          // BUG 3：accept 后建立私聊 + 发送好友接受系统消息。
          onEstablishDirectChatWithRequest:
              (matrixUserId, friendUserId, friendDisplayName, request) =>
                  _establishDirectChatAndGreet(
                      matrixUserId, friendDisplayName, request),
        ),
      ),
    );
  }

  /// BUG 3：好友接受后的私聊建立与系统招呼（"你已添加了 XXX…"，
  /// ChatFlow 系统消息类型渲染，绝不伪装成对方普通消息）。
  Future<void> _establishDirectChatAndGreet(
    String matrixUserId,
    String friendDisplayName,
    Map request,
  ) async {
    final cache = await _identityCache();
    await _refreshMissingFriendIdentity(cache, matrixUserId);
    final reference = await directChats.open(matrixUserId);
    await widget.matrix.sendFriendAccepted(
        reference.roomId, matrixUserId, friendDisplayName,
        requestId: request['id']?.toString(),
        requestMessage: request['message']?.toString());
    // The recipient sees request context before this route exposes a composer.
    await _openConversationFromNotification(reference.roomId);
  }

  AppUpdateDeferStore? _deferStore;

  /// 更新后数据完整性校验：版本变化时验证关键本地存储可读，只报告、
  /// 从不清理或重置数据。
  Future<void> _verifyDataIntegrity() async {
    try {
      final report = await UpdateDataIntegrity.verify(
        currentBuild: AppConfig.appBuildNumber,
        checks: [
          UpdateIntegrityCheck('preferences', () async {
            await SharedPreferences.getInstance();
            return true;
          }),
          UpdateIntegrityCheck('secure-session', () async {
            await widget.api.currentMatrixUserId();
            return true;
          }),
        ],
      );
      if (report == null || report.allOk || !mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          key: const Key('update-integrity-warning'),
          title: const Text('数据完整性提醒'),
          content: const Text('版本更新后的例行校验未全部通过。您的数据未被修改或清除，'
              '如遇异常请联系客服。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (_) {
      // Integrity verification must never block the session.
    }
  }

  int _deferredUpdateBuild = 0;

  Future<void> _recordDeferredUpdate(int build) async {
    _deferredUpdateBuild = build;
    try {
      final prefs = await SharedPreferences.getInstance();
      _deferStore ??= AppUpdateDeferStore(prefs);
      await _deferStore!.record(build, DateTime.now());
    } catch (_) {
      // Recording the choice must never break the flow.
    }
  }

  /// Silent best-effort check; network failures must never block the session.
  /// 诊断构建（LIUHETONG_IN_APP_UPDATE=false）整体跳过，避免
  /// "下载 APK 并拉起安装"高危行为参与安全软件误报判定。
  Future<void> _checkForAppUpdate() async {
    if (!AppConfig.inAppUpdateEnabled) return;
    AppUpdateInfo? info;
    try {
      info = parseAppUpdate(await widget.api.latestAppUpdate());
    } catch (_) {
      return;
    }
    final pending = resolvePendingUpdate(
      info: info,
      currentBuild: AppConfig.appBuildNumber,
      currentVersion: AppConfig.appVersionName,
    );
    if (!mounted ||
        pending == null ||
        pending.latestBuild <= _deferredUpdateBuild) {
      return;
    }
    if (!requiresForcedUpdate(pending, AppConfig.appBuildNumber)) {
      await showAppUpdateDialog(
        context,
        info: pending,
        currentBuild: AppConfig.appBuildNumber,
        onDeferred: () => unawaited(_recordDeferredUpdate(pending.latestBuild)),
      );
      return;
    }
    // 强制更新：即使弹窗因任何原因被关闭，也立即重新弹出，直到更新完成。
    while (mounted &&
        pending.latestBuild > _deferredUpdateBuild &&
        requiresForcedUpdate(pending, AppConfig.appBuildNumber)) {
      await showAppUpdateDialog(
        context,
        info: pending,
        currentBuild: AppConfig.appBuildNumber,
      );
    }
  }

  Future<void> _clearAllUnread() async {
    await widget.matrix.conversations.clearAllUnread();
    await _refreshUnreadCount();
  }

  void _bindConnectionStatus() {
    final owner = Object();
    _connectionStatusOwner = owner;
    AppConnectionStatusHub.shared.bind<MatrixConnectionStatus>(
      owner,
      syncWatchdog.connectionStatus,
      (status) => switch (status) {
        MatrixConnectionStatus.unknown => AppConnectionStatus.unknown,
        MatrixConnectionStatus.connecting => AppConnectionStatus.connecting,
        MatrixConnectionStatus.offline => AppConnectionStatus.offline,
        MatrixConnectionStatus.connected => AppConnectionStatus.connected,
        MatrixConnectionStatus.serviceUnavailable =>
          AppConnectionStatus.serviceUnavailable,
      },
      onRetry: syncWatchdog.retry,
    );
  }

  void _disposeSyncWatchdog() {
    if (!_syncWatchdogStarted) return;
    // The hub listener must be removed while the notifier is still valid.
    // Its owner check also prevents an old AppHome close from clearing a new
    // session that has already bound its own watchdog.
    final owner = _connectionStatusOwner;
    if (owner != null) AppConnectionStatusHub.shared.unbind(owner);
    _connectionStatusOwner = null;
    syncWatchdog.dispose();
    _syncWatchdogStarted = false;
  }

  Future<void> _refreshUnreadCount() async {
    final unread = await widget.matrix.conversations.totalUnreadCount();
    if (mounted && unread != _totalUnreadCount) {
      setState(() => _totalUnreadCount = unread);
    }
  }

  Future<void> _initializeMatrixResources() async {
    final resource = await widget.matrix.registerAppHomeResource(
      open: (capability) async {
        if (_disposed) return;
        _matrixHomeCapability = capability;
        callWakeup = capability.createCallWakeupClient(
            Uri.parse(AppConfig.businessApiBaseUrl).resolve('/ios-call/'));
        callBackend = capability.createCallBackend(
            diagnostics: callDiagnostics, wakeup: callWakeup);
        calls = _createCallController();
        final watchdogTarget = capability.createSyncWatchdogTarget();
        syncWatchdog = widget.syncWatchdogFactory?.call(watchdogTarget) ??
            MatrixSyncWatchdog(
              target: watchdogTarget,
              transport: ConnectivityPlusTransportMonitor(),
            );
        syncWatchdog.start();
        _syncWatchdogStarted = true;
        _bindConnectionStatus();
        _startup.open();
        _matrixReady = true;
        _startHomeResources();
        if (mounted) setState(() {});
      },
      close: _closeHomeResources,
    );
    if (_disposed) {
      await resource.cancel();
      return;
    }
    matrixResources = resource;
  }

  Future<MessageReminderSyncCoordinator> _createReminderSync() async {
    final generation = _startup.generation;
    final capability = _matrixHomeCapability;
    if (capability == null) {
      throw StateError('Matrix home capability is unavailable');
    }
    final backend = await capability.openMessageReminderBackend();
    if (!_currentStartup(generation)) {
      await backend.dispose();
      throw StateError('Matrix home initialization was superseded');
    }
    reminderBackend = backend;
    return MessageReminderSyncCoordinator(
      source: backend,
      service: MessageReminderService(
        backend: backend,
        scheduler: FlutterLocalNotificationScheduler(),
      ),
    );
  }

  Future<ProfileRepository> _identityCache() =>
      _chatIdentityCacheLoad ??= _createIdentityCache();

  Future<ProfileRepository> _createIdentityCache() async {
    final accountKey = widget.matrix.userId;
    ProfileRepository cache;
    try {
      final factory = widget.profileRepositoryFactory;
      cache = factory != null
          ? await factory(widget.api, accountKey)
          : accountKey == null
              ? ProfileRepository(widget.api)
              : await ProfileRepository.create(
                  api: widget.api,
                  accountKey: 'matrix:$accountKey',
                );
      await cache.hydrate();
    } catch (_) {
      // 最终兜底：无持久化的内存仓库——页面必须能渲染，
      // 绝不允许消息/通讯录停留在加载态（Mi 6 SQLite 故障教训）。
      cache = ProfileRepository(widget.api, accountKey: accountKey);
    }
    _chatIdentityCache = cache;
    if (mounted) setState(() {});
    unawaited(cache.preload().catchError((_) {}));
    return cache;
  }

  /// 通话状态变化的业务钩子（UI 呈现全部在 CallUiManager）：
  /// 消息提醒抑制 + 主叫通话摘要。
  void _onCallPhaseChangedForBusiness(CallPhase previous, CallPhase next) {
    final active = next == CallPhase.ringing ||
        next == CallPhase.requestingPermission ||
        next == CallPhase.connecting ||
        next == CallPhase.connected;
    notificationAppState.setCallActive(active);
    if (active) {
      unawaited(
          NotificationSystemHandle.coordinator?.cancelPushWakeNotification());
    }
  }

  NativePushBridge? _nativePushBridge;
  MethodChannel? _nativeCallChannel;
  MethodChannel? _nativeCallControl;
  static const _iosCallChannel = MethodChannel('chatflow/ios_calls');
  IosCallCoordinator? _iosCalls;
  StreamSubscription<void>? _iosVideoSubscription;

  Future<void> _initializeIosCalls() => _runStartup(_initializeIosCallsFor);

  Future<void> _initializeIosCallsFor(int generation) async {
    if (!_currentStartup(generation)) return;
    final wakeup = callWakeup;
    final backend = callBackend;
    final controller = calls;
    final watchdog = syncWatchdog;
    Future<Object?> invoke(String method, [Object? args]) =>
        _iosCallChannel.invokeMethod<Object?>(method, {
          if (args is Map) ...Map<String, Object?>.from(args),
          'owner': wakeup.registrationId,
        });
    final coordinator = IosCallCoordinator(
      owner: wakeup.registrationId,
      cancelPendingAnswer: backend.cancelPendingAnswer,
      snapshot: () => IosCallSnapshot(
        callId: backend.activeCallId,
        roomId: backend.activeRoomId,
        phase: controller.state.phase.name,
        incoming: backend.isIncomingCall,
        video: controller.state.type == CallMediaType.video,
        muted: controller.state.muted,
      ),
      invoke: invoke,
      accept: controller.accept,
      end: () async {
        if (controller.state.phase == CallPhase.ringing) {
          await controller.reject();
        } else if (backend.hasActiveSession) {
          await controller.hangup();
        }
      },
      mute: (muted) async {
        if (controller.state.muted != muted) await controller.toggleMute();
      },
      sync: () =>
          watchdog.target.oneShotSync().timeout(const Duration(seconds: 10)),
      registerTokens: (tokens) async {
        if (_currentStartup(generation)) await wakeup.register(tokens);
      },
    );
    _iosCalls = coordinator;
    _iosCallChannel.setMethodCallHandler((call) async {
      if (!_currentStartup(generation)) return false;
      if (call.arguments is! Map ||
          (call.arguments as Map)['owner'] != wakeup.registrationId) {
        return false;
      }
      if (call.method == 'returnToCall') {
        callUi.restoreCall();
        return true;
      }
      return coordinator.handle(call.method, call.arguments);
    });
    _iosVideoSubscription = backend.mediaStreamChanges.listen((_) {
      if (_currentStartup(generation)) unawaited(_refreshIosVideo());
    });
    try {
      await coordinator.start();
    } catch (error) {
      debugPrint(
          '[ios-call] native initialization failed: ${error.runtimeType}');
    }
  }

  Future<Object?> _invokeIosCall(String method, [Object? args]) =>
      _iosCallChannel.invokeMethod<Object?>(method, {
        if (args is Map) ...Map<String, Object?>.from(args),
        'owner': callWakeup.registrationId,
      });

  Future<void> _refreshIosCallTokens() => _runStartup((generation) async {
        final wakeup = callWakeup;
        try {
          final raw = await _invokeIosCall('getTokens');
          if (_currentStartup(generation) && raw is Map) {
            await wakeup.register(Map<String, Object?>.from(raw));
          }
        } catch (_) {/* A later foreground resume retries registration. */}
      });

  Future<void> _refreshIosVideo() async {
    if (!mounted || defaultTargetPlatform != TargetPlatform.iOS) return;
    final stream = calls.state.type == CallMediaType.video &&
            calls.state.phase == CallPhase.connected
        ? callBackend.remoteMediaStream
        : null;
    try {
      await _invokeIosCall('setPipVideo', {
        'streamId': stream?.id,
        'ownerTag': stream?.ownerTag,
      });
    } catch (_) {/* Unsupported PiP does not end a working encrypted call. */}
  }

  /// 原生通话协调器：来电呈现/用户接听/拒绝/冷启动恢复的唯一接线。
  /// （原 _autoAcceptWhenRinging"未来 8 秒出现任何响铃即接听"的宽泛
  /// 逻辑已删除——待接听现在绑定具体通话、有期限与取消条件。）
  late NativeCallCoordinator nativeCalls;
  NativeCallCoordinator _createNativeCalls() => NativeCallCoordinator(
        calls: calls,
        onPresentIncoming: () {
          if (mounted) callUi.showIncomingCall(calls);
        },
        onDismissNativeLayer: _dismissNativeCallLayer,
      );

  void _dismissNativeCallLayer() {
    unawaited(_nativeCallChannel?.invokeMethod('dismiss'));
  }

  Future<void> _nativePresentation(String method) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _invokeIosCall(
            method == 'minimizeCallPresentation' ? 'startPip' : 'stopPip');
        return;
      }
      await _nativeCallControl?.invokeMethod(method);
    } catch (_) {
      // In-app return entry is available even if native overlay is unsupported.
    }
  }

  /// 规格§三：来电委托管理器呈现；摘要落消息；登出经 dispose 清理。
  void _handleCallState() {
    if (!mounted) return;
    // 待接听匹配（用户已在原生层点接听而 Matrix 响铃刚到）+ 状态回报。
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(_iosCalls?.update().catchError((Object error) {
        debugPrint('[ios-call] state update failed: ${error.runtimeType}');
      }));
      unawaited(_refreshIosVideo());
    } else {
      nativeCalls.onCallPhaseChanged();
    }
    final phase = calls.state.phase;
    if (phase == CallPhase.ringing) {
      // 前台：任意页面之上弹出来电页；后台：系统全屏来电通知。
      callUi.showIncomingCall(calls);
    } else if (phase == CallPhase.ended ||
        phase == CallPhase.failed ||
        phase == CallPhase.permissionDenied) {
      // 主叫在结束时落一条通话摘要消息（接通=时长，未接通=已取消），
      // 被叫端经同步收到同一消息，双端会话各显示一条。
      if (_outgoingCallActive && !callSummarySent) {
        callSummarySent = true;
        final connectedAt = calls.state.connectedAt;
        final roomId = calls.state.roomId;
        final type = calls.state.type ?? CallMediaType.audio;
        if (roomId != null) {
          unawaited(callBackend.sendCallSummary(
            roomId: roomId,
            type: type,
            connected: connectedAt != null,
            duration: connectedAt == null
                ? Duration.zero
                : DateTime.now().difference(connectedAt),
          ));
        }
      }
      _outgoingCallActive = false;
    }
  }

  Future<void> _openCall(ContactDetails contact, CallMediaType type) async {
    if (callUi.hasActiveCall) {
      callUi.restoreCall();
      return;
    }
    final presentationToken = Object();
    void releasePresentation() {
      if (identical(_outgoingPresentationToken, presentationToken)) {
        _outgoingPresentationToken = null;
        callPageVisible = false;
      }
    }

    try {
      final cache = await _identityCache();
      await _refreshMissingFriendIdentity(cache, contact.matrixUserId);
      if (!mounted) return;
      final reference = await directChats.open(contact.matrixUserId);
      if (!mounted) return;
      if (callUi.hasActiveCall) {
        callUi.restoreCall();
        return;
      }
      _outgoingPresentationToken = presentationToken;
      callPageVisible = true;
      _outgoingCallActive = true;
      callSummarySent = false;
      callUi.registerOutgoingCall();
      final navigation = Navigator.push(
        context,
        CupertinoPageRoute(
          builder: (pageContext) => CallPage(
            controller: calls,
            displayName: contact.displayName,
            fallbackSeed: contact.username,
            avatarUrl: contact.avatarUrl,
            mediaBackend: callBackend,
            autoCloseOnEnd: true,
            onMinimize: () {
              releasePresentation();
              callUi.minimizeCall();
              Navigator.of(pageContext).pop();
            },
          ),
        ),
      );
      unawaited(navigation.whenComplete(releasePresentation));
      await calls.start(
        roomId: reference.roomId,
        matrixUserId: contact.matrixUserId,
        type: type,
      );
      await navigation;
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('无法发起加密通话'),
          content: const Text('请检查权限和网络后重试。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } finally {
      // Closing presentation never terminates the media session.
      releasePresentation();
    }
  }

  Future<void> _openMessage(ContactDetails contact) async {
    try {
      final cache = await _identityCache();
      await _refreshMissingFriendIdentity(cache, contact.matrixUserId);
      final reference = await directChats.open(contact.matrixUserId);
      await _openManagedRoom(reference.roomId,
          roomName: contact.displayName, initialContact: contact, cache: cache);
    } catch (error) {
      if (!mounted) return;
      await showDirectChatFailureDialog(context, error,
          onRetry: () => _openMessage(contact));
    }
  }

  /// BUG4：通讯录 → 群聊 → 群聊通讯录列表（已 join + saved=true）。
  Future<void> _openGroupAddressList() async {
    await Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (_) => GroupAddressListPage(
          matrix: widget.matrix,
          identityCache: _chatIdentityCache,
          onOpen: (room) {
            Navigator.pop(context);
            unawaited(_openRoomFromAddressList(room));
          },
        ),
      ),
    );
  }

  Future<void> _openRoomFromAddressList(String roomId) =>
      _openManagedRoom(roomId);

  Future<void> _openManagedRoom(String roomId,
      {String? roomName,
      ContactDetails? initialContact,
      ProfileRepository? cache}) async {
    final identityCache = cache ?? await _identityCache();
    final name =
        roomName ?? await widget.matrix.conversations.roomDisplayName(roomId);
    final lease = await widget.matrix.openRoomLease(roomId);
    if (!mounted) {
      await lease.cancel();
      return;
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = CupertinoPageRoute<void>(
        builder: (_) => RoomPage(
              api: widget.api,
              roomLease: lease,
              roomName: name,
              initialContact: initialContact,
              onCreateGroup: _createGroupChat,
              onMessage: _openMessage,
              onVoice: (contact) => _openCall(contact, CallMediaType.audio),
              onVideo: (contact) => _openCall(contact, CallMediaType.video),
              reminderService: reminderService,
              initialIdentityCache: identityCache,
            ));
    lease.setOnRevoked(() async {
      if (route.isActive) {
        navigator.popUntil((candidate) => identical(candidate, route));
        if (route.isCurrent) navigator.pop();
      }
    });
    try {
      await navigator.push(route);
    } finally {
      await lease.cancel();
    }
  }

  void _scanFromTab() {
    Navigator.of(context, rootNavigator: true).push(CupertinoPageRoute(
      fullscreenDialog: true,
      builder: (_) => ScanQrPage(
          api: widget.api,
          groupJoinApi: widget.api,
          onGroupJoined: (roomId) =>
              unawaited(_openConversationFromNotification(roomId))),
    ));
  }

  void _addFriendFromTab() {
    Navigator.of(context, rootNavigator: true).push(CupertinoPageRoute(
      builder: (_) => AddFriendPage(
        api: widget.api,
        identityCache: _chatIdentityCache,
        contactActions: ContactActions(
          onMessage: _openMessage,
          onVoice: (contact) => _openCall(contact, CallMediaType.audio),
          onVideo: (contact) => _openCall(contact, CallMediaType.video),
        ),
      ),
    ));
  }

  Future<void> _createGroupChat() async {
    final matrix = widget.matrix;
    String currentUserDisplayName = '我';
    try {
      final cache = await _identityCache();
      if (!mounted || !identical(matrix, widget.matrix)) return;
      final profile = cache.profile;
      if (profile != null) {
        currentUserDisplayName =
            profile.nickname.isEmpty ? profile.username : profile.nickname;
      }
      unawaited(cache.preload().catchError((_) {}));
    } catch (_) {
      // Group creation remains available when the cached profile is offline.
    }
    if (!mounted) return;
    final controller = GroupChatController(
      contacts: widget.api,
      groups: ServerAutoJoinGroupGateway(api: widget.api, matrix: matrix),
      currentUserDisplayName: currentUserDisplayName,
    );
    final roomId = await Navigator.push<String>(
      context,
      CupertinoPageRoute(
        builder: (pageContext) => GroupChatPage(
          controller: controller,
          onCreated: (createdRoomId) =>
              Navigator.pop(pageContext, createdRoomId),
        ),
      ),
    );
    controller.dispose();
    if (!mounted || roomId == null || !identical(matrix, widget.matrix)) return;
    final roomName = await matrix.conversations.roomDisplayName(roomId);
    final identityCache = await _identityCache();
    if (!mounted || !identical(matrix, widget.matrix)) return;
    final lease = await matrix.openRoomLease(roomId);
    if (!mounted || !identical(matrix, widget.matrix)) {
      await lease.cancel();
      return;
    }
    unawaited(() async {
      try {
        await identityCache.preload();
        if (mounted &&
            identical(matrix, widget.matrix) &&
            identical(identityCache, _chatIdentityCache)) {
          await identityCache.precacheAvatarImages(context,
              shouldContinue: () =>
                  mounted &&
                  identical(matrix, widget.matrix) &&
                  identical(identityCache, _chatIdentityCache));
        }
      } catch (_) {}
    }());
    final navigator = Navigator.of(context, rootNavigator: true);
    late final Route<void> route;
    route = CupertinoPageRoute<void>(
      builder: (_) => RoomPage(
        api: widget.api,
        roomLease: lease,
        roomName: roomName,
        onCreateGroup: _createGroupChat,
        onMessage: _openMessage,
        onVoice: (contact) => _openCall(contact, CallMediaType.audio),
        onVideo: (contact) => _openCall(contact, CallMediaType.video),
        reminderService: reminderService,
        initialIdentityCache: identityCache,
      ),
    );
    lease.setOnRevoked(() async {
      if (route.isActive) {
        navigator.popUntil((candidate) => identical(candidate, route));
        navigator.removeRoute(route);
      }
      await route.popped;
    });
    try {
      await navigator.push(route);
    } finally {
      await lease.cancel();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _unreadSubscription?.cancel();
    _friendRequestPollTimer?.cancel();
    _friendRequestPollTimer = null;
    _backgroundCallPermissionTimer?.cancel();
    _backgroundCallPermissionTimer = null;
    _disposeSyncWatchdog();
    directChats.dispose();
    pendingFriendRequests.dispose();
    unawaited(_disposeMatrixResources());
    super.dispose();
  }

  Future<void> _closeHomeResources() async {
    if (!_matrixReady) return;
    _matrixReady = false;
    await _startup.close();
    Future<void> stop(FutureOr<void> Function() operation) async {
      try {
        await operation();
      } catch (_) {
        widget.matrix.securityLogger.record(
          stage: MatrixSecurityStage.lifecycle,
          outcome: MatrixSecurityOutcome.failure,
          eventCode: MatrixSecurityCode.homeResourceDisposeFailed,
        );
      }
    }

    _momentsUnread?.dispose();
    _momentsUnread = null;
    _friendRequestPollTimer?.cancel();
    _backgroundCallPermissionTimer?.cancel();
    await stop(() async {
      await _nativePushBridge?.uninstall();
    });
    calls.removeListener(_handleCallState);
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _iosCallChannel.setMethodCallHandler(null);
      await stop(() async {
        await _iosVideoSubscription?.cancel();
      });
      await stop(() async {
        await _iosCalls?.dispose();
      });
      await stop(() async {
        await callWakeup.unregister();
      });
    } else {
      await stop(() async {
        await nativeCalls.dispose();
      });
      _nativeCallControl?.setMethodCallHandler(null);
    }
    callWakeup.close();
    await stop(() async {
      await callUi.detach();
    });
    calls.dispose();
    await stop(() async {
      await callBackend.dispose();
    });
    await stop(() async {
      await syncKeepAlive.stop();
    });
    _disposeSyncWatchdog();
    await stop(() async {
      await reminderBootstrap?.dispose();
    });
    reminderBootstrap = null;
    await stop(() async {
      await reminderBackend?.dispose();
    });
    reminderBackend = null;
    reminderService = null;
    NotificationFeedback.uninstall();
    NotificationSystemHandle.uninstall();
    await stop(() async {
      await _notificationBootstrapper?.dispose();
    });
    await stop(() async {
      await _notificationEventSource?.stop();
    });
    await stop(() async {
      await _notificationCoordinator?.dispose();
    });
    _notificationBootstrapper = null;
    _notificationEventSource = null;
    _notificationCoordinator = null;
    _pushTapRouter?.reset();
    _pushTapRouter = null;
    for (final pusher in _pusherServices) {
      await stop(() async {
        await pusher.unregister();
      });
      await stop(() async {
        await pusher.dispose();
      });
    }
    _pusherServices.clear();
    PushStatusRegistry.shared.clear();
    for (final provider in _pushTokenProviders) {
      await stop(() async {
        await provider.dispose();
      });
    }
    _pushTokenProviders.clear();
    _matrixHomeCapability = null;
    if (_disposed) await stop(notificationSounds.dispose);
    if (mounted) setState(() {});
  }

  /// 系统通知点击统一分发：只有 presenter 注册一次插件回调（最后
  /// initialize 者胜出——此前好友申请/通话/保活各自 initialize 互相
  /// 覆盖，消息通知点击被劫持或失效）。
  void _handleNotificationTap(String payload) {
    if (!mounted) return;
    routeSystemNotificationPayload(
      payload,
      openConversation: (roomId) =>
          unawaited(_openConversationFromNotification(roomId)),
      openFriendRequests: _openFriendRequests,
      openCall: callUi.restoreCall,
    );
  }

  /// 横幅/通知/推送点击进入会话（PRD §7）：优先复用本地身份缓存与既有的
  /// RoomPage 组装路径，头像未就绪先用占位，不为导航等待网络。
  ///
  /// 冷启动（推送点击拉起进程）：房间可能尚未进入首次同步——短暂等待
  /// 房间就绪后再进入，避免点击"无反应"。
  Future<void> _openConversationFromNotification(String roomId) async {
    try {
      await widget.matrix
          .waitForRoom(roomId)
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      unawaited(const SharedPreferencesNotificationUsageRecorder()
          .count(NotificationUsageEvents.opened));
      await _openManagedRoom(roomId);
    } catch (_) {
      // Preserve the current route when a pushed room has not synced yet.
    }
  }

  Widget _contactsBadge(Widget icon) => ValueListenableBuilder<int>(
        valueListenable: pendingFriendRequests,
        builder: (_, count, child) => Stack(clipBehavior: Clip.none, children: [
          icon,
          if (count > 0)
            Positioned(
                right: -10,
                top: -4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                      color: CupertinoColors.systemRed,
                      borderRadius: BorderRadius.circular(10)),
                  child: Text(count > 99 ? '99+' : '$count',
                      style: const TextStyle(
                          color: CupertinoColors.white, fontSize: 10)),
                )),
        ]),
      );

  Future<void> _disposeMatrixResources() async {
    try {
      await _matrixResourceSetup;
    } catch (_) {
      return;
    }
    final resource = matrixResources;
    matrixResources = null;
    try {
      await resource?.cancel();
    } catch (_) {
      widget.matrix.securityLogger.record(
        stage: MatrixSecurityStage.lifecycle,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.homeResourceDisposeFailed,
      );
    }
  }

  @override
  Widget build(BuildContext context) => !_matrixReady
      ? const Center(child: CupertinoActivityIndicator())
      : Stack(
          children: [
            CupertinoTabScaffold(
              tabBar: CupertinoTabBar(
                onTap: (index) {
                  if (index == 2) unawaited(_momentsUnread?.refresh());
                  if (index == 0) unawaited(_refreshUnreadCount());
                },
                activeColor: const Color(0xff07c160),
                items: [
                  BottomNavigationBarItem(
                    icon: MessagesTabIcon(
                      unreadCount: _totalUnreadCount,
                      active: false,
                      onClearUnread: _clearAllUnread,
                    ),
                    activeIcon: MessagesTabIcon(
                      unreadCount: _totalUnreadCount,
                      active: true,
                      onClearUnread: _clearAllUnread,
                    ),
                    label: '消息',
                  ),
                  BottomNavigationBarItem(
                    icon: _contactsBadge(const Icon(ChangliaoIcons.contacts)),
                    activeIcon: _contactsBadge(
                        const Icon(ChangliaoIcons.contactsFilled)),
                    label: '通讯录',
                  ),
                  const BottomNavigationBarItem(
                    icon: Icon(ChangliaoIcons.discover),
                    activeIcon: Icon(ChangliaoIcons.discoverFilled),
                    label: '发现',
                  ),
                  const BottomNavigationBarItem(
                    icon: Icon(ChangliaoIcons.me),
                    activeIcon: Icon(ChangliaoIcons.meFilled),
                    label: '我',
                  ),
                ],
              ),
              tabBuilder: (_, index) => CupertinoTabView(
                builder: (_) => switch (index) {
                  0 => MatrixHomePage(
                      api: widget.api,
                      matrix: widget.matrix,
                      themeController: widget.themeController,
                      onCreateGroup: _createGroupChat,
                      onMessage: _openMessage,
                      onVoice: (contact) =>
                          _openCall(contact, CallMediaType.audio),
                      onVideo: (contact) =>
                          _openCall(contact, CallMediaType.video),
                      reminderService: reminderService,
                      identityCache: _chatIdentityCache,
                      onUnreadChanged: () => unawaited(_refreshUnreadCount()),
                    ),
                  1 => _chatIdentityCache == null
                      ? const Center(child: CupertinoActivityIndicator())
                      : ContactsTabPage(
                          api: widget.api,
                          matrix: widget.matrix,
                          pendingFriendRequests: pendingFriendRequests,
                          onFriendRequests: _openFriendRequests,
                          directChats: directChats,
                          onVoice: (contact) =>
                              _openCall(contact, CallMediaType.audio),
                          onVideo: (contact) =>
                              _openCall(contact, CallMediaType.video),
                          onGroupChat: _createGroupChat,
                          onScan: _scanFromTab,
                          onAppearance: () => showThemePickerSheet(
                              context, widget.themeController),
                          onGroupAddressList: _openGroupAddressList,
                          reminderService: reminderService,
                          identityCache: _chatIdentityCache,
                        ),
                  2 => DiscoveryPage(
                      contactActions: ContactActions(
                        onMessage: _openMessage,
                        onVoice: (contact) =>
                            _openCall(contact, CallMediaType.audio),
                        onVideo: (contact) =>
                            _openCall(contact, CallMediaType.video),
                      ),
                      onCreateGroup: _createGroupChat,
                      onAddFriend: _addFriendFromTab,
                      onScan: _scanFromTab,
                      onAppearance: () =>
                          showThemePickerSheet(context, widget.themeController),
                      unreadController: _momentsUnread,
                      matrix: widget.matrix,
                      api: widget.api,
                      identityCache: _chatIdentityCache,
                    ),
                  _ => ProfileTabPage(
                      contactActions: ContactActions(
                        onMessage: _openMessage,
                        onVoice: (contact) =>
                            _openCall(contact, CallMediaType.audio),
                        onVideo: (contact) =>
                            _openCall(contact, CallMediaType.video),
                      ),
                      api: widget.api,
                      onLogout: widget.onLogout,
                      onClearLocalChatData: widget.matrix.clearLocalChatData,
                      identityCache: _chatIdentityCache,
                    ),
                },
              ),
            ),
            // 来电页不再作为 Stack 覆盖层：CallUiManager 经根 Navigator
            // （callNavigatorKey）推送，任意推入路由/子页面也盖不住。
            // 应用内通知横幅：覆盖在 Tab 内容之上（PRD §7/§40）。
            InAppBannerOverlay(
              controller: notificationBanners,
              onOpenConversation: (conversationId) =>
                  unawaited(_openConversationFromNotification(conversationId)),
            ),
            const Positioned(
                left: 0,
                right: 0,
                bottom: 64,
                child: NotificationReadinessBanner()),
          ],
        );
}

// Existing contacts use the hydrated snapshot immediately. A newly accepted
// contact must be resolved through the business API before room lookup, so the
// canonical directory and RoomPage share the same current identity projection.
Future<void> _refreshMissingFriendIdentity(
    ProfileRepository cache, String matrixUserId) async {
  await cache.hydrate();
  if (cache.contactsByMatrixId.containsKey(matrixUserId)) return;
  if (cache.profile == null) await cache.preload();
  if (!cache.contactsByMatrixId.containsKey(matrixUserId)) {
    try {
      await cache.refreshContactsQuietly(minInterval: Duration.zero);
    } catch (_) {
      // 断网时静默：本地已有该好友映射即可继续打开会话。
    }
  }
  if (!cache.contactsByMatrixId.containsKey(matrixUserId)) {
    throw StateError('The contact is no longer a current friend');
  }
}

final class ContactsTabPage extends StatefulWidget {
  const ContactsTabPage({
    super.key,
    required this.api,
    required this.matrix,
    required this.directChats,
    required this.onVoice,
    required this.onVideo,
    required this.onGroupChat,
    this.onScan,
    this.onAppearance,
    this.onGroupAddressList,
    this.onFriendRequests,
    required this.pendingFriendRequests,
    this.reminderService,
    this.identityCache,
  });
  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final DirectChatController directChats;
  final ContactAction onVoice;
  final ContactAction onVideo;
  final VoidCallback onGroupChat;
  final VoidCallback? onScan, onAppearance;

  /// BUG4：通讯录"群聊"入口 → 群聊通讯录列表。
  final VoidCallback? onGroupAddressList;
  final VoidCallback? onFriendRequests;
  final ValueNotifier<int> pendingFriendRequests;
  final MessageReminderService? reminderService;
  final ProfileRepository? identityCache;

  @override
  State<ContactsTabPage> createState() => _ContactsTabPageState();
}

final class _ContactsTabPageState extends State<ContactsTabPage> {
  Future<void> _openMessage(ContactDetails contact) async {
    try {
      final identityCache =
          widget.identityCache ?? ProfileRepository(widget.api);
      await _refreshMissingFriendIdentity(identityCache, contact.matrixUserId);
      final reference = await widget.directChats.open(contact.matrixUserId);
      final lease = await widget.matrix.openRoomLease(reference.roomId);
      if (!mounted) {
        await lease.cancel();
        return;
      }
      final navigator = Navigator.of(context, rootNavigator: true);
      late final Route<void> route;
      route = CupertinoPageRoute<void>(
        builder: (_) => RoomPage(
          api: widget.api,
          roomLease: lease,
          roomName: contact.displayName,
          initialContact: contact,
          onCreateGroup: widget.onGroupChat,
          onMessage: _openMessage,
          onVoice: widget.onVoice,
          onVideo: widget.onVideo,
          reminderService: widget.reminderService,
          initialIdentityCache: identityCache,
        ),
      );
      lease.setOnRevoked(() async {
        if (route.isActive) {
          navigator.popUntil((candidate) => identical(candidate, route));
          navigator.removeRoute(route);
        }
        await route.popped;
      });
      try {
        await navigator.push(route);
      } finally {
        await lease.cancel();
      }
    } catch (error) {
      if (!mounted) return;
      await showDirectChatFailureDialog(context, error,
          onRetry: () => _openMessage(contact));
    }
  }

  @override
  Widget build(BuildContext context) => ContactsPage(
        api: widget.api,
        matrix: widget.matrix,
        pendingFriendRequests: widget.pendingFriendRequests,
        directChats: widget.directChats,
        onFriendRequests: widget.onFriendRequests,
        identityCache: widget.identityCache,
        onMessage: _openMessage,
        onVoice: widget.onVoice,
        onVideo: widget.onVideo,
        onGroupChat: widget.onGroupChat,
        onScan: widget.onScan,
        onAppearance: widget.onAppearance,
        onGroupAddressList: widget.onGroupAddressList,
      );
}

final class ProfileTabPage extends StatefulWidget {
  const ProfileTabPage({
    super.key,
    required this.api,
    required this.onLogout,
    this.onClearLocalChatData,
    this.identityCache,
    this.contactActions,
  });
  final BusinessApiClient api;
  final ContactActions? contactActions;
  final Future<void> Function() onLogout;
  final ProfileRepository? identityCache;
  final Future<void> Function()? onClearLocalChatData;
  @override
  State<ProfileTabPage> createState() => _ProfileTabPageState();
}

/// 点钻页右上角/查看全部 → 全部账单页（复用既有账单列表）。
void _openLedgerAllBills(BuildContext context, BusinessApiClient? api) {
  if (api == null) return;
  Navigator.of(context).push(CupertinoPageRoute<void>(
      builder: (_) => LedgerListPage(gateway: BusinessLedgerGateway(api))));
}

final class _ProfileTabPageState extends State<ProfileTabPage> {
  late ProfileController controller;
  late BusinessApiClient _controllerApi;
  late int _controllerSessionEpoch;
  String? _controllerAccountKey;

  @override
  void initState() {
    super.initState();
    controller = _createController();
  }

  ProfileController _createController() {
    final api = widget.api;
    final sessionEpoch = api.sessionEpoch;
    final cache = widget.identityCache;
    _controllerApi = api;
    _controllerSessionEpoch = sessionEpoch;
    _controllerAccountKey = cache?.accountKey;
    bool ownsCurrentSession() =>
        mounted &&
        identical(widget.api, api) &&
        api.sessionEpoch == sessionEpoch &&
        identical(widget.identityCache, cache) &&
        cache?.accountKey == _controllerAccountKey;
    return ProfileController(
      gateway: api,
      avatarSource: GalleryAvatarSource(
        brightnessProvider: () => CupertinoTheme.brightnessOf(context),
      ),
      readCachedProfile: () async {
        if (!ownsCurrentSession() || cache == null) return null;
        await cache.hydrate();
        return ownsCurrentSession() ? cache.profile : null;
      },
      persistProfile: (profile) async {
        if (!ownsCurrentSession() || cache == null) return;
        await cache.applyUpdatedProfile(profile);
      },
      onAvatarUpdated: _refreshAvatarDisplays,
      initialProfile: cache?.profile,
    );
  }

  @override
  void didUpdateWidget(covariant ProfileTabPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(_controllerApi, widget.api) ||
        _controllerSessionEpoch != widget.api.sessionEpoch ||
        !identical(oldWidget.identityCache, widget.identityCache) ||
        _controllerAccountKey != widget.identityCache?.accountKey) {
      controller.dispose();
      controller = _createController();
    }
  }

  void _refreshAvatarDisplays() {
    unawaited(widget.identityCache?.refresh());
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProfileExperiencePage(
      key: ObjectKey(controller),
      controller: controller,
      onMoments: () async {
        final cache = widget.identityCache;
        if (cache == null) return;
        final page = await MomentsPage.prepare(
          api: widget.api,
          identityCache: cache,
          contactActions: widget.contactActions,
        );
        if (!context.mounted) return;
        Navigator.of(context, rootNavigator: true).push(
            CupertinoPageRoute(fullscreenDialog: true, builder: (_) => page));
      },
      onCaibi: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => CaibiPage(
                  api: widget.api,
                  onOpenAllBills: () => _openLedgerAllBills(context, widget.api)))),
      onWallet: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => CupertinoPageScaffold(
                  navigationBar: CupertinoNavigationBar(
                      automaticBackgroundVisibility: false,
                      enableBackgroundFilterBlur: false,
                      middle: Text('钱包')),
                  child: WalletPage(api: widget.api)))),
      inviteGateway: widget.api,
      onInvite: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => InviteCodePage(
                  controller: InviteCodeController(gateway: widget.api)))),
      onQrCode: () {
        final profile = controller.state.profile;
        if (profile == null) return;
        Navigator.push(context,
            CupertinoPageRoute(builder: (_) => MyQrCodePage(profile: profile)));
      },
      onSettings: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => SettingsPage(
                  api: widget.api,
                  onLogout: widget.onLogout,
                  onClearLocalChatData: widget.onClearLocalChatData))));
}

final class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    required this.api,
    required this.onLogout,
  });

  final BusinessApiClient api;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('我')),
        child: SafeArea(
          child: ListView(
            children: [
              const SizedBox(height: 16),
              WeChatListTile(
                leading: const Icon(CupertinoIcons.money_dollar_circle_fill),
                title: const Text('点钻'),
                onTap: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => CaibiPage(
                      api: api,
                      onOpenAllBills: () => _openLedgerAllBills(context, api),
                    ),
                  ),
                ),
              ),
              WeChatListTile(
                leading: const Icon(CupertinoIcons.creditcard_fill),
                title: const Text('钱包'),
                onTap: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => CupertinoPageScaffold(
                      navigationBar: CupertinoNavigationBar(
                          automaticBackgroundVisibility: false,
                          enableBackgroundFilterBlur: false,
                          middle: Text('钱包')),
                      child: WalletPage(api: api),
                    ),
                  ),
                ),
              ),
              WeChatListTile(
                leading: const Icon(CupertinoIcons.settings),
                title: const Text('设置'),
                onTap: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => SettingsPage(api: api, onLogout: onLogout),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

final class SettingsPage extends StatefulWidget {
  const SettingsPage(
      {super.key,
      required this.api,
      required this.onLogout,
      this.onClearLocalChatData});

  final BusinessApiClient api;
  final Future<void> Function() onLogout;
  final Future<void> Function()? onClearLocalChatData;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<SettingsPage> {
  bool _loggingOut = false;

  Future<void> _confirmLogout(BuildContext context) async {
    if (_loggingOut) return;
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    var deleteRequested = false;
    var loggedOut = false;
    setState(() => _loggingOut = true);
    try {
      final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('退出登录'),
          content: const Text('退出后将清除本设备的登录状态。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('退出登录'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      final delete = await showCupertinoDialog<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('是否删除本机聊天记录？'),
          content: const Text('保存可在重新登录后继续查看。删除会清除本机聊天数据与加密密钥；未备份的记录可能无法恢复。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('保存'),
            ),
            if (widget.onClearLocalChatData != null)
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确认删除',
                    style: TextStyle(
                        color: CupertinoColors.systemRed,
                        fontWeight: FontWeight.bold)),
              ),
          ],
        ),
      );
      if (delete == null || !context.mounted) return;
      // Both dialogs close before lifecycle teardown. Keep the existing explicit
      // local-clear API so the account-clear/login continuity repair remains intact.
      if (delete) {
        deleteRequested = true;
        try {
          await widget.onClearLocalChatData!();
        } finally {
          // Clear revokes home resources before disk work. Even if disk work
          // fails, leave the authentication gate closed instead of a dead home.
          await widget.onLogout();
          loggedOut = true;
        }
      } else {
        await widget.onLogout();
      }
    } catch (_) {
      if (!rootNavigator.mounted) return;
      await showCupertinoDialog<void>(
        context: rootNavigator.context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title:
              Text(deleteRequested && loggedOut ? '已退出登录，本机数据未完全删除' : '退出未完成'),
          content: const Text('本机操作未完成，请重试。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            )
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('设置')),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              _SettingsTile(
                icon: CupertinoIcons.info_circle,
                label: '账号与隐私',
                onTap: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => AccountPrivacyPage(api: widget.api),
                  ),
                ),
              ),
              _SettingsTile(
                icon: CupertinoIcons.bell,
                label: '消息通知',
                detail: '通知与声音',
                onTap: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => NotificationSettingsPage(
                      coordinator: NotificationSystemHandle.coordinator,
                    ),
                  ),
                ),
              ),
              _SettingsTile(
                icon: CupertinoIcons.wind,
                label: '减少动态效果',
                detail: '跟随系统',
                onTap: () {},
              ),
              _SettingsTile(
                icon: CupertinoIcons.info,
                label: '关于畅聊',
                detail: 'V${AppConfig.appVersionName}',
                onTap: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => AboutChangliaoPage(api: widget.api),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              SizedBox(
                height: 48,
                child: CupertinoButton(
                  color:
                      CupertinoTheme.of(context).brightness == Brightness.dark
                          ? WeChatColors.darkElevated
                          : WeChatColors.lightElevated,
                  borderRadius: BorderRadius.circular(14),
                  padding: EdgeInsets.zero,
                  onPressed: _loggingOut ? null : () => _confirmLogout(context),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        CupertinoIcons.xmark,
                        size: 20,
                        color: WeChatColors.danger,
                      ),
                      SizedBox(width: 8),
                      Text(
                        '退出登录',
                        style: TextStyle(
                          fontSize: 16,
                          color: WeChatColors.danger,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

final class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.detail,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final foreground =
        dark ? WeChatColors.darkTextPrimary : WeChatColors.lightTextPrimary;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Container(
        height: 57,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: dark ? WeChatColors.darkElevated : WeChatColors.lightElevated,
          border: Border(
            bottom: BorderSide(
              width: .5,
              color: dark ? WeChatColors.darkDivider : WeChatColors.divider,
            ),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: Icon(icon, size: 20, color: foreground),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 16, color: foreground),
              ),
            ),
            if (detail != null)
              Text(
                detail!,
                style: const TextStyle(
                  fontSize: 12,
                  color: WeChatColors.textSecondary,
                ),
              ),
            const SizedBox(width: 4),
            const Icon(
              CupertinoIcons.chevron_right,
              size: 12,
              color: WeChatColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

final class AccountPrivacyPage extends StatefulWidget {
  const AccountPrivacyPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<AccountPrivacyPage> createState() => _AccountPrivacyPageState();
}

final class _AccountPrivacyPageState extends State<AccountPrivacyPage> {
  bool enabled = true;
  bool loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      enabled = await widget.api.autoAllowGroupJoin();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _update(bool value) async {
    setState(() => enabled = value);
    try {
      await widget.api.setAutoAllowGroupJoin(value);
    } catch (_) {
      if (mounted) setState(() => enabled = !value);
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text('账号与隐私'),
        ),
        child: SafeArea(
            child: loading
                ? const Center(child: CupertinoActivityIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    children: [
                      WeChatListTile(
                        title: const Text('是否自动允许加入群聊'),
                        subtitle: const Text('开启后，好友创建群聊时将自动加入'),
                        trailing:
                            CupertinoSwitch(value: enabled, onChanged: _update),
                      )
                    ],
                  )),
      );
}
