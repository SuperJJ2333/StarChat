import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'core/business_api_client.dart';
import 'core/local_notification_scheduler.dart';
import 'features/caibi/caibi_page.dart';
import 'features/contacts/contacts_page.dart';
import 'features/contacts/contact_models.dart';
import 'features/discovery/discovery_page.dart';
import 'features/moments/moments_page.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'features/matrix/direct_chat_controller.dart';
import 'features/matrix/matrix_home_page.dart';
import 'features/matrix/chat_identity_cache.dart';
import 'features/matrix/group_chat_controller.dart';
import 'features/matrix/group_chat_page.dart';
import 'features/matrix/server_auto_join_group_gateway.dart';
import 'features/matrix/call_controller.dart';
import 'features/matrix/call_page.dart';
import 'features/matrix/matrix_call_adapter.dart';
import 'features/matrix/matrix_message_reminder_backend.dart';
import 'features/matrix/message_reminder_service.dart';
import 'features/redpacket/redpacket_page.dart';
import 'features/wallet/wallet_page.dart';
import 'ui/components/wechat_list_tile.dart';
import 'ui/foundation/changliao_icons.dart';
import 'ui/foundation/wechat_tokens.dart';
import 'ui/theme/theme_controller.dart';
import 'features/profile/profile_controller.dart';
import 'features/profile/profile_page.dart';
import 'features/profile/avatar_source.dart';

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

final class _AppHomeState extends State<AppHome> {
  late final DirectChatController directChats =
      DirectChatController(widget.matrix);
  late final MatrixCallBackend callBackend =
      MatrixCallBackend(widget.matrix.sdkClient);
  late final CallController calls = CallController(
    backend: callBackend,
    permissions: const WebRtcPermissionGateway(),
  );
  bool callPageVisible = false;
  bool incomingCallActive = false;
  MessageReminderService? reminderService;
  late final MessageReminderSyncBootstrapper reminderBootstrap;
  ChatIdentityCache? _chatIdentityCache;
  Future<ChatIdentityCache>? _chatIdentityCacheLoad;

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

  Future<ChatIdentityCache> _identityCache() =>
      _chatIdentityCacheLoad ??= _createIdentityCache();

  Future<ChatIdentityCache> _createIdentityCache() async {
    final accountKey = widget.matrix.sdkClient.userID;
    final cache = accountKey == null
        ? ChatIdentityCache(widget.api)
        : await ChatIdentityCache.create(
            api: widget.api,
            accountKey: 'matrix:$accountKey',
          );
    await cache.hydrate();
    _chatIdentityCache = cache;
    if (mounted) setState(() {});
    unawaited(cache.preload());
    return cache;
  }

  void _callChanged() {
    if (!mounted) return;
    if (calls.state.phase == CallPhase.ringing && !callPageVisible) {
      incomingCallActive = true;
      setState(() {});
    } else if (incomingCallActive &&
        (calls.state.phase == CallPhase.ended ||
            calls.state.phase == CallPhase.failed ||
            calls.state.phase == CallPhase.permissionDenied)) {
      incomingCallActive = false;
      setState(() {});
    }
  }

  Future<void> _openCall(ContactDetails contact, CallMediaType type) async {
    try {
      final reference = await directChats.open(contact.matrixUserId);
      if (!mounted) return;
      callPageVisible = true;
      final navigation = Navigator.push(
        context,
        CupertinoPageRoute(
          builder: (_) => CallPage(
            controller: calls,
            displayName: contact.displayName,
            fallbackSeed: contact.username,
            avatarUrl: contact.avatarUrl,
            mediaBackend: callBackend,
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
    calls.removeListener(_callChanged);
    calls.dispose();
    callBackend.dispose();
    directChats.dispose();
    unawaited(reminderBootstrap.dispose());
    super.dispose();
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
                        directChats: directChats,
                        onVoice: (contact) =>
                            _openCall(contact, CallMediaType.audio),
                        onVideo: (contact) =>
                            _openCall(contact, CallMediaType.video),
                        onGroupChat: _createGroupChat,
                        reminderService: reminderService,
                        identityCache: _chatIdentityCache,
                      ),
                2 => DiscoveryPage(api: widget.api),
                _ => ProfileTabPage(api: widget.api, onLogout: widget.onLogout),
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
        ],
      );
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
    this.reminderService,
    this.identityCache,
  });
  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final DirectChatController directChats;
  final ContactAction onVoice;
  final ContactAction onVideo;
  final VoidCallback onGroupChat;
  final MessageReminderService? reminderService;
  final ChatIdentityCache? identityCache;

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
          widget.identityCache ?? ChatIdentityCache(widget.api);
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
        onMessage: _openMessage,
        onVoice: widget.onVoice,
        onVideo: widget.onVideo,
        onGroupChat: widget.onGroupChat,
      );
}

final class ProfileTabPage extends StatefulWidget {
  const ProfileTabPage({super.key, required this.api, required this.onLogout});
  final BusinessApiClient api;
  final Future<void> Function() onLogout;
  @override
  State<ProfileTabPage> createState() => _ProfileTabPageState();
}

final class _ProfileTabPageState extends State<ProfileTabPage> {
  late final ProfileController controller = ProfileController(
      gateway: widget.api, avatarSource: GalleryAvatarSource());
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProfileExperiencePage(
      controller: controller,
      onMoments: () => Navigator.push(context,
          CupertinoPageRoute(builder: (_) => MomentsPage(api: widget.api))),
      onCaibi: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => CupertinoPageScaffold(
                  navigationBar: CupertinoNavigationBar(
                      backgroundColor: WeChatColors.chatNavigationBackground,
                      automaticBackgroundVisibility: false,
                      enableBackgroundFilterBlur: false,
                      middle: Text('彩币')),
                  child: CaibiPage(api: widget.api)))),
      onRedPacket: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => CupertinoPageScaffold(
                  navigationBar: CupertinoNavigationBar(
                      backgroundColor: WeChatColors.chatNavigationBackground,
                      automaticBackgroundVisibility: false,
                      enableBackgroundFilterBlur: false,
                      middle: Text('红包')),
                  child: RedPacketPage(api: widget.api)))),
      onWallet: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => CupertinoPageScaffold(navigationBar: CupertinoNavigationBar(backgroundColor: WeChatColors.chatNavigationBackground, automaticBackgroundVisibility: false, enableBackgroundFilterBlur: false, middle: Text('钱包')), child: WalletPage(api: widget.api)))),
      onSettings: () => Navigator.push(context, CupertinoPageRoute(builder: (_) => SettingsPage(api: widget.api, onLogout: widget.onLogout))));
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
            backgroundColor: WeChatColors.chatNavigationBackground,
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('我')),
        child: SafeArea(
          child: ListView(
            children: [
              const SizedBox(height: 16),
              WeChatListTile(
                leading: const Icon(CupertinoIcons.money_dollar_circle_fill),
                title: const Text('彩币'),
                onTap: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => CupertinoPageScaffold(
                      navigationBar: CupertinoNavigationBar(
                          backgroundColor:
                              WeChatColors.chatNavigationBackground,
                          automaticBackgroundVisibility: false,
                          enableBackgroundFilterBlur: false,
                          middle: Text('彩币')),
                      child: CaibiPage(api: api),
                    ),
                  ),
                ),
              ),
              WeChatListTile(
                leading: const Icon(CupertinoIcons.gift_fill),
                title: const Text('红包'),
                onTap: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => CupertinoPageScaffold(
                      navigationBar: CupertinoNavigationBar(
                          backgroundColor:
                              WeChatColors.chatNavigationBackground,
                          automaticBackgroundVisibility: false,
                          enableBackgroundFilterBlur: false,
                          middle: Text('红包')),
                      child: RedPacketPage(api: api),
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
                          backgroundColor:
                              WeChatColors.chatNavigationBackground,
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
            backgroundColor: WeChatColors.chatNavigationBackground,
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
                detail: '已开启',
                onTap: () {},
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
                detail: '1.1',
                onTap: () {},
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
          backgroundColor: WeChatColors.chatNavigationBackground,
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
