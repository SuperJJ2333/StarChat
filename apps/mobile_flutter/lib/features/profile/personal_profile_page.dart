import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';


import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_scaffold.dart';
import 'profile_controller.dart';
import 'profile_avatar_page.dart';

/// 微信式「个人信息」页：头像 / 昵称 / 性别 / 地区 / 畅聊号 / 邮箱 / 拍一拍。
/// 性别与地区当前为客户端本地资料（v1），昵称走业务 API 保存。
final class PersonalProfilePage extends StatefulWidget {
  const PersonalProfilePage({super.key, required this.controller});

  final ProfileController controller;

  @override
  State<PersonalProfilePage> createState() => _PersonalProfilePageState();
}

const _genderOptions = <String>['男', '女', '保密'];
const _regions = <String>[
  '北京', '上海', '广东', '江苏', '浙江', '四川', '湖北', '湖南',
  '山东', '河南', '河北', '福建', '陕西', '辽宁', '其他',
];

final class _PersonalProfilePageState extends State<PersonalProfilePage> {
  String gender = '保密';
  String region = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_change);
    widget.controller.load();
    _loadLocalProfile();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_change);
    super.dispose();
  }

  Future<void> _loadLocalProfile() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      gender = prefs.getString('profile-gender') ?? '保密';
      region = prefs.getString('profile-region') ?? '';
    });
  }

  Future<void> _saveLocal(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
    if (!mounted) return;
    setState(() {});
  }

  void _change() {
    if (mounted) setState(() {});
  }

  Future<void> _chooseGender() async {
    final selected = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('性别'),
        actions: [
          for (final option in _genderOptions)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheetContext, option),
              child: Text(option),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected != null) await _saveLocal('profile-gender', selected);
  }

  Future<void> _chooseRegion() async {
    final selected = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('选择地区'),
        actions: [
          for (final option in _regions)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheetContext, option),
              child: Text(option),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected != null) await _saveLocal('profile-region', selected);
  }

  Future<void> _editNickname(String current) async {
    final controller = TextEditingController(text: current);
    final nickname = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('修改昵称'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            key: const Key('personal-nickname-input'),
            controller: controller,
            maxLength: 20,
            autofocus: true,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (nickname == null || nickname.isEmpty || nickname == current) return;
    final signature = widget.controller.state.profile?.signature;
    await widget.controller.save(nickname, signature);
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.controller.state.profile;
    final nickname = profile?.nickname ?? '';
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const Text('个人信息'),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            CupertinoListSection.insetGrouped(
              margin: EdgeInsets.zero,
              children: [
                CupertinoListTile(
                  key: const Key('personal-avatar-row'),
                  title: const Text('头像'),
                  trailing: UserAvatar(
                    nickname: nickname,
                    fallbackSeed: profile?.fallbackSeed ?? widget.controller.hashCode.toString(),
                    avatarUrl: profile?.avatarUrl,
                    size: 48,
                  ),
                  onTap: () => Navigator.push(
                    context,
                    CupertinoPageRoute(
                      builder: (_) =>
                          ProfileAvatarPage(controller: widget.controller),
                    ),
                  ),
                ),
                CupertinoListTile(
                  key: const Key('personal-nickname-row'),
                  title: const Text('昵称'),
                  additionalInfo: Text(nickname.isEmpty ? '未设置' : nickname),
                  trailing: const CupertinoListTileChevron(),
                  onTap: nickname.isEmpty ? null : () => _editNickname(nickname),
                ),
              ],
            ),
            CupertinoListSection.insetGrouped(
              margin: const EdgeInsets.only(top: 12),
              children: [
                CupertinoListTile(
                  key: const Key('personal-gender-row'),
                  title: const Text('性别'),
                  additionalInfo: Text(gender),
                  trailing: const CupertinoListTileChevron(),
                  onTap: _chooseGender,
                ),
                CupertinoListTile(
                  key: const Key('personal-region-row'),
                  title: const Text('地区'),
                  additionalInfo: Text(region.isEmpty ? '未选择' : region),
                  trailing: const CupertinoListTileChevron(),
                  onTap: _chooseRegion,
                ),
              ],
            ),
            CupertinoListSection.insetGrouped(
              margin: const EdgeInsets.only(top: 12),
              children: [
                CupertinoListTile(
                  title: const Text('畅聊号'),
                  additionalInfo: Text(profile?.username ?? '—'),
                ),
                CupertinoListTile(
                  title: const Text('邮箱'),
                  additionalInfo: Text(profile?.maskedEmail ?? '—'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
