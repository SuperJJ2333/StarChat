import 'package:flutter/cupertino.dart';

import 'core/business_api_client.dart';
import 'features/caibi/caibi_page.dart';
import 'features/contacts/contacts_page.dart';
import 'features/contacts/contact_models.dart';
import 'features/discovery/discovery_page.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'features/matrix/direct_chat_controller.dart';
import 'features/matrix/matrix_home_page.dart';
import 'features/matrix/call_controller.dart';
import 'features/matrix/call_page.dart';
import 'features/matrix/matrix_call_adapter.dart';
import 'features/redpacket/redpacket_page.dart';
import 'features/wallet/wallet_page.dart';
import 'ui/components/wechat_list_tile.dart';
import 'features/profile/profile_controller.dart';
import 'features/profile/profile_page.dart';
import 'features/profile/avatar_source.dart';

final class AppHome extends StatefulWidget {
  const AppHome({
    super.key,
    required this.api,
    required this.matrix,
    required this.onLogout,
  });

  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final Future<void> Function() onLogout;

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

  @override
  void initState() {
    super.initState();
    calls.addListener(_callChanged);
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

  @override
  void dispose() {
    calls.removeListener(_callChanged);
    calls.dispose();
    callBackend.dispose();
    directChats.dispose();
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
                  icon: Icon(CupertinoIcons.chat_bubble_2_fill),
                  label: '消息',
                ),
                BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.person_2_fill),
                  label: '通讯录',
                ),
                BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.compass_fill),
                  label: '发现',
                ),
                BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.person_crop_circle_fill),
                  label: '我',
                ),
              ],
            ),
            tabBuilder: (_, index) => CupertinoTabView(
              builder: (_) => switch (index) {
                0 => MatrixHomePage(matrix: widget.matrix),
                1 => ContactsTabPage(
                    api: widget.api,
                    matrix: widget.matrix,
                    directChats: directChats,
                    onVoice: (contact) =>
                        _openCall(contact, CallMediaType.audio),
                    onVideo: (contact) =>
                        _openCall(contact, CallMediaType.video),
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
  });
  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final DirectChatController directChats;
  final ContactAction onVoice;
  final ContactAction onVideo;

  @override
  State<ContactsTabPage> createState() => _ContactsTabPageState();
}

final class _ContactsTabPageState extends State<ContactsTabPage> {
  Future<void> _openMessage(ContactDetails contact) async {
    try {
      final reference = await widget.directChats.open(contact.matrixUserId);
      final room = widget.matrix.sdkClient.getRoomById(reference.roomId);
      if (room == null) throw StateError('Matrix room is unavailable');
      if (!mounted) return;
      await Navigator.push(
        context,
        CupertinoPageRoute(
          builder: (_) => RoomPage(room: room, roomName: contact.displayName),
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
      onCaibi: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => CupertinoPageScaffold(
                  navigationBar:
                      const CupertinoNavigationBar(middle: Text('彩币')),
                  child: CaibiPage(api: widget.api)))),
      onRedPacket: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => CupertinoPageScaffold(
                  navigationBar:
                      const CupertinoNavigationBar(middle: Text('红包')),
                  child: RedPacketPage(api: widget.api)))),
      onWallet: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => CupertinoPageScaffold(
                  navigationBar:
                      const CupertinoNavigationBar(middle: Text('钱包')),
                  child: WalletPage(api: widget.api)))),
      onSettings: () => Navigator.push(context, CupertinoPageRoute(builder: (_) => SettingsPage(onLogout: widget.onLogout))),
      onLogout: widget.onLogout);
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
        navigationBar: const CupertinoNavigationBar(middle: Text('我')),
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
                      navigationBar:
                          const CupertinoNavigationBar(middle: Text('彩币')),
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
                      navigationBar:
                          const CupertinoNavigationBar(middle: Text('红包')),
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
                      navigationBar:
                          const CupertinoNavigationBar(middle: Text('钱包')),
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
                    builder: (_) => SettingsPage(onLogout: onLogout),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

final class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.onLogout});

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
        navigationBar: const CupertinoNavigationBar(middle: Text('设置')),
        child: SafeArea(
          child: ListView(
            children: [
              CupertinoListSection.insetGrouped(
                children: [
                  CupertinoListTile(
                    title: const Center(
                      child: Text(
                        '退出登录',
                        style: TextStyle(color: CupertinoColors.systemRed),
                      ),
                    ),
                    onTap: () => _confirmLogout(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}
