import 'package:flutter/cupertino.dart';

import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_identity_header.dart';
import 'profile_controller.dart';

final class ProfileExperiencePage extends StatefulWidget {
  const ProfileExperiencePage({
    super.key,
    required this.controller,
    required this.onCaibi,
    required this.onRedPacket,
    required this.onWallet,
    required this.onSettings,
    required this.onLogout,
  });

  final ProfileController controller;
  final VoidCallback onCaibi;
  final VoidCallback onRedPacket;
  final VoidCallback onWallet;
  final VoidCallback onSettings;
  final Future<void> Function() onLogout;

  @override
  State<ProfileExperiencePage> createState() => _ProfileExperiencePageState();
}

final class _ProfileExperiencePageState extends State<ProfileExperiencePage> {
  final nickname = TextEditingController();
  final signature = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_change);
    widget.controller.load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_change);
    nickname.dispose();
    signature.dispose();
    super.dispose();
  }

  void _change() {
    final profile = widget.controller.state.profile;
    if (profile != null && nickname.text.isEmpty) {
      nickname.text = profile.nickname;
      signature.text = profile.signature ?? '';
    }
    if (mounted) setState(() {});
  }

  Future<void> _confirmLogout() async {
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
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final profile = state.profile;
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('我')),
      child: SafeArea(
        child: profile == null
            ? Center(
                child: state.status == ProfileStatus.failed
                    ? ModernActionButton(
                        icon: CupertinoIcons.refresh,
                        label: '重试',
                        onPressed: widget.controller.load,
                      )
                    : const CupertinoActivityIndicator(),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  UserIdentityHeader(
                    username: profile.username,
                    nickname: profile.nickname,
                    signature: profile.signature,
                    fallbackSeed: profile.fallbackSeed,
                    avatarUrl: profile.avatarUrl,
                  ),
                  const SizedBox(height: 20),
                  CupertinoTextField(
                    controller: nickname,
                    placeholder: '昵称',
                  ),
                  const SizedBox(height: 12),
                  CupertinoTextField(
                    controller: signature,
                    placeholder: '个性签名',
                  ),
                  const SizedBox(height: 16),
                  ModernActionButton(
                    icon: CupertinoIcons.check_mark,
                    label: '保存资料',
                    loading: state.status == ProfileStatus.saving,
                    onPressed: () => widget.controller.save(
                      nickname.text.trim(),
                      signature.text.trim(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ModernActionButton(
                    icon: CupertinoIcons.photo,
                    label: '选择并裁剪头像',
                    onPressed: widget.controller.chooseAvatar,
                  ),
                  if (state.candidate != null) ...[
                    const SizedBox(height: 12),
                    Image.memory(state.candidate!.bytes, height: 160),
                    const SizedBox(height: 8),
                    if (state.status == ProfileStatus.uploading)
                      Row(
                        children: [
                          const CupertinoActivityIndicator(),
                          const SizedBox(width: 8),
                          Text('上传 ${(state.progress * 100).round()}%'),
                        ],
                      ),
                    ModernActionButton(
                      icon: CupertinoIcons.cloud_upload,
                      label: state.status == ProfileStatus.failed
                          ? '重试上传'
                          : '确认上传',
                      onPressed: state.status == ProfileStatus.failed
                          ? widget.controller.retryAvatar
                          : widget.controller.uploadAvatar,
                    ),
                    ModernActionButton(
                      icon: CupertinoIcons.clear,
                      label: '取消',
                      kind: ModernActionKind.secondary,
                      onPressed: widget.controller.cancelPreview,
                    ),
                  ],
                  ModernActionButton(
                    icon: CupertinoIcons.person_crop_circle_badge_minus,
                    label: '恢复默认头像',
                    kind: ModernActionKind.secondary,
                    onPressed: widget.controller.restoreDefaultAvatar,
                  ),
                  if (state.message != null)
                    Text(
                      state.message!,
                      style: const TextStyle(color: CupertinoColors.systemRed),
                    ),
                  const SizedBox(height: 12),
                  Text('邮箱：${profile.maskedEmail}'),
                  const SizedBox(height: 20),
                  ModernActionButton(
                    icon: CupertinoIcons.money_dollar_circle,
                    label: '彩币',
                    kind: ModernActionKind.secondary,
                    onPressed: widget.onCaibi,
                  ),
                  const SizedBox(height: 10),
                  ModernActionButton(
                    icon: CupertinoIcons.gift,
                    label: '红包',
                    kind: ModernActionKind.secondary,
                    onPressed: widget.onRedPacket,
                  ),
                  const SizedBox(height: 10),
                  ModernActionButton(
                    icon: CupertinoIcons.creditcard,
                    label: '钱包',
                    kind: ModernActionKind.secondary,
                    onPressed: widget.onWallet,
                  ),
                  const SizedBox(height: 10),
                  ModernActionButton(
                    icon: CupertinoIcons.settings,
                    label: '设置',
                    kind: ModernActionKind.secondary,
                    onPressed: widget.onSettings,
                  ),
                  const SizedBox(height: 10),
                  ModernActionButton(
                    icon: CupertinoIcons.square_arrow_right,
                    label: '退出登录',
                    kind: ModernActionKind.danger,
                    onPressed: _confirmLogout,
                  ),
                ],
              ),
      ),
    );
  }
}
