import 'package:flutter/cupertino.dart';

import 'core/business_api_client.dart';
import 'features/caibi/caibi_page.dart';
import 'features/contacts/contacts_page.dart';
import 'features/discovery/discovery_page.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'features/matrix/matrix_home_page.dart';
import 'features/redpacket/redpacket_page.dart';
import 'features/wallet/wallet_page.dart';
import 'ui/components/wechat_list_tile.dart';
import 'features/profile/profile_controller.dart';
import 'features/profile/profile_page.dart';
import 'features/profile/avatar_source.dart';

final class AppHome extends StatelessWidget {
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
  Widget build(BuildContext context) => CupertinoTabScaffold(
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
            0 => MatrixHomePage(matrix: matrix),
            1 => ContactsPage(api: api),
            2 => DiscoveryPage(api: api),
            _ => ProfileTabPage(api: api, onLogout: onLogout),
          },
        ),
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
      onSettings: () => Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => SettingsPage(onLogout: widget.onLogout))),
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
