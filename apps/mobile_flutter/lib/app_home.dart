import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/business_api_client.dart';
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
import 'features/contacts/contact_models.dart';
import 'features/discovery/discovery_page.dart';
import 'features/moments/moments_page.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart' show Membership, Room;
import 'features/matrix/direct_chat_controller.dart';
import 'features/matrix/matrix_direct_chat_adapter.dart';
import 'features/matrix/matrix_sync_watchdog.dart';
import 'features/matrix/matrix_home_page.dart';
import 'features/matrix/room_page.dart';
import 'features/matrix/profile_repository.dart';
import 'features/matrix/group_chat_controller.dart';
import 'features/matrix/group_chat_page.dart';
import 'features/matrix/server_auto_join_group_gateway.dart';
import 'features/matrix/call_alerts.dart';
import 'features/matrix/call_controller.dart';
import 'features/matrix/call_diagnostics.dart';
import 'features/matrix/call_permissions.dart';
import 'features/matrix/call_notifications.dart';
import 'features/matrix/call_page.dart';
import 'features/matrix/matrix_call_adapter.dart';
import 'features/matrix/matrix_message_reminder_backend.dart';
import 'features/matrix/matrix_notification_event_source.dart';
import 'features/matrix/matrix_room_timeline_adapter.dart'
    show changliaoFriendAcceptedEventType, friendAcceptedSystemMessage;
import 'features/matrix/message_reminder_service.dart';
import 'features/push/firebase_push_token_provider.dart';
import 'core/privacy_consent.dart';
import 'features/push/firebase_push_wiring.dart';
import 'features/push/getui_push_token_provider.dart';
import 'features/push/matrix_pusher_service.dart';
import 'features/push/push_tap_router.dart';
import 'features/push/push_token_provider.dart';
import 'features/wallet/wallet_page.dart';
import 'ui/components/wechat_list_tile.dart';
import 'ui/foundation/changliao_icons.dart';
import 'ui/foundation/wechat_tokens.dart';
import 'ui/theme/theme_controller.dart';
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

final class AppHome extends StatefulWidget {
  const AppHome({
    super.key,
    required this.api,
    required this.matrix,
    required this.onLogout,
    required this.themeController,
  });

  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final Future<void> Function() onLogout;
  final ThemeController themeController;

  @override
  State<AppHome> createState() => _AppHomeState();
}

final class _AppHomeState extends State<AppHome> with WidgetsBindingObserver {
  late final DirectChatController directChats = DirectChatController(
    // Canonical Direct Conversation（好友系统重构 Phase E）：
    // 创建私聊前先查规范房间复用；不存在才 startDirectChat 新建并注册。
    CanonicalDirectChatGateway(
      inner: widget.matrix,
      directory: _ApiCanonicalDirectRoomDirectory(widget.api),
      businessUserIdOf: (matrixUserId) =>
          _chatIdentityCache?.contactsByMatrixId[matrixUserId]?.userId,
      openExistingRoom: _openCanonicalDirectRoom,
    ),
  );

  /// 打开规范登记的私聊房间：受邀未加入时先加入；对端建的房间我方
  /// m.direct 可能缺失，补写后房间才具备 DM 语义（否则渲染成"群聊"，
  /// 且后续 invite 扫描无法识别）；最后做加密+双人校验。
  Future<DirectChatRoom> _openCanonicalDirectRoom(String roomId) async {
    final client = widget.matrix.sdkClient;
    var room = client.getRoomById(roomId);
    if (room == null || room.membership != Membership.join) {
      try {
        await room?.join();
      } catch (_) {
        // 可能已在 join 中；下方等待同步兜底。
      }
      await client.waitForRoomInSync(roomId, join: true);
      room = client.getRoomById(roomId);
    }
    final backend = MatrixDirectChatBackend(client);
    var snapshot = await backend.waitForRoom(roomId);
    final target = snapshot.participantIds
        .firstWhere((id) => id != client.userID, orElse: () => '');
    if (target.isNotEmpty &&
        (room?.isDirectChat != true || room?.directChatMatrixID != target)) {
      try {
        await Room(id: roomId, client: client).addToDirectChat(target);
        await client.waitForRoomInSync(roomId, join: true);
        room = client.getRoomById(roomId);
        snapshot = await backend.waitForRoom(roomId);
      } catch (_) {
        // m.direct 补写失败不阻断打开；下次进入会再次补写。
      }
    }
    final service = DirectChatService(backend);
    return service.openExisting(snapshot.roomId, target);
  }

  /// 通话关键路径诊断：backend（invite/answer/ICE）与 controller
  /// （UI 展示/点击接听）共享同一时间线。
  late final CallDiagnostics callDiagnostics = CallDiagnostics();
  late final MatrixCallBackend callBackend = MatrixCallBackend(
    widget.matrix.sdkClient,
    diagnostics: callDiagnostics,
  );
  late final ForegroundSoundService notificationSounds =
      ForegroundSoundService();
  late final CallController calls = CallController(
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
        audible: () => appResumed || !incomingCallActive,
      ),
    ),
  );
  bool callPageVisible = false;
  bool incomingCallActive = false;
  bool appResumed = true;

  /// 本次通话摘要是否已发送：ended 分支可能随 notifyListeners 多次进入，
  /// 必须去重，确保一次通话只落一条通话状态气泡。
  bool callSummarySent = false;
  late final CallNotifications callNotifications = CallNotifications(
    arbiter: foregroundArbiter,
  );
  MessageReminderService? reminderService;
  late final MessageReminderSyncBootstrapper reminderBootstrap;

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
  late final MatrixSyncWatchdog syncWatchdog = MatrixSyncWatchdog(
    target: ClientSyncWatchdogTarget(widget.matrix.sdkClient),
  );
  MatrixNotificationEventSource? _notificationEventSource;

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
  Future<ProfileRepository>? _chatIdentityCacheLoad;

  @override
  void initState() {
    super.initState();
    calls.addListener(_callChanged);
    reminderBootstrap = MessageReminderSyncBootstrapper(
      retries: widget.matrix.sdkClient.onSync.stream.map<void>((_) {}),
      create: _createReminderSync,
      onReady: (coordinator) {
        if (mounted) setState(() => reminderService = coordinator.service);
      },
    );
    unawaited(reminderBootstrap.start());
    unawaited(_identityCache());
    unawaited(_verifyDataIntegrity());
    unawaited(_checkForAppUpdate());
    unawaited(_startFriendRequestWatch());
    // 通知系统登录会话内只启动一次（保活/看门狗/引导在其就绪后接力）。
    // 历史缺陷：这里曾并发调用两次 _startNotificationSystem，产生两套
    // eventSource/coordinator/dedup，首套泄漏整个会话（双声/双震/双通知）。
    unawaited(_startNotificationSystem());
    WidgetsBinding.instance.addObserver(this);
  }

  /// 组装并启动统一通知协调器（PRD §2/§22）。
  ///
  /// 启动失败不抛出：bootstrapper 置 needsRetry 并记录诊断，下一次
  /// 生命周期恢复（didChangeAppLifecycleState）重试。
  Future<void> _startNotificationSystem() async {
    unawaited(NotificationDiagnostics.shared.ensureLoaded());
    final bootstrapper =
        _notificationBootstrapper ??= NotificationSystemBootstrapper(
      start: _assembleNotificationSystem,
      stop: () async {
        await _notificationEventSource?.stop();
        await _notificationCoordinator?.dispose();
      },
      onReady: () {
        final coordinator = _notificationCoordinator;
        if (coordinator == null) return;
        NotificationFeedback.install(coordinator.playUiSound);
        NotificationSystemHandle.install(coordinator);
      },
    );
    final ready = await bootstrapper.ensureStarted();
    if (!ready) return;
    // 前台服务保活必须在通知系统就绪后启动（权限/渠道先行）。
    await syncKeepAlive.ensureStarted();
    syncWatchdog.start();
    unawaited(() async {
      await _primeBatteryOptimization();
      await _primeNotificationPermission();
    }());
    unawaited(_startPushIntegration());
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
  Future<void> _startPushIntegration() async {
    final client = widget.matrix.sdkClient;
    final store = _sharedDedupStore ??=
        await SharedPreferencesNotificationDedupStore.create();
    final deduplicator = _sharedDeduplicator ??= NotificationDeduplicator(
      store: store,
      ttl: SharedPreferencesNotificationDedupStore.defaultTtl,
    );
    final router = _pushTapRouter ??= PushTapRouter(
      openConversation: (roomId) =>
          mounted ? _openConversationFromNotification(roomId) : Future.value(),
      deduplicator: deduplicator,
    );
    // 冷启动由通知点击拉起（含常规消息通知与推送兜底通知）。
    unawaited(routeNotificationLaunch(tapRouter: router));

    final pushers = <MatrixPusherService>[];

    // ① Android 个推通道（隐私同意前置；未同意只影响推送，不影响聊天）。
    if (defaultTargetPlatform == TargetPlatform.android &&
        AppConfig.getuiPushGatewayUrl.isNotEmpty &&
        await SharedPreferencesPrivacyConsentStore().accepted()) {
      final getuiGateway =
          Uri.tryParse(AppConfig.getuiPushGatewayUrl);
      if (getuiGateway != null) {
        final getui = GetuiPushTokenProvider();
        await getui.initialize();
        _pushTokenProviders.add(getui);
        pushers.add(MatrixPusherService(
          gateway: ClientMatrixPusherGateway(client),
          tokenProvider: getui,
          appId: MatrixPusherService.appIdGetui,
          gatewayUrl: getuiGateway.resolve('_matrix/push/v1/getui/notify'),
          deviceDisplayName: 'ChatFlow Android',
        ));
      }
    }

    // ② FCM/Sygnal 通道（原有行为不变）。
    final gatewayUrl = AppConfig.sygnalPushGatewayUrl.isEmpty
        ? null
        : Uri.tryParse(AppConfig.sygnalPushGatewayUrl);
    final firebase = await FirebasePushTokenProvider.tryCreate();
    if (firebase != null) {
      _pushTokenProviders.add(firebase);
      pushers.add(MatrixPusherService(
        gateway: ClientMatrixPusherGateway(client),
        tokenProvider: firebase,
        appId: defaultTargetPlatform == TargetPlatform.iOS
            ? MatrixPusherService.appIdIOS
            : MatrixPusherService.appIdAndroid,
        gatewayUrl: gatewayUrl?.resolve('_matrix/push/v1/notify'),
        deviceDisplayName: defaultTargetPlatform == TargetPlatform.iOS
            ? 'ChatFlow iOS'
            : 'ChatFlow Android',
      ));
      unawaited(configureFirebasePushHandlers(tapRouter: router));
    }
    _pusherServices.addAll(pushers);

    for (final pusher in pushers) {
      await pusher.ensureRegistered();
      await pusher.watchTokenRefresh();
    }
    // 推送点击路由就绪：通知系统已装配、主页面已挂载。
    router.markReady();
  }

  Future<void> _assembleNotificationSystem() async {
    final dedupStore = _sharedDedupStore ??=
        await SharedPreferencesNotificationDedupStore.create();
    final deduplicator = _sharedDeduplicator ??= NotificationDeduplicator(
      store: dedupStore,
      ttl: SharedPreferencesNotificationDedupStore.defaultTtl,
    );
    final eventSource = MatrixNotificationEventSource(
      client: widget.matrix.sdkClient,
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
      unreadSource: MatrixUnreadSnapshotSource(
        client: widget.matrix.sdkClient,
      ),
      deduplicator: deduplicator,
    );
    _notificationEventSource = eventSource;
    _notificationCoordinator = coordinator;
    await eventSource.start();
    await coordinator.start();
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
    appResumed = state == AppLifecycleState.resumed;
    // 通知决策的前后台维度（PRD §21）。
    notificationAppState.updateLifecycle(
      switch (state) {
        AppLifecycleState.resumed => AppRunState.foreground,
        AppLifecycleState.inactive => AppRunState.inactive,
        _ => AppRunState.background,
      },
    );
    if (appResumed) {
      // 通知系统启动失败的重试（此前 catch 注释承诺了重试但不存在）。
      if (_notificationBootstrapper?.needsRetry ?? false) {
        unawaited(_startNotificationSystem());
      }
      // 回前台：重新检查通知权限（用户可能刚在系统设置中开启/关闭），
      // 记入诊断；设置页打开时亦会自行刷新。
      unawaited(_refreshNotificationPermissionState());
      // 对齐一次桌面角标（PRD §36 reconcile）+ 静默刷新好友资料
      //（BUG 1：好友头像/昵称变化无需重启即可见）。
      unawaited(_notificationCoordinator?.refreshLauncherBadge());
      unawaited(_chatIdentityCache?.refreshContactsQuietly());
      // BUG 2：前台服务可能被系统配额（Android 14+ dataSync 每日上限）
      // 或厂商 ROM 停止；回前台时幂等补启。
      unawaited(syncKeepAlive.ensureStarted());
    } else if (state == AppLifecycleState.paused) {
      // 退后台瞬间重申保活（部分系统在切后台时回收前台服务/唤醒锁）。
      unawaited(syncKeepAlive.ensureStarted());
    }
    // 回到前台且仍在响铃：收起全屏来电通知，改由应用内接听页呈现。
    if (appResumed && incomingCallActive) {
      unawaited(callNotifications.hideIncoming());
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

  Timer? _friendRequestPollTimer;
  FriendRequestWatch? _friendRequestWatch;
  final ValueNotifier<int> pendingFriendRequests = ValueNotifier<int>(0);

  Future<void> _startFriendRequestWatch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final notifier = FriendRequestNotifier();
      _friendRequestWatch =
          FriendRequestWatch(widget.api, prefs, notifier: notifier);
      _friendRequestPollTimer = Timer.periodic(
        const Duration(seconds: 60),
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
          onEstablishDirectChat:
              (matrixUserId, friendUserId, friendDisplayName) =>
                  _establishDirectChatAndGreet(matrixUserId, friendDisplayName),
        ),
      ),
    );
  }

  /// BUG 3：好友接受后的私聊建立与系统招呼（"你已添加了 XXX…"，
  /// ChatFlow 系统消息类型渲染，绝不伪装成对方普通消息）。
  Future<void> _establishDirectChatAndGreet(
    String matrixUserId,
    String friendDisplayName,
  ) async {
    final reference = await directChats.open(matrixUserId);
    final room = widget.matrix.sdkClient.getRoomById(reference.roomId);
    if (room == null) return;
    await room.sendEvent(
      {
        'body': friendAcceptedSystemMessage(friendDisplayName),
        'friend_user_id': matrixUserId,
        'friend_display_name': friendDisplayName,
      },
      type: changliaoFriendAcceptedEventType,
    );
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

  Future<MessageReminderSyncCoordinator> _createReminderSync() async {
    final backend =
        await MatrixMessageReminderBackend.open(widget.matrix.sdkClient);
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
    final accountKey = widget.matrix.sdkClient.userID;
    ProfileRepository cache;
    try {
      cache = accountKey == null
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
    unawaited(cache.preload());
    return cache;
  }

  void _callChanged() {
    if (!mounted) return;
    final phase = calls.state.phase;
    // 通话占用维度（PRD §40）：响铃与通话中抑制普通消息提醒。
    notificationAppState.setCallActive(
      phase == CallPhase.ringing || phase == CallPhase.connected,
    );
    if (phase == CallPhase.ringing && !callPageVisible) {
      // 来电：前台直接呈现接听页；后台/锁屏/其他应用之上
      // 以全屏意图通知覆盖提醒，点击拉起接听页。
      incomingCallActive = true;
      if (!appResumed) {
        unawaited(callNotifications.showIncoming(
          callerName: calls.state.matrixUserId ?? '加密来电',
          video: calls.state.type == CallMediaType.video,
          ring: true,
        ));
      }
      setState(() {});
    } else if (phase == CallPhase.connected) {
      if (incomingCallActive) {
        incomingCallActive = false;
        unawaited(callNotifications.hideIncoming());
      }
      // 通话中前台服务：按 Home 键/切换应用后通话继续、麦克风摄像头不回收。
      unawaited(callNotifications.showOngoing(title: '端到端加密通话进行中'));
      setState(() {});
    } else if (phase == CallPhase.ended ||
        phase == CallPhase.failed ||
        phase == CallPhase.permissionDenied) {
      final hadCallUi = incomingCallActive || callPageVisible;
      // 主叫在结束时落一条通话摘要消息（接通=时长，未接通=已取消），
      // 被叫端经同步收到同一消息，双端会话各显示一条。
      if (callPageVisible && !callSummarySent) {
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
      incomingCallActive = false;
      unawaited(callNotifications.hideIncoming());
      unawaited(callNotifications.hideOngoing());
      if (hadCallUi) setState(() {});
    }
  }

  Future<void> _openCall(ContactDetails contact, CallMediaType type) async {
    try {
      final reference = await directChats.open(contact.matrixUserId);
      if (!mounted) return;
      callPageVisible = true;
      callSummarySent = false;
      final navigation = Navigator.push(
        context,
        CupertinoPageRoute(
          builder: (_) => CallPage(
            controller: calls,
            displayName: contact.displayName,
            fallbackSeed: contact.username,
            avatarUrl: contact.avatarUrl,
            mediaBackend: callBackend,
            autoCloseOnEnd: true,
          ),
        ),
      );
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
      if (calls.state.phase == CallPhase.requestingPermission ||
          calls.state.phase == CallPhase.ringing ||
          calls.state.phase == CallPhase.connected) {
        try {
          await calls.hangup();
        } catch (_) {
          // The route is already closing; the backend also observes Matrix end
          // events, so cleanup remains best-effort here.
        }
      }
      callPageVisible = false;
    }
  }

  Future<void> _createGroupChat() async {
    String currentUserDisplayName = '我';
    try {
      final cache = await _identityCache();
      await cache.preload();
      final profile = cache.profile!;
      currentUserDisplayName =
          profile.nickname.isEmpty ? profile.username : profile.nickname;
    } catch (_) {
      // Group creation remains available when the cached profile is offline.
    }
    if (!mounted) return;
    final controller = GroupChatController(
      contacts: widget.api,
      groups:
          ServerAutoJoinGroupGateway(api: widget.api, matrix: widget.matrix),
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
    if (!mounted || roomId == null) return;
    final room = widget.matrix.sdkClient.getRoomById(roomId);
    if (room == null) return;
    final identityCache = await _identityCache();
    await identityCache.preload();
    if (!mounted) return;
    await identityCache.precacheAvatarImages(context);
    if (!mounted) return;
    await Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (_) => RoomPage(
          api: widget.api,
          room: room,
          roomName: room.getLocalizedDisplayname(),
          onCreateGroup: _createGroupChat,
          onVoice: (contact) => _openCall(contact, CallMediaType.audio),
          onVideo: (contact) => _openCall(contact, CallMediaType.video),
          reminderService: reminderService,
          initialIdentityCache: identityCache,
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _friendRequestPollTimer?.cancel();
    pendingFriendRequests.dispose();
    calls.removeListener(_callChanged);
    calls.dispose();
    callBackend.dispose();
    directChats.dispose();
    // 退出登录/会话结束：停止消息同步保活前台服务。
    unawaited(syncKeepAlive.stop());
    syncWatchdog.dispose();
    unawaited(reminderBootstrap.dispose());
    NotificationFeedback.uninstall();
    NotificationSystemHandle.uninstall();
    // 通知系统唯一所有者清理（bootstrapper 幂等；兜底直接停引用）。
    final bootstrapper = _notificationBootstrapper;
    if (bootstrapper != null) {
      unawaited(bootstrapper.dispose());
    } else {
      unawaited(_notificationEventSource?.stop());
      unawaited(_notificationCoordinator?.dispose());
    }
    // 推送清理：登出/账号切换注销全部通道的 pusher（服务端停止向本
    // 设备推送），丢弃挂起的点击路由（不跨账号串会话），释放提供方。
    _pushTapRouter?.reset();
    for (final pusher in _pusherServices) {
      unawaited(pusher.unregister());
      unawaited(pusher.dispose());
    }
    _pusherServices.clear();
    for (final provider in _pushTokenProviders) {
      unawaited(provider.dispose());
    }
    _pushTokenProviders.clear();
    unawaited(notificationSounds.dispose());
    super.dispose();
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
    );
  }

  /// 横幅/通知/推送点击进入会话（PRD §7）：优先复用本地身份缓存与既有的
  /// RoomPage 组装路径，头像未就绪先用占位，不为导航等待网络。
  ///
  /// 冷启动（推送点击拉起进程）：房间可能尚未进入首次同步——短暂等待
  /// 房间就绪后再进入，避免点击"无反应"。
  Future<void> _openConversationFromNotification(String roomId) async {
    var room = widget.matrix.sdkClient.getRoomById(roomId);
    if (room == null) {
      try {
        await widget.matrix.sdkClient
            .waitForRoomInSync(roomId)
            .timeout(const Duration(seconds: 10));
        room = widget.matrix.sdkClient.getRoomById(roomId);
      } catch (_) {
        // 首次同步未及时带回房间：留在当前页，会话仍可从消息列表进入。
      }
    }
    if (room == null || !mounted) return;
    final openedRoom = room;
    unawaited(const SharedPreferencesNotificationUsageRecorder()
        .count(NotificationUsageEvents.opened));
    try {
      final cache = await _identityCache();
      await cache.preload();
      if (!mounted) return;
      await cache.precacheAvatarImages(context);
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).push(
        CupertinoPageRoute(
          builder: (_) => RoomPage(
            api: widget.api,
            room: openedRoom,
            roomName: openedRoom.getLocalizedDisplayname(),
            onCreateGroup: _createGroupChat,
            onVoice: (contact) => _openCall(contact, CallMediaType.audio),
            onVideo: (contact) => _openCall(contact, CallMediaType.video),
            reminderService: reminderService,
            initialIdentityCache: cache,
          ),
        ),
      );
    } catch (_) {
      // 导航失败保留在当前页；会话仍可从消息列表进入。
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          CupertinoTabScaffold(
            tabBar: CupertinoTabBar(
              activeColor: const Color(0xff07c160),
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(ChangliaoIcons.messages),
                  activeIcon: Icon(ChangliaoIcons.messagesFilled),
                  label: '消息',
                ),
                BottomNavigationBarItem(
                  icon: Icon(ChangliaoIcons.contacts),
                  activeIcon: Icon(ChangliaoIcons.contactsFilled),
                  label: '通讯录',
                ),
                BottomNavigationBarItem(
                  icon: Icon(ChangliaoIcons.discover),
                  activeIcon: Icon(ChangliaoIcons.discoverFilled),
                  label: '发现',
                ),
                BottomNavigationBarItem(
                  icon: Icon(ChangliaoIcons.me),
                  activeIcon: Icon(ChangliaoIcons.meFilled),
                  label: '我',
                ),
              ],
            ),
            tabBuilder: (_, index) => CupertinoTabView(
              builder: (_) => switch (index) {
                0 => _chatIdentityCache == null
                    ? const Center(child: CupertinoActivityIndicator())
                    : MatrixHomePage(
                        api: widget.api,
                        matrix: widget.matrix,
                        themeController: widget.themeController,
                        onCreateGroup: _createGroupChat,
                        onVoice: (contact) =>
                            _openCall(contact, CallMediaType.audio),
                        onVideo: (contact) =>
                            _openCall(contact, CallMediaType.video),
                        reminderService: reminderService,
                        identityCache: _chatIdentityCache,
                      ),
                1 => _chatIdentityCache == null
                    ? const Center(child: CupertinoActivityIndicator())
                    : ContactsTabPage(
                        api: widget.api,
                        matrix: widget.matrix,
                        pendingFriendRequests: pendingFriendRequests,
                        directChats: directChats,
                        onVoice: (contact) =>
                            _openCall(contact, CallMediaType.audio),
                        onVideo: (contact) =>
                            _openCall(contact, CallMediaType.video),
                        onGroupChat: _createGroupChat,
                        reminderService: reminderService,
                        identityCache: _chatIdentityCache,
                      ),
                2 => DiscoveryPage(
                    matrix: widget.matrix,
                    api: widget.api,
                    identityCache: _chatIdentityCache,
                  ),
                _ => ProfileTabPage(
                    api: widget.api,
                    onLogout: widget.onLogout,
                    identityCache: _chatIdentityCache,
                  ),
              },
            ),
          ),
          if (incomingCallActive)
            Positioned.fill(
              child: CallPage(
                controller: calls,
                displayName: calls.state.matrixUserId ?? '加密来电',
                fallbackSeed: calls.state.matrixUserId ?? 'incoming-call',
                incoming: true,
                mediaBackend: callBackend,
              ),
            ),
          // 应用内通知横幅：覆盖在 Tab 内容之上、来电页之下（PRD §7/§40）。
          InAppBannerOverlay(
            controller: notificationBanners,
            onOpenConversation: (conversationId) =>
                unawaited(_openConversationFromNotification(conversationId)),
          ),
        ],
      );
}

/// Canonical Direct Conversation 目录适配（好友系统重构 Phase E）。
final class _ApiCanonicalDirectRoomDirectory
    implements CanonicalDirectRoomDirectory {
  _ApiCanonicalDirectRoomDirectory(this._api);
  final BusinessApiClient _api;

  @override
  Future<String?> canonicalRoomId(String peerUserId) =>
      _api.canonicalDirectRoomId(peerUserId);

  @override
  Future<String?> registerRoom(String peerUserId, String roomId) async {
    try {
      return await _api.registerDirectConversation(peerUserId, roomId);
    } catch (_) {
      return null;
    }
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
  final ValueNotifier<int> pendingFriendRequests;
  final MessageReminderService? reminderService;
  final ProfileRepository? identityCache;

  @override
  State<ContactsTabPage> createState() => _ContactsTabPageState();
}

final class _ContactsTabPageState extends State<ContactsTabPage> {
  Future<void> _openMessage(ContactDetails contact) async {
    try {
      final reference = await widget.directChats.open(contact.matrixUserId);
      final room = widget.matrix.sdkClient.getRoomById(reference.roomId);
      if (room == null) throw StateError('Matrix room is unavailable');
      final identityCache =
          widget.identityCache ?? ProfileRepository(widget.api);
      await identityCache.preload();
      if (!mounted) return;
      await identityCache.precacheAvatarImages(context);
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).push(
        CupertinoPageRoute(
          builder: (_) => RoomPage(
            api: widget.api,
            room: room,
            roomName: contact.displayName,
            initialContact: contact,
            onCreateGroup: widget.onGroupChat,
            onVoice: widget.onVoice,
            onVideo: widget.onVideo,
            reminderService: widget.reminderService,
            initialIdentityCache: identityCache,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('无法打开加密会话'),
          content: const Text('请检查网络后重试。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ContactsPage(
        api: widget.api,
        matrix: widget.matrix,
        pendingFriendRequests: widget.pendingFriendRequests,
        identityCache: widget.identityCache,
        onMessage: _openMessage,
        onVoice: widget.onVoice,
        onVideo: widget.onVideo,
        onGroupChat: widget.onGroupChat,
      );
}

final class ProfileTabPage extends StatefulWidget {
  const ProfileTabPage({
    super.key,
    required this.api,
    required this.onLogout,
    this.identityCache,
  });
  final BusinessApiClient api;
  final Future<void> Function() onLogout;
  final ProfileRepository? identityCache;
  @override
  State<ProfileTabPage> createState() => _ProfileTabPageState();
}

final class _ProfileTabPageState extends State<ProfileTabPage> {
  late final ProfileController controller = ProfileController(
    gateway: widget.api,
    avatarSource: GalleryAvatarSource(),
    onAvatarUpdated: _refreshAvatarDisplays,
  );

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
      controller: controller,
      onMoments: () {
        final cache = widget.identityCache;
        if (cache == null) return;
        Navigator.of(context, rootNavigator: true).push(CupertinoPageRoute(
            fullscreenDialog: true,
            builder: (_) => MomentsPage(
                  api: widget.api,
                  identityCache: cache,
                )));
      },
      onCaibi: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => CupertinoPageScaffold(
                  navigationBar: CupertinoNavigationBar(
                      automaticBackgroundVisibility: false,
                      enableBackgroundFilterBlur: false,
                      middle: Text('点钻')),
                  child: CaibiPage(api: widget.api)))),
      onWallet: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => CupertinoPageScaffold(
                  navigationBar: CupertinoNavigationBar(
                      automaticBackgroundVisibility: false,
                      enableBackgroundFilterBlur: false,
                      middle: Text('钱包')),
                  child: WalletPage(api: widget.api)))),
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
              builder: (_) =>
                  SettingsPage(api: widget.api, onLogout: widget.onLogout))));
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
                    builder: (_) => CupertinoPageScaffold(
                      navigationBar: CupertinoNavigationBar(
                          automaticBackgroundVisibility: false,
                          enableBackgroundFilterBlur: false,
                          middle: Text('点钻')),
                      child: CaibiPage(api: api),
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

final class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.api, required this.onLogout});

  final BusinessApiClient api;
  final Future<void> Function() onLogout;

  Future<void> _confirmLogout(BuildContext context) async {
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
    if (confirmed == true) await onLogout();
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
                    builder: (_) => AccountPrivacyPage(api: api),
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
                    builder: (_) => AboutChangliaoPage(api: api),
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
                  onPressed: () => _confirmLogout(context),
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
