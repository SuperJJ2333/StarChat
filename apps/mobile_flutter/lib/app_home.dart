import 'features/auth/phone_rebind_page.dart';
import 'features/contacts/contact_actions.dart';
import 'features/contacts/friend_acceptance_greeting_ledger.dart';
import 'features/matrix/direct_chat_failure.dart';
import 'features/contacts/group_address_list_page.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/business_api_client.dart';
import 'core/friend_acceptance_greeting_flow.dart';
import 'core/app_connection_status.dart';
import 'core/network_state_manager.dart';
import 'core/outbox/message_send_scheduler.dart';
import 'core/outbox/outbox_recovery_service.dart';
import 'core/outbox/outbox_room_sender_registry.dart';
import 'core/outbox/outbox_store.dart';
import 'core/outbox/persistent_outbox_manager.dart';
import 'features/matrix/matrix_room_timeline_adapter.dart';
import 'core/app_config.dart';
import 'core/permissions/blocked_contacts.dart';
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
import 'features/finance/wallet_entry_snapshot_store.dart';
import 'features/ledger/ledger_page_snapshot_store.dart';
import 'features/friendship/friend_request_snapshot_store.dart';
import 'features/contacts/contact_tag_snapshot_store.dart';
import 'features/moments/moment_draft_store.dart';
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
import 'features/matrix/direct_chat_entry.dart';
import 'features/matrix/room_navigation_coordinator.dart';
import 'features/matrix/room_opening_policy.dart';
import 'features/matrix/room_open_failure_feedback.dart';
import 'features/statistics/statistics_room_scope.dart';
import 'features/search/global_search_models.dart';
import 'features/search/global_search_page.dart'
    show GlobalSearchRoomOpenCallback;
import 'features/matrix/coordinated_direct_chat.dart';
import 'features/matrix/direct_room_directory_convergence.dart';
import 'features/moments/moment_preview_cache.dart';
import 'features/ledger/ledger_pages.dart';
import 'features/ledger/ledger_business_gateway.dart';
import 'features/matrix/direct_room_coordination_storage.dart';
import 'features/matrix/matrix_sync_watchdog.dart';
import 'features/matrix/matrix_sync_recovery_controller.dart';
import 'features/matrix/matrix_home_page.dart' show MatrixHomePage;
import 'features/matrix/room_page.dart';
import 'features/matrix/pending_conversation_page.dart';
import 'features/matrix/profile_repository.dart';
import 'features/matrix/group_chat_controller.dart';
import 'features/matrix/call_ui_manager.dart';
import 'features/matrix/group_chat_page.dart';
import 'features/matrix/server_auto_join_group_gateway.dart';
import 'features/matrix/call_alerts.dart';
import 'features/matrix/call_controller.dart';
import 'features/search/local_message_search_repository.dart';
import 'features/matrix/call_audio_route_coordinator.dart';
import 'features/matrix/platform_audio_route_observer.dart';
import 'features/matrix/call_identity_resolver.dart';
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
import 'ui/motion/motion_preferences.dart';
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
import './ui/motion/motion_page_route.dart';

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
    // 冷启动后台预取好友预览（并发 3，TTL 内不重复请求）。
    unawaited(MomentPreviewCache.forApi(widget.api)
        .prefetch(cache.contacts.map((contact) => contact.userId)));
  }

  late final DirectChatController directChats = DirectChatController(
    CoordinatedDirectChatGateway(
      coordinator: ApiDirectRoomCoordinator(widget.api),
      intents: PreferencesDirectRoomIntentStore(widget.matrix.userId ?? ''),
      createOnce: widget.matrix.createDirectChatOnce,
      createReserved: widget.matrix.createReservedDirectRoom,
      findExisting: widget.matrix.findExistingDirectChat,
      findCached: widget.matrix.findCachedDirectChat,
      businessUserIdOf: (matrixUserId) =>
          _chatIdentityCache?.contactsByMatrixId[matrixUserId]?.userId,
      openExisting: _openCanonicalDirectRoom,
      onResolved: _rememberResolvedDirectRoom,
      ownerToken: () => (
        widget.matrix.sendPreparationIdentity,
        widget.api.sessionEpoch,
        _disposed
      ),
    ),
  );

  /// 房间页面导航协调器：同一 roomId 只允许一个活动 RoomPage。
  /// 好友资料、消息列表、通知、群聊通讯录与建群后都经由它打开房间。
  late final RoomNavigationCoordinator _roomNavigation =
      RoomNavigationCoordinator(
    openRoom: _openManagedRoomRoute,
    navigatorOf: _rootNavigatorOrNull,
    conversationKeyOf: widget.matrix.logicalConversationKeySync,
  );

  /// **Room Opening Policy Engine**：所有入口进入 [_roomNavigation] 之前的
  /// 唯一策略层。职责只有"打开前判断 + 失败分类"，不创建页面、不管理租约
  /// ——导航职责仍完整属于 [RoomNavigationCoordinator]。
  ///
  /// 离线优先的关键：本地已 joined 的房间由策略直接放行，**绝不**先
  /// `waitForRoom`/`waitForJoinedRoom`；只有本地不存在才允许有界网络回退。
  late final RoomOpeningPolicy _roomOpening = RoomOpeningPolicy(
    probe: _MatrixRoomOpenProbe(widget.matrix),
    diagnostics: (diagnostic) => debugPrint('[room-open] ${diagnostic.line}'),
  );

  /// 打开失败对话框的 single-flight 标志（防止叠层）。
  bool _roomOpenFailureVisible = false;

  /// "本地没有该房间"时的等待上限。
  ///
  /// 从 12 秒收紧到 5 秒：等待只在本地确实没有该房间时发生，且期间会有可见
  /// 进度；过长的空等没有信息增量。超时后由策略给出可重试的失败提示。
  static const Duration _roomOpenWaitTimeout = Duration(seconds: 5);

  NavigatorState? _rootNavigatorOrNull() =>
      mounted ? Navigator.of(context, rootNavigator: true) : null;

  /// 打开规范登记的私聊房间：受邀未加入时先加入；对端建的房间我方
  /// m.direct 可能缺失，补写后房间才具备 DM 语义（否则渲染成"群聊"，
  /// 且后续 invite 扫描无法识别）；最后做加密+双人校验。
  Future<DirectChatRoom> _openCanonicalDirectRoom(String roomId, String peer) =>
      widget.matrix.openCanonicalDirectRoom(roomId, matrixUserId: peer);

  Future<void> _rememberResolvedDirectRoom(
      String peer, DirectRoomResolution resolution) async {
    if (!mounted || _disposed) throw StateError('Conversation owner disposed');
    final contact = _chatIdentityCache?.contactsByMatrixId[peer];
    if (contact == null) throw StateError('Conversation identity unavailable');
    widget.api.acceptDirectConversationSnapshot(contact.userId,
        {'matrix_room_id': resolution.roomId, 'revision': resolution.revision},
        epoch: widget.api.sessionEpoch);
    await widget.matrix.conversations.convergeDirectRoomDirectory(
        knownMatrixPeers: [peer],
        businessUserIdOf: (id) => id == peer ? peer : null,
        associationsOf: (_) async => DirectRoomAssociations(
            primaryRoomId: resolution.roomId!,
            roomIds: resolution.roomIds,
            revision: resolution.revision));
    if (!mounted ||
        _disposed ||
        widget.matrix.logicalPrimaryRoomIdSync(resolution.roomId!) !=
            resolution.roomId) {
      throw const DirectRoomPendingException();
    }
  }

  Future<String> _resolveNewDirectSend(String peer) async {
    final account = widget.matrix.userId;
    final owner = widget.matrix.sendPreparationIdentity;
    final epoch = widget.api.sessionEpoch;
    final cache = await _identityCache();
    final contact = cache.contactsByMatrixId[peer];
    if (!mounted ||
        _disposed ||
        account == null ||
        account != widget.matrix.userId ||
        owner != widget.matrix.sendPreparationIdentity ||
        epoch != widget.api.sessionEpoch ||
        contact == null ||
        blockedContacts.isBlocked(contact.userId)) {
      throw StateError('当前不可发送消息');
    }
    final room = await directChats.open(peer);
    if (!mounted ||
        _disposed ||
        account != widget.matrix.userId ||
        owner != widget.matrix.sendPreparationIdentity ||
        epoch != widget.api.sessionEpoch ||
        blockedContacts.isBlocked(contact.userId)) {
      throw StateError('会话状态已变化');
    }
    return room.roomId;
  }

  void _replaceRecoveredPage(
      String oldRoom, String target, ContactDetails? contact) {
    if (!mounted ||
        _disposed ||
        target == oldRoom ||
        _roomNavigation.activeRoute(oldRoom)?.isCurrent != true) {
      return;
    }
    unawaited(_openManagedRoom(target,
        roomName: contact?.displayName ?? '',
        initialContact: contact,
        source: RoomOpenSource.conversationList));
  }

  /// 同一好友「发消息」的单飞闸门：只锁「权威身份 + canonical roomId」解析，
  /// RoomPage/租约/复用由 [RoomNavigationCoordinator] 按 roomId 负责
  /// （见 `features/matrix/direct_chat_entry.dart` 的生命周期说明）。
  final DirectMessageOpenGate _directMessageGate = DirectMessageOpenGate();

  /// 通话关键路径诊断：backend（invite/answer/ICE）与 controller
  /// （UI 展示/点击接听）共享同一时间线。
  late final CallDiagnostics callDiagnostics = CallDiagnostics();
  late CallWakeupClient callWakeup;
  late MatrixCallBackend callBackend;
  late final ForegroundSoundService notificationSounds =
      ForegroundSoundService();

  /// 唯一音频路由所有者（Task I）：所有 speaker/earpiece 决策只经此组件。
  late final CallAudioRouteCoordinator callAudioRoute =
      CallAudioRouteCoordinator(apply: callBackend.setSpeaker);

  /// 通话对方身份统一解析（Task L）：名称 + 头像 + 授权头一次算出。
  late final CallIdentityResolver callIdentity = CallIdentityResolver(
    displayNameResolver: _sharedDisplayNameResolver,
    avatarMedia: widget.matrix,
    contactFor: _contactSummaryFor,
    matrixProfileFor: _matrixAvatarUriFor,
  );

  CallController _createCallController() => CallController(
        backend: callBackend,
        // 系统权限 API（permission_handler）——不再用 getUserMedia 探测流。
        permissions: const SystemCallPermissionGateway(),
        diagnostics: callDiagnostics,
        audioRoute: callAudioRoute,
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

  /// 最近一次已知的好友快照（同步读取，供通话/通知的即时路径使用）。
  List<ContactSummary>? _contactSnapshot;

  Future<void> _primeContactSnapshot() async {
    try {
      final cache = await (_chatIdentityCacheLoad ??= _createIdentityCache());
      if (!mounted) return;
      _contactSnapshot = List<ContactSummary>.from(cache.contacts);
    } catch (_) {
      // 好友资料不可用时逐级回退，不影响通话建立。
    }
  }

  ContactSummary? _contactSummaryFor(String matrixUserId) {
    for (final contact in _contactSnapshot ?? const <ContactSummary>[]) {
      if (contact.matrixUserId == matrixUserId) return contact;
    }
    // 回退到解析器自身的好友源（可能已完成加载）。
    final resolver = _sharedDisplayNameResolver;
    if (resolver is ContactBackedUserDisplayNameResolver) {
      return resolver.contactFor(matrixUserId);
    }
    return null;
  }

  /// Matrix 头像 `mxc://` 回退（只读本地 SDK 状态，无网络）。
  Uri? _matrixAvatarUriFor(String matrixUserId) =>
      _matrixHomeCapability?.matrixAvatarUriFor(matrixUserId);
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
    widget.matrix.authorizeRoomSend = _authorizeRoomSend;
    widget.matrix.prepareRoomSend = (account, room, peer) async {
      if (account != widget.matrix.userId) throw StateError('Account changed');
      return _resolveNewDirectSend(peer);
    };
    WidgetsBinding.instance.addObserver(this);
    _matrixResourceSetup = _initializeMatrixResources();
    unawaited(_matrixResourceSetup);
    unawaited(_identityCache());
    unawaited(_hydrateBlockedContacts());
    _unreadSubscription = widget.matrix.syncEvents.listen((_) {
      unawaited(_refreshUnreadCount());
    });
  }

  /// BUG-10：登录后同步一次拉黑名单。「聊天发送门」读取同一份投影，
  /// 因此重开 App / 冷启动后拉黑状态依旧生效（服务端 `GET /blocks` 为权威）。
  Future<void> _hydrateBlockedContacts() async {
    try {
      final body = await widget.api.blockList();
      final items = (body['items'] as List?) ?? const [];
      final businessIds = <String>[];
      final matrixIdByUser = <String, String>{};
      for (final item in items) {
        if (item is Map && item['user_id'] != null) {
          final businessId = item['user_id'].toString();
          businessIds.add(businessId);
          final matrixId = item['matrix_user_id']?.toString();
          if (matrixId != null && matrixId.startsWith('@')) {
            matrixIdByUser[businessId] = matrixId;
          }
        }
      }
      blockedContacts.replaceAll(businessIds,
          fromServer: true, matrixIdByUser: matrixIdByUser);
      _syncMatrixIgnoreList(blockedContacts.matrixUserIds);
      blockedContacts.addListener(_onBlockedContactsChanged);
    } catch (_) {
      // 网络失败保持上次已知状态；好友设置页仍会以服务端结果刷新。
    }
  }

  /// 由本 App 的拉黑操作自动加入 Matrix 忽略列表的账号。取消拉黑时只有
  /// 这些账号会被移出忽略列表（用户因其他原因忽略的账号不受影响）。
  final _blockAutoIgnored = <String>{};

  /// BUG-11 回归：把拉黑投影同步为 Matrix 忽略列表——被拉黑用户的消息
  /// 在同步层即被过滤（不再送达本机），而非仅隐藏提醒。
  void _syncMatrixIgnoreList(Set<String> matrixIds) {
    // BUG-11 回归（真机反馈 2）：忽略列表与拉黑列表**严格镜像**——
    // 取消拉黑（哪怕跨重启）必须把账号移出忽略列表，否则对方的消息、
    // 语音通话邀请、消息提醒永远无法恢复。
    for (final id in widget.matrix.ignoredUsers.toSet().difference(matrixIds)) {
      _blockAutoIgnored.remove(id);
      unawaited(widget.matrix
          .unignoreUser(id)
          .catchError((_) => _blockAutoIgnored.add(id)));
    }
    for (final id in matrixIds.difference(widget.matrix.ignoredUsers.toSet())) {
      _blockAutoIgnored.add(id);
      unawaited(widget.matrix
          .ignoreUser(id)
          .catchError((_) => _blockAutoIgnored.remove(id)));
    }
  }

  void _onBlockedContactsChanged() {
    if (!mounted) return;
    // 登出时投影被清空是账号切换语义，不得反向清空服务端忽略列表。
    if (!widget.matrix.isLoggedIn) return;
    _syncMatrixIgnoreList(blockedContacts.matrixUserIds);
  }

  void _startHomeResources() {
    final generation = _startup.generation;
    unawaited(_initializeMomentsUnread().catchError((_) {}));
    // 钱包进入态本地快照：启动时装一次，之后页面的 read 都是同步命中。
    // 这是「断网也能看到余额与已绑定钱包、并且进得去充值/提现页」的前提；
    // 失败不阻塞启动，页面退化为「无本地数据」。
    unawaited(() async {
      try {
        await WalletEntrySnapshotStores.ensureLoaded();
      } catch (_) {
        // 本地快照不可用不是启动失败。
      }
    }());
    // 账单首页本地快照：同样在启动时装一次，让「全部账单」首帧就有上次结果。
    unawaited(() async {
      try {
        await LedgerPageSnapshotStores.ensureLoaded();
      } catch (_) {
        // 同上：不可用即退化为无本地数据。
      }
    }());
    // 「新的朋友」列表本地快照：断网进入时不再谎报「暂无新的朋友」。
    unawaited(() async {
      try {
        await FriendRequestSnapshotStores.ensureLoaded();
      } catch (_) {
        // 同上。
      }
    }());
    // 通讯录标签本地快照：断网冷启动仍能看到上次的标签列表。
    unawaited(() async {
      try {
        await ContactTagSnapshotStores.ensureLoaded();
      } catch (_) {
        // 同上。
      }
    }());
    // 朋友圈草稿本地快照：断网也能接着上次写。
    unawaited(() async {
      try {
        await MomentDraftStores.ensureLoaded();
      } catch (_) {
        // 同上。
      }
    }());
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
    // Task B：登录会话就绪后从**本机加密库**做一次有界回填，让「聊天记录
    // 搜索」覆盖本机已有历史（含从未打开过的房间），而不是只覆盖本次运行
    // 打开过的房间。零网络、有界、可取消。
    unawaited(_backfillLocalSearchHistory(generation));
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
      MotionPageRoute(
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
  ///
  /// BUG-3（2026-09-19）幂等收口：打开会话**每次都执行**，只有一次性系统
  /// 提示 + 打招呼被持久化账本门控（见 [establishAcceptedFriendChat]）。
  Future<void> _establishDirectChatAndGreet(
    String matrixUserId,
    String friendDisplayName,
    Map request,
  ) async {
    final cache = await _identityCache();
    await ensureCurrentFriendIdentity(cache, matrixUserId);
    final ledger = await _greetingLedger();
    await establishAcceptedFriendChat(
      ledger: ledger,
      acceptingUserId: widget.matrix.userId ?? '',
      requestId: request['id']?.toString(),
      openRoom: () async => (await directChats.open(matrixUserId)).roomId,
      sendGreeting: (roomId) => widget.matrix.sendFriendAccepted(
        roomId,
        matrixUserId,
        friendDisplayName,
        requestId: request['id']?.toString(),
        requestMessage: request['message']?.toString(),
      ),
      // The recipient sees request context before this route exposes a composer.
      openConversation: (roomId) => _openConversationFromNotification(roomId,
          source: RoomOpenSource.friendAccept),
    );
  }

  FriendAcceptanceGreetingLedger? _greetingLedgerInstance;
  String? _greetingLedgerAccount;

  /// 一次性好友接受招呼的幂等账本：**每个 AppHome 实例只建一次**并复用
  /// （账号切换时按新账号重建），持久化在 SharedPreferences 里，因此进程
  /// 重启后仍记得"已经发放过"。
  Future<FriendAcceptanceGreetingLedger> _greetingLedger() async {
    final account = widget.matrix.userId ?? '';
    final existing = _greetingLedgerInstance;
    if (existing != null && _greetingLedgerAccount == account) return existing;
    final preferences = await SharedPreferences.getInstance();
    final ledger = FriendAcceptanceGreetingLedger(
        preferences: preferences, accountKey: account);
    _greetingLedgerInstance = ledger;
    _greetingLedgerAccount = account;
    return ledger;
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
    _bindNetworkState();
  }

  /// 统一网络状态（Offline First）：把 Matrix 同步看门狗的既有信号投影为
  /// `online / weak / offline / recovering`，供会话进入与消息发送共用。
  ///
  /// 复用既有信号，不新增探针、不新增定时器：watchdog 已经合并了
  /// connectivity_plus 的传输态、SDK 的 sync 状态与自身的重连序列。
  void _bindNetworkState() {
    final manager = NetworkStateManager.shared ??= NetworkStateManager();
    void listener() {
      // 2026-09-19 修正：`serviceUnavailable`（sync 明确报错/服务端不可达）
      // 不再把传输层事实翻成 `true`——那会让网络状态机在服务器失联时仍认为
      // 可用。服务不可达按 `serverReachable: false` 上报（传输态不动，由
      // connectivity/watchdog 的 offline 判定负责），连续两次即进入 offline，
      // 发送侧据此快速失败并转红叹号等待恢复。
      final status = syncWatchdog.connectionStatus.value;
      manager.report(
        transportAvailable: switch (status) {
          MatrixConnectionStatus.offline => false,
          MatrixConnectionStatus.unknown => null,
          MatrixConnectionStatus.serviceUnavailable => null,
          _ => true,
        },
        serverReachable: status == MatrixConnectionStatus.connected
            ? true
            : status == MatrixConnectionStatus.serviceUnavailable
                ? false
                : null,
        recovering: status == MatrixConnectionStatus.connecting ? true : null,
      );
    }

    syncWatchdog.connectionStatus.addListener(listener);
    _networkStateListener = listener;
    listener();
    _bindOutbox(manager);
  }

  VoidCallback? _networkStateListener;

  PersistentOutboxManager? _outbox;
  MessageSendScheduler? _outboxScheduler;
  OutboxRecoveryService? _outboxRecovery;

  /// 持久化出站消息层（Offline First）：组合根只做接线。
  ///
  /// - 账号命名空间用 `matrix.userId`，切号不会把上一账号的消息发出去；
  /// - 调度器只监听既有网络状态（不新增定时器/探针），房间打开路径不变；
  /// - 启动即恢复未送达行：房间号已知的立刻尝试（房间没打开时原样保留，
  ///   等下次进入会话），房间号未知的等 pending conversation 绑定。
  void _bindOutbox(NetworkStateManager network) {
    final accountId = widget.matrix.userId ?? '';
    var outbox = PersistentOutboxManager.shared;
    if (outbox == null || outbox.accountId != accountId) {
      outbox =
          PersistentOutboxManager(SqliteOutboxStore(), accountId: accountId);
      PersistentOutboxManager.shared = outbox;
    }
    _outbox = outbox;
    final scheduler = MessageSendScheduler(
      outbox: outbox,
      networkState: network,
      senderFor: OutboxRoomSenderRegistry.shared.senderFor,
      // 房间没有打开时的后台发送路径：临时取租约发送后立即释放，
      // 不导航、不 push 页面（房间打开路径仍然唯一）。
      leaseFactory: _openOutboxLease,
      resolveUnbound: (message) async {
        if (!mounted || _disposed || widget.matrix.userId != accountId) {
          return null;
        }
        final cache = await _identityCache();
        if (!cache.contactsByMatrixId.containsKey(message.receiverId)) {
          return null;
        }
        try {
          final room = await directChats.open(message.receiverId);
          if (!mounted || _disposed || widget.matrix.userId != accountId) {
            return null;
          }
          return room.roomId;
        } on DirectRoomPendingException {
          return null;
        }
      },
      authorizeSend: (message) async =>
          mounted &&
          !_disposed &&
          identical(_outbox, outbox) &&
          widget.matrix.userId == accountId &&
          message.roomId != null &&
          await widget.matrix.authorizeSendToRoom(message.roomId!),
    );
    _outboxScheduler = scheduler;
    final recovery =
        OutboxRecoveryService(outbox: outbox, scheduler: scheduler);
    _outboxRecovery = recovery;
    unawaited(recovery.recoverOnStartup().then((_) {
      if (mounted && identical(_outboxScheduler, scheduler)) {
        scheduler.start();
      }
    }).catchError((Object _) {}));
  }

  Future<bool> _authorizeRoomSend(
      String accountId, String roomId, String? peerId) async {
    if (!mounted || _disposed || accountId != widget.matrix.userId) {
      return false;
    }
    if (peerId == null || peerId.isEmpty) return true;
    final cache = await _identityCache();
    final peer = cache.contactsByMatrixId[peerId];
    if (peer == null || blockedContacts.isBlocked(peer.userId)) {
      return false;
    }
    final relationship = await widget.api.lookupUserByMatrixId(peerId);
    if (relationship['relationship_state'] != 'FRIEND' ||
        relationship['user_id'] != peer.userId) {
      return false;
    }
    // Adopt an existing verified legacy room only when no reservation/canonical
    // exists. Server fencing prevents this path from replacing a V2 decision.
    final canonical = await widget.api.canonicalDirectRoomId(peer.userId) ??
        await widget.api.registerDirectConversation(peer.userId, roomId);
    return mounted &&
        !_disposed &&
        accountId == widget.matrix.userId &&
        !blockedContacts.isBlocked(peer.userId) &&
        canonical == roomId;
  }

  Future<void> _reconcileOpenedDirectRoom(
      String roomId, ContactDetails? contact) async {
    if (contact == null) return;
    try {
      final canonical = await _resolveNewDirectSend(contact.matrixUserId);
      if (!mounted ||
          _disposed ||
          canonical == roomId ||
          !widget.matrix.knowsRoomLocally(canonical) ||
          _roomNavigation.activeRoute(roomId)?.isCurrent != true) {
        return;
      }
      if (!mounted ||
          _disposed ||
          _roomNavigation.activeRoute(roomId)?.isCurrent != true) {
        return;
      }
      await _openManagedRoom(canonical,
          roomName: contact.displayName,
          initialContact: contact,
          source: RoomOpenSource.conversationList);
    } catch (_) {/* Local history stays open; later navigation retries. */}
  }

  /// 打开一条**只用于发送**的临时房间租约。
  ///
  /// 与 `_openManagedRoomRoute` 的区别：不经过 `RoomOpeningPolicy`、不注册
  /// 路由、不 push 页面；发送完成后由调用方 [OutboxLease.release] 释放
  /// （timeline.dispose + lease.cancel），因此不会留下资源。
  Future<OutboxLease> _openOutboxLease(String roomId) async {
    final lease = await widget.matrix.openRoomLease(roomId);
    try {
      final timeline = await lease.openRoomTimeline(onUpdate: () {});
      return _MatrixOutboxLease(lease, timeline);
    } catch (error) {
      // 时间线打不开时也必须释放租约（无泄漏）。
      try {
        await lease.cancel();
      } catch (_) {}
      rethrow;
    }
  }

  void _disposeOutbox() {
    _outboxScheduler?.dispose();
    _outboxScheduler = null;
    _outboxRecovery = null;
    // 只解绑监听；数据库里的未送达行留给下次登录继续（账号命名空间隔离）。
    if (identical(PersistentOutboxManager.shared, _outbox)) {
      PersistentOutboxManager.shared = null;
    }
    _outbox = null;
  }

  void _disposeSyncWatchdog() {
    if (!_syncWatchdogStarted) return;
    // The hub listener must be removed while the notifier is still valid.
    // Its owner check also prevents an old AppHome close from clearing a new
    // session that has already bound its own watchdog.
    final owner = _connectionStatusOwner;
    if (owner != null) AppConnectionStatusHub.shared.unbind(owner);
    _connectionStatusOwner = null;
    final listener = _networkStateListener;
    if (listener != null) {
      syncWatchdog.connectionStatus.removeListener(listener);
      _networkStateListener = null;
    }
    _disposeOutbox();
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
        // Task L：主叫/被叫共用同一套身份解析（名称 + 头像 + 授权头）。
        callBackend.identityResolver =
            (matrixUserId, {String? matrixDisplayName}) => callIdentity
                .resolve(matrixUserId, matrixDisplayName: matrixDisplayName);
        // Task G：wakeup 的显式 tombstone 只允许结束**完全匹配**的当前通话。
        callWakeup.onExplicitlyEnded = callBackend.endActiveCallIfMatching;
        // Task B：本机历史搜索数据源（只读本机加密库，零网络）。
        LocalMessageSearchRepository.shared.source =
            capability.createLocalHistorySearchSource();
        LocalMessageSearchRepository.shared
            .attachAccount(widget.matrix.userId ?? '');
        unawaited(_primeContactSnapshot());
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
  /// 只读平台音频路由观察者（外设：蓝牙 / 有线耳机 / USB）。
  ///
  /// **不是**第二个 route owner：它只把平台真实的外设状态喂给
  /// [callAudioRoute]；路由决策与下发仍由协调器独占。
  PlatformAudioRouteObserver? _audioRouteObserver;

  void _onCallPhaseChangedForBusiness(CallPhase previous, CallPhase next) {
    final active = next == CallPhase.ringing ||
        next == CallPhase.requestingPermission ||
        next == CallPhase.connecting ||
        next == CallPhase.connected;
    notificationAppState.setCallActive(active);
    // 只有通话期间才需要观察外设变化：插入/拔出耳机、蓝牙 SCO 连接都发生在
    // 通话中，而已接通后的自动策略必须立刻让位给外设。
    final observer = _audioRouteObserver ??=
        PlatformAudioRouteObserver(route: callAudioRoute);
    if (active) {
      observer.start();
    } else {
      observer.stop();
    }
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

  /// Task B：有界本机历史回填（只读本机加密库；绝不下载云端历史）。
  Future<void> _backfillLocalSearchHistory(int generation) async {
    if (!_currentStartup(generation)) return;
    try {
      await LocalMessageSearchRepository.shared.backfillLocalHistory();
    } catch (_) {
      // 回填失败不影响任何其它功能：搜索退化为「已打开房间 + 增量同步」。
    }
  }

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
      // 与「发消息」同一身份规则：业务 userId 为主键解析权威联系人，
      // 不使用入口快照可能过期的 matrixUserId（否则会把通话拨给旧 Matrix 用户）。
      final target = await resolveCallTarget(
          cache: cache, directChats: directChats, entry: contact);
      final authoritative = target.contact;
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
        MotionPageRoute(
          builder: (pageContext) => CallPage(
            controller: calls,
            // 通话页展示信息同样取自权威联系人：不允许「房间用新身份、
            // 页面显示旧资料」。
            displayName: authoritative.displayName,
            fallbackSeed: authoritative.username,
            avatarUrl: authoritative.avatarUrl,
            mediaBackend: callBackend,
            autoCloseOnEnd: true,
            // BUG-23：通话结束后推进该会话已读（消除虚增未读）。
            onEnded: (roomId) =>
                unawaited(widget.matrix.conversations.markRoomRead(roomId)),
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
        roomId: target.roomId,
        matrixUserId: authoritative.matrixUserId.trim(),
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

  /// “发消息”统一入口（唯一实现）：不信任任何入口传入的 contact 快照
  /// （新好友的本地缓存可能缺 matrix 绑定，Matrix ID 也可能已更新），
  /// 一律按业务 userId 从好友目录解析权威联系人——双源合并（业务 friends
  /// 权威 + Matrix 房间成员实时态），保证 matrixUserId 有效后再打开加密
  /// 私聊；RoomLease/RoomPage 统一交给 [_openManagedRoom]。
  ///
  /// 生命周期边界（真机 BUG 修复）：[DirectMessageOpenGate] 只锁
  /// [_resolveDirectMessageTarget]（身份解析 + canonical roomId），拿到 roomId
  /// 即释放；**`_openManagedRoom` 必须在闸门之外**——它 await 到 RoomPage 关闭
  /// 才完成，若置于闸门内，Room A 打开期间同一好友的第二次「发消息」会被吞掉，
  /// 到不了 `RoomNavigationCoordinator` 的 popUntil。
  /// Offline First（2026-09-18）：进入好友会话**绝不等待网络完成**。
  ///
  /// 顺序（与产品要求一致）：
  /// 1. 只读本地（好友目录 + SDK 本地库 + 持久化房间号提示）解析目标；
  /// 2. 本地有房间 → 立即进入 RoomPage（策略层零网络等待）；
  /// 3. 本地还没有房间 → 后台发起真实 Matrix 房间仲裁，**立即**进入
  ///    pending conversation；房间就绪后自动换成 RoomPage 并发送排队消息。
  Future<void> _openMessage(ContactDetails contact) async {
    try {
      final target = await _directMessageGate.run(
        directMessageOpenKey(contact),
        () => _resolveLocalDirectMessageTarget(contact),
      );
      if (!mounted) return;
      if (target != null) {
        // 闸门已在此释放：下面 await 的是页面生命周期，不是闸门生命周期。
        // 已打开 → popUntil 回原房间；在打开 → 复用；未打开 → push。
        await _openManagedRoom(target.roomId,
            roomName: target.contact.displayName,
            initialContact: target.contact,
            source: RoomOpenSource.contactProfile);
        return;
      }
      await _openPendingConversation(contact);
    } catch (error) {
      // 失败时闸门已自动释放（见 DirectMessageOpenGate.run），弹窗「重试」
      // 可以重新进入本方法。
      if (!mounted) return;
      await showDirectChatFailureDialog(context, error,
          onRetry: () => _openMessage(contact));
    }
  }

  /// 本地优先解析（Offline First 第一步）：只读好友目录、SDK 本地库与
  /// 持久化房间号提示，**不做任何网络请求**；本地还没有会话时返回 null。
  ///
  /// 仍然保留身份权威解析：好友已不在目录、或拿不到有效 matrixUserId 时
  /// 照旧抛出（这是终态失败，不是网络问题）。
  Future<DirectMessageTarget?> _resolveLocalDirectMessageTarget(
      ContactDetails contact) async {
    final cache = await _identityCache();
    final authoritative = await resolveFriendContact(cache, contact);
    final matrixUserId = authoritative.matrixUserId.trim();
    if (matrixUserId.isEmpty) {
      throw StateError('The contact is no longer a current friend');
    }
    // 1) SDK 本地库里已有安全快照 → 直接用它。
    final cached = await directChats.tryLocal(matrixUserId);
    if (cached != null && cached.roomId.trim().isNotEmpty) {
      return DirectMessageTarget(
          roomId: cached.roomId.trim(), contact: authoritative);
    }
    // 2) 协调 intent 里持久化的房间号 + 本地确实存在该房间 → 直接进入。
    //    成员/加密状态由 RoomPage 在后台刷新，不阻塞进入。
    final hint = await directChats.localRoomHint(matrixUserId);
    if (hint != null && widget.matrix.knowsRoomLocally(hint)) {
      return DirectMessageTarget(roomId: hint, contact: authoritative);
    }
    return null;
  }

  /// Offline First 第三步：本地没有会话时**立即**进入 pending conversation，
  /// 并把真实房间仲裁放到后台；房间就绪后换成 RoomPage 并发送排队消息。
  final _pendingConversationRoutes =
      <String, Route<PendingConversationResult>>{};

  Future<void> _openPendingConversation(ContactDetails contact) async {
    final cache = await _identityCache();
    final authoritative = await resolveFriendContact(cache, contact);
    final matrixUserId = authoritative.matrixUserId.trim();
    if (matrixUserId.isEmpty) {
      throw StateError('The contact is no longer a current friend');
    }
    Future<DirectChatRoom> openRoom() => directChats.open(matrixUserId);

    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final existing = _pendingConversationRoutes[matrixUserId];
    if (existing != null && existing.isActive) {
      navigator.popUntil((route) => identical(route, existing));
      return;
    }
    final route = MotionPageRoute<PendingConversationResult>(
        builder: (_) => PendingConversationPage(
            contact: authoritative,
            openRoom: openRoom,
            networkState: NetworkStateManager.shared?.state,
            outbox: _outbox,
            recovery: _outboxRecovery));
    _pendingConversationRoutes[matrixUserId] = route;
    PendingConversationResult? result;
    try {
      result = await navigator.push(route);
    } finally {
      if (identical(_pendingConversationRoutes[matrixUserId], route)) {
        _pendingConversationRoutes.remove(matrixUserId);
      }
    }
    if (!mounted || result == null) return;
    if (result.roomId.isEmpty) return;
    // 房间就绪：按既有唯一入口进入 RoomPage；排队消息作为初始 outbox 发送
    // （弱网/无网时由消息状态机继续“等待发送”并在恢复后重试）。
    await _openManagedRoom(result.roomId,
        roomName: authoritative.displayName,
        initialContact: authoritative,
        source: RoomOpenSource.contactProfile,
        outboxLocalIds: result.outboxLocalIds);
  }

  /// BUG4：通讯录 → 群聊 → 群聊通讯录列表（已 join + saved=true）。
  Future<void> _openGroupAddressList() async {
    await Navigator.push<void>(
      context,
      MotionPageRoute(
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
      _openManagedRoom(roomId, source: RoomOpenSource.groupAddressList);

  /// 房间页面打开的唯一入口：由 [RoomNavigationCoordinator] 按 roomId 去重，
  /// 同一房间已打开时回到既有页面而不是叠加新页面。
  Future<void> _openManagedRoom(String roomId,
          {String? roomName,
          ContactDetails? initialContact,
          RoomOpenSource source = RoomOpenSource.unknown,
          List<String> outbox = const <String>[],
          List<String> outboxLocalIds = const <String>[]}) =>
      _openManagedRoomRequest(RoomOpenRequest(
        roomId: roomId,
        roomName: roomName ?? '',
        initialContact: initialContact,
        source: source,
        outbox: outbox,
        outboxLocalIds: outboxLocalIds,
      ));

  /// **所有入口进入房间的唯一策略路径**（唯一失败反馈点）。
  ///
  /// 流程：RoomOpenRequest → `RoomOpeningPolicy`（打开前判定 + 有界网络等待
  /// + 失败分类）→ `RoomNavigationCoordinator`（去重/复用/页面+租约）。
  /// 失败一律以 [RoomOpenFailure] 抛出并由这里转成用户可见提示——
  /// **不再有任何 `catch (_) {}` 让打开失败静默消失**。
  ///
  /// 反馈是**非阻断 toast**（2026-09-19 用户修订：不再弹警告弹窗）：失败
  /// 原因自动消失式提示，重试由用户再次点击入口完成——按**同一个请求**
  /// 重跑（幂等，协调器与网关都保证不会重复建房）。`_roomOpenFailureVisible`
  /// 仍作 short-window single-flight：toast 显示期间连点不会叠出多条提示。
  Future<void> _openManagedRoomRequest(RoomOpenRequest request) async {
    if (_roomOpenFailureVisible) return;
    // 逻辑会话归一化（缺陷 0919 项 3）：搜索/通知命中历史孤儿房间时，
    // 只允许只读定位打开（保留 roomId+anchor），不作为独立可发送会话。
    await widget.matrix.prepareConversationAssociations();
    final normalized = normalizeDuplicateRoomOpen(request,
        primaryRoomIdOf: widget.matrix.logicalPrimaryRoomIdSync);
    try {
      await _roomOpening.open(
        normalized,
        navigate: _roomNavigation.open,
        awaitLocalRoom: _awaitLocalRoom,
      );
    } on RoomOpenFailure catch (failure) {
      if (!mounted) return;
      _roomOpenFailureVisible = true;
      try {
        showRoomOpenFailureToast(context, failure);
      } finally {
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (mounted) _roomOpenFailureVisible = false;
        });
      }
    }
  }

  /// 有界网络等待：只有策略判定"本地没有这个房间"时才会被调用。
  ///
  /// - 等待窗口 [_roomOpenWaitTimeout]：短于旧的 12 秒，避免"点了没反应"的
  ///   长时间空等仍无解释；
  /// - 等待期间显示**可见进度**（根 Overlay 上的转圈，与消息列表同一做法：
  ///   不用 modal route，避免低端机上"modal→pop→push"同帧竞争吞掉 push）；
  /// - 返回 false（而不是抛错）表示"窗口内没等到"，由策略统一转成可重试的
  ///   [RoomOpenFailureKind.temporaryFailure] 并给出可见提示。
  Future<bool> _awaitLocalRoom(String roomId) async {
    final overlay = mounted ? _insertRoomOpenWaitOverlay() : null;
    try {
      await widget.matrix.waitForRoom(roomId).timeout(_roomOpenWaitTimeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      overlay?.remove();
    }
  }

  /// 等待期间的可见进度（根 Overlay；页面退出/不可用时静默跳过）。
  OverlayEntry? _insertRoomOpenWaitOverlay() {
    if (!mounted) return null;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return null;
    final entry = OverlayEntry(
      builder: (_) => const Positioned.fill(
        key: Key('room-open-waiting'),
        child: ColoredBox(
          color: Color(0x33000000),
          child: Center(child: CupertinoActivityIndicator(radius: 16)),
        ),
      ),
    );
    overlay.insert(entry);
    return entry;
  }

  /// 通讯录 / 发现 Tab 的搜索入口：与消息 Tab 的搜索**同一条策略路径**
  /// （`source = search`，离线优先）。三处注入同一个回调，能力不再分叉。
  Future<void> _openSearchRoom(GlobalSearchRoomResult room,
          {String? anchorEventId}) =>
      _openManagedRoomRequest(RoomOpenRequest(
        roomId: room.roomId,
        roomName: room.displayName,
        anchorEventId: anchorEventId,
        source: RoomOpenSource.search,
      ));

  /// 打开流程（协调器持有 registry）：取租约 → RoomPage → 登记路由 →
  /// revoke 绑定 → push → 页面退出后释放租约。
  ///
  /// 生命周期语义与改造前一致：未 mounted 时取消租约；push 抛异常也会释放
  /// 登记与租约；revoke 时只关闭自己这一层（`popUntil` 到自身 + 当前则 pop）。
  /// 租约取消按 roomId 串行，不会阻塞打开**其它**房间。
  Future<void> _openManagedRoomRoute(
      RoomOpenRequest request, RoomRouteHandle handle) async {
    final roomId = request.roomId;
    var stage = 'identity';
    debugPrint('[room-open-flow] stage=$stage room=$roomId');
    MotionPageRoute<void>? route;
    ValueNotifier<RoomOpenRequest>? navigationRequests;
    var closed = false;
    void notifyClosed() {
      if (closed) return;
      closed = true;
      request.onRoomClosed?.call();
    }

    try {
      final identityCache = await _identityCache();
      final name = request.roomName.trim().isEmpty
          ? await widget.matrix.conversations.roomDisplayName(roomId)
          : request.roomName.trim();
      stage = 'lease';
      debugPrint('[room-open-flow] stage=lease room=$roomId');
      final lease = await widget.matrix.openRoomLease(roomId);

      if (!mounted) {
        await lease.cancel();
        return;
      }
      final navigator = Navigator.of(context, rootNavigator: true);
      navigationRequests = ValueNotifier<RoomOpenRequest>(request);
      route = MotionPageRoute<void>(
          builder: (_) => RoomPage(
                api: widget.api,
                roomLease: lease,
                roomName: name,
                initialContact: request.initialContact,
                initialAnchorEventId: request.anchorEventId,
                initialOutbox: request.outbox,
                initialOutboxLocalIds: request.outboxLocalIds,
                initialAnchorRoomId: request.anchorRoomId,
                navigationRequests: navigationRequests,
                requestOutboxDrain: () => unawaited(_outboxScheduler?.drain()),
                resolveDirectSendTarget: _resolveNewDirectSend,
                onDirectTargetChanged: (target) => _replaceRecoveredPage(
                    roomId,
                    target,
                    request.initialContact ??
                        identityCache
                            .contactsByMatrixId[lease.roomInfo.directPeerId]),
                outbox: _outbox,
                onCreateGroup: _createGroupChat,
                // BUG-16：聊天信息页入口携带当前对端，发起群聊默认选中。
                onCreateGroupWithPeer: _createGroupChat,
                onMessage: _openMessage,
                onVoice: (contact) => _openCall(contact, CallMediaType.audio),
                onVideo: (contact) => _openCall(contact, CallMediaType.video),
                reminderService: reminderService,
                initialIdentityCache: identityCache,
                readOnly: request.readOnly,
              ));
      handle.register(route, onReopen: (next) => navigationRequests!.value = next);
      // 「当前可见会话」作用域（统计工具上下文）由**打开流程**登记与释放，
      // 不再由 RoomPage 自己维护：会话状态只有一个真相源（本流程）。
      StatisticsRoomScope.enter(roomId);
      lease.setOnRevoked(() async {
        final r = route;
        if (r == null) return;
        if (r.isActive) {
          navigator.popUntil((candidate) => identical(candidate, r));
          if (r.isCurrent) navigator.pop();
        }
      });
      stage = 'ready';
      debugPrint('[room-open-flow] stage=ready room=$roomId');
      request.onRoomReady?.call();
      // 已知竞态兜底（低端机）：同帧 modal→pop→push 会吞掉房间 push——路由
      // 从未进栈，`visible` 永不完成 → 列表侧 `_openingRooms` 守卫被永久占住，
      // 该房间永远点不开。落地校验：限时未进栈则按失败收尾，列表解锁可重试。
      final landed = Completer<void>();
      Timer? landingWatch;
      // 首帧落地检查通过则不建定时器（测试的 FakeAsync 不残留 pending Timer）。
      void verifyLanded() {
        final r = route;
        if (r == null || closed || landed.isCompleted) return;
        if (r.isActive || r.isCurrent) {
          landed.complete();
          return;
        }
        landingWatch ??= Timer(const Duration(milliseconds: 1200), () {
          final r2 = route;
          if (r2 == null || closed || landed.isCompleted) return;
          if (r2.isActive || r2.isCurrent) {
            landed.complete();
            return;
          }
          try {
            navigator.removeRoute(r2);
          } catch (_) {}
          landed.completeError(StateError('ROOM_PUSH_SWALLOWED'));
        });
      }

      stage = 'push';
      final visible = navigator.push(route);
      WidgetsBinding.instance.addPostFrameCallback((_) => verifyLanded());
      final previous = handle.replacedRoute;
      if (previous != null && previous.isActive) {
        navigator.removeRoute(previous);
      }
      final contact = request.initialContact ??
          identityCache.contactsByMatrixId[lease.roomInfo.directPeerId];
      unawaited(_reconcileOpenedDirectRoom(roomId, contact));
      await landed.future;
      stage = 'landed';
      // 路由已落地：通知调用方移除打开期反馈遮罩（转圈），由房间页自身
      // 的推入转场完成最后的视觉过渡。
      request.onRoomLanded?.call();
      // A removed/replaced route completes its pop before its widgets finish
      // their final frame. Keep their timeline and lease alive until disposal.
      await visible;
      await route.completed;
    } catch (error) {
      debugPrint('[room-open-flow] FAILED stage=$stage room=$roomId error=$error');
      rethrow;
    } finally {
      StatisticsRoomScope.leave(roomId);
      final finalRoute = route;
      if (finalRoute != null) handle.release(finalRoute);
      navigationRequests?.dispose();
      notifyClosed();
    }
  }

  void _scanFromTab() {
    Navigator.of(context, rootNavigator: true).push(MotionPageRoute(
      fullscreenDialog: true,
      builder: (_) => ScanQrPage(
          api: widget.api,
          groupJoinApi: widget.api,
          identityCache: _chatIdentityCache,
          onGroupJoined: (roomId) => unawaited(
              _openConversationFromNotification(roomId,
                  source: RoomOpenSource.scan))),
    ));
  }

  void _addFriendFromTab() {
    Navigator.of(context, rootNavigator: true).push(MotionPageRoute(
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

  /// BUG-16：[preselectedMatrixUserId] 来自聊天信息页入口——发起群聊时
  /// 默认选中当前会话对端（可取消）；其他入口不传即为空。
  Future<void> _createGroupChat([String? preselectedMatrixUserId]) async {
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
      preselectedMatrixUserIds: {
        if (preselectedMatrixUserId != null) preselectedMatrixUserId,
      },
    );
    final roomId = await Navigator.push<String>(
      context,
      MotionPageRoute(
        builder: (pageContext) => GroupChatPage(
          controller: controller,
          onCreated: (createdRoomId) =>
              Navigator.pop(pageContext, createdRoomId),
        ),
      ),
    );
    controller.dispose();
    if (!mounted || roomId == null || !identical(matrix, widget.matrix)) return;
    final identityCache = await _identityCache();
    if (!mounted || !identical(matrix, widget.matrix)) return;
    // 建群成功后同样走统一房间导航（登记 roomId，避免与消息列表/通知
    // 重复打开同一房间）；身份预热保持原样的后台任务。
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
    await _openManagedRoom(roomId, source: RoomOpenSource.groupCreated);
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
    // 账号切换/退出登录：房间导航登记不得泄漏到下一个账号。
    _roomNavigation.dispose();
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
    // 平台路由观察者随通话资源一并停止（不持有 Timer 残留）。
    _audioRouteObserver?.dispose();
    _audioRouteObserver = null;
    // Task B：登出/资源关闭即清空本机搜索索引（账号命名空间隔离）。
    LocalMessageSearchRepository.shared.clear();
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

  /// 横幅/通知/推送点击进入会话（PRD §7）。
  ///
  /// 策略化改造（**不再静默失败**）：网络姿态由 `RoomOpeningPolicy` 按
  /// [source] 决定（通知 = `localThenNetwork`）——
  /// - 本地已有该房间 → **零等待立即打开**（离线也能进，旧实现会先等 10 秒）；
  /// - 本地没有 → 交给策略做一次有界等待；等不到时抛出 [RoomOpenFailure]，
  ///   由 [_openManagedRoomRequest] 统一显示"无法打开会话，请检查网络"，
  ///   取代原来的 `catch (_) {}`（用户看到的是"点了没反应"）。
  Future<void> _openConversationFromNotification(
    String roomId, {
    RoomOpenSource source = RoomOpenSource.notification,
  }) async {
    if (!mounted) return;
    await _openManagedRoomRequest(RoomOpenRequest(
      roomId: roomId,
      roomName: '',
      source: source,
      // 真的进到房间（租约已取、页面即将 push）才记为"打开通知"，
      // 失败不会留下虚假的 opened 统计。
      onRoomReady: () => unawaited(
          const SharedPreferencesNotificationUsageRecorder()
              .count(NotificationUsageEvents.opened)),
    ));
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
  Widget build(BuildContext context) => Stack(
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
                  activeIcon:
                      _contactsBadge(const Icon(ChangliaoIcons.contactsFilled)),
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
                0 => !_matrixReady
                    ? const _HomeWarmupPane(
                        key: ValueKey('home-matrix-warmup'),
                        message: '正在连接，稍候即可查看消息',
                      )
                    : MatrixHomePage(
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
                        // 消息列表不再自建 RoomLease/RoomPage：统一交给
                        // AppHome 的房间导航协调器（同一 roomId 只有一个页面）。
                        onOpenRoom: _openManagedRoomRequest,
                      ),
                1 => _chatIdentityCache == null
                    ? const _HomeWarmupPane(
                        key: ValueKey('home-contacts-warmup'),
                        message: '正在准备通讯录',
                      )
                    : ContactsTabPage(
                        api: widget.api,
                        matrix: widget.matrix,
                        pendingFriendRequests: pendingFriendRequests,
                        onFriendRequests: _openFriendRequests,
                        directChats: directChats,
                        // 通讯录好友资料「发消息」使用与朋友圈/群聊同一个
                        // 统一入口（唯一实现，见 _openMessage）。
                        onMessage: _openMessage,
                        onVoice: (contact) =>
                            _openCall(contact, CallMediaType.audio),
                        onVideo: (contact) =>
                            _openCall(contact, CallMediaType.video),
                        onGroupChat: _createGroupChat,
                        onScan: _scanFromTab,
                        onAppearance: () => showThemePickerSheet(
                            context, widget.themeController),
                        onGroupAddressList: _openGroupAddressList,
                        identityCache: _chatIdentityCache,
                        // 搜索（群聊/聊天记录）三 Tab 能力一致：同一个回调。
                        onOpenRoom: _openSearchRoom,
                      ),
                2 => DiscoveryPage(
                    onOpenRoom: _openSearchRoom,
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

/// `RoomOpenLocalProbe` 的 Matrix 实现。
///
/// **只读本机事实**：SDK 本地库的房间 membership 与 accountData 引用的控制
/// 房间。绝不发起网络请求——这是 `RoomOpeningPolicy` 离线优先的前提。
final class _MatrixRoomOpenProbe implements RoomOpenLocalProbe {
  const _MatrixRoomOpenProbe(this.matrix);

  final MatrixSdkE2eeClient matrix;

  @override
  bool knowsRoom(String roomId) => matrix.knowsRoomLocally(roomId);

  @override
  bool isJoined(String roomId) => matrix.isRoomJoinedLocally(roomId);

  @override
  Set<String> get controlRoomIds => matrix.controlRoomIds;
}

/// 轻量后台加载占位：小号指示器+次级说明文案，不阻塞其余 Tab 与操作。
final class _HomeWarmupPane extends StatelessWidget {
  const _HomeWarmupPane({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(radius: 9),
            const SizedBox(height: 8),
            Text(message,
                style: const TextStyle(
                    fontSize: 13, color: WeChatColors.textSecondary)),
          ],
        ),
      );
}

/// 通讯录 Tab：已 hydrate 的快照立即渲染；「发消息」等好友动作全部使用
/// AppHome 注入的统一实现（权威身份解析见 features/matrix/direct_chat_entry.dart），
/// 因此本页不持有 canonical 房间查找 / RoomLease / RoomPage 逻辑。
final class ContactsTabPage extends StatefulWidget {
  const ContactsTabPage({
    super.key,
    required this.api,
    required this.matrix,
    required this.directChats,
    required this.onMessage,
    required this.onVoice,
    required this.onVideo,
    required this.onGroupChat,
    required this.onOpenRoom,
    this.onScan,
    this.onAppearance,
    this.onGroupAddressList,
    this.onFriendRequests,
    required this.pendingFriendRequests,
    this.identityCache,
  });
  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final DirectChatController directChats;

  /// 好友资料「发消息」的统一入口（AppHome 注入）：通讯录不再自己实现
  /// canonical 房间查找、RoomLease 管理与 RoomPage 推送。
  final ContactAction onMessage;
  final ContactAction onVoice;
  final ContactAction onVideo;
  final VoidCallback onGroupChat;
  final VoidCallback? onScan, onAppearance;

  /// BUG4：通讯录"群聊"入口 → 群聊通讯录列表。
  final VoidCallback? onGroupAddressList;
  final VoidCallback? onFriendRequests;
  final ValueNotifier<int> pendingFriendRequests;
  final ProfileRepository? identityCache;

  /// 房间打开（必填）：本 Tab 搜索与消息 Tab 搜索共用的统一打开回调
  /// （RoomOpeningPolicy → RoomNavigationCoordinator）。
  final GlobalSearchRoomOpenCallback onOpenRoom;

  @override
  State<ContactsTabPage> createState() => _ContactsTabPageState();
}

final class _ContactsTabPageState extends State<ContactsTabPage> {
  @override
  Widget build(BuildContext context) => ContactsPage(
        api: widget.api,
        matrix: widget.matrix,
        onOpenRoom: widget.onOpenRoom,
        pendingFriendRequests: widget.pendingFriendRequests,
        directChats: widget.directChats,
        onFriendRequests: widget.onFriendRequests,
        identityCache: widget.identityCache,
        onMessage: widget.onMessage,
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
void _openLedgerAllBills(BuildContext context, BusinessApiClient? api,
    ProfileRepository? identityCache) {
  if (api == null) return;
  Navigator.of(context).push(MotionPageRoute<void>(
      builder: (_) => LedgerListPage(
          gateway: BusinessLedgerGateway(api), identityCache: identityCache)));
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
            MotionPageRoute(fullscreenDialog: true, builder: (_) => page));
      },
      onCaibi: () => Navigator.push(
          context,
          MotionPageRoute(
              builder: (_) => CaibiPage(
                  api: widget.api,
                  onOpenAllBills: () => _openLedgerAllBills(
                      context, widget.api, widget.identityCache)))),
      onWallet: () => Navigator.push(context,
          MotionPageRoute(builder: (_) => WalletPage(api: widget.api))),
      inviteGateway: widget.api,
      onInvite: () => Navigator.push(
          context,
          MotionPageRoute(
              builder: (_) => InviteCodePage(
                  controller: InviteCodeController(gateway: widget.api)))),
      onQrCode: () {
        final profile = controller.state.profile;
        if (profile == null) return;
        Navigator.push(context,
            MotionPageRoute(builder: (_) => MyQrCodePage(profile: profile)));
      },
      onSettings: () => Navigator.push(
          context,
          MotionPageRoute(
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
    this.identityCache,
  });

  final BusinessApiClient api;
  final Future<void> Function() onLogout;
  final ProfileRepository? identityCache;

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
                  MotionPageRoute(
                    builder: (_) => CaibiPage(
                      api: api,
                      onOpenAllBills: () =>
                          _openLedgerAllBills(context, api, identityCache),
                    ),
                  ),
                ),
              ),
              WeChatListTile(
                leading: const Icon(CupertinoIcons.creditcard_fill),
                title: const Text('钱包'),
                onTap: () => Navigator.push(
                  context,
                  MotionPageRoute(
                    builder: (_) => WalletPage(api: api),
                  ),
                ),
              ),
              WeChatListTile(
                leading: const Icon(CupertinoIcons.settings),
                title: const Text('设置'),
                onTap: () => Navigator.push(
                  context,
                  MotionPageRoute(
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
                  MotionPageRoute(
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
                  MotionPageRoute(
                    builder: (_) => NotificationSettingsPage(
                      coordinator: NotificationSystemHandle.coordinator,
                    ),
                  ),
                ),
              ),
              const _MotionSettingsTile(),
              _SettingsTile(
                icon: CupertinoIcons.info,
                label: '关于畅聊',
                detail: 'V${AppConfig.appVersionName}',
                onTap: () => Navigator.push(
                  context,
                  MotionPageRoute(
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
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback onTap;
  final Widget? trailing;

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
            if (trailing != null)
              trailing!
            else
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

/// BUG-08：「减少动态效果」开关（此前是不可点击的占位行，
/// 文案固定「跟随系统」，开启后对动画没有任何影响）。
///
/// 开关写入本地设置；应用根据此覆盖 `MediaQuery.disableAnimations`，
/// 所有动效组件（菜单/点赞/按钮/图片帧）与页面转场（[MotionPageRoute]）
/// 立即跟随。
final class _MotionSettingsTile extends StatelessWidget {
  const _MotionSettingsTile();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: motionPreferences,
        builder: (context, _) => _SettingsTile(
          icon: CupertinoIcons.wind,
          label: '减少动态效果',
          detail: motionPreferences.reduceMotion ? '已开启' : '跟随系统',
          trailing: CupertinoSwitch(
            key: const Key('settings-reduce-motion-switch'),
            value: motionPreferences.reduceMotion,
            onChanged: (value) =>
                unawaited(motionPreferences.setReduceMotion(value)),
          ),
          onTap: () => unawaited(motionPreferences
              .setReduceMotion(!motionPreferences.reduceMotion)),
        ),
      );
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
                        title: const Text('绑定或更换手机号'),
                        onTap: () => Navigator.of(context).push(MotionPageRoute(
                            builder: (_) => PhoneRebindPage(api: widget.api))),
                      ),
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

/// 临时房间租约（只用于发送）：发送完成后由调度器释放。
///
/// 与 `RoomPage` 持有的租约语义一致（同一 SDK 资源管理），区别是这里不挂
/// 时间线 UI、不注册导航路由；`release()` 幂等，成功/失败/取消三路都调用。
final class _MatrixOutboxLease implements OutboxLease {
  _MatrixOutboxLease(this._lease, this._timeline);

  final MatrixRoomLease _lease;
  final RoomTimelineCapability _timeline;
  bool _released = false;

  @override
  Future<String> send(String text, String transactionId) =>
      _timeline.sendTextWithTransaction(text, transactionId);

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      _timeline.dispose();
    } catch (_) {
      // 释放错误不得掩盖发送结果。
    }
    try {
      await _lease.cancel();
    } catch (_) {
      // 同上：租约取消失败由 SDK 生命周期兜底。
    }
  }
}
