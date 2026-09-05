import 'package:flutter/cupertino.dart';

import '../../ui/components/wechat_scaffold.dart';

import '../../ui/foundation/wechat_tokens.dart';

import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_avatar.dart';
import 'profile_controller.dart';

final class ProfileAvatarPage extends StatefulWidget {
  const ProfileAvatarPage({super.key, required this.controller});

  final ProfileController controller;

  @override
  State<ProfileAvatarPage> createState() => _ProfileAvatarPageState();
}

final class _ProfileAvatarPageState extends State<ProfileAvatarPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _restore() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('恢复默认头像'),
        content: const Text('当前头像将被移除，是否继续？'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.controller.restoreDefaultAvatar();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final profile = state.profile!;
    final candidate = state.candidate;
    final busy = state.status == ProfileStatus.selectingAvatar ||
        state.status == ProfileStatus.uploading;
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text('头像')),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Center(
              child: candidate == null
                  ? UserAvatar(
                      nickname: profile.nickname,
                      fallbackSeed: profile.fallbackSeed,
                      avatarUrl: profile.avatarUrl,
                      size: 176,
                    )
                  : ClipRRect(
                      key: const Key('profile-avatar-preview'),
                      borderRadius: BorderRadius.circular(18),
                      child: Image.memory(
                        candidate.bytes,
                        width: 176,
                        height: 176,
                        fit: BoxFit.cover,
                      ),
                    ),
            ),
            if (state.status == ProfileStatus.uploading) ...[
              const SizedBox(height: 16),
              CupertinoActivityIndicator.partiallyRevealed(
                progress: state.progress,
              ),
            ],
            const SizedBox(height: 24),
            ModernActionButton(
              key: const Key('profile-avatar-choose'),
              icon: CupertinoIcons.photo,
              label: candidate == null ? '从相册选择' : '重新选择',
              loading: state.status == ProfileStatus.selectingAvatar,
              onPressed: busy ? null : widget.controller.chooseAvatar,
            ),
            if (candidate != null) ...[
              const SizedBox(height: 12),
              ModernActionButton(
                key: const Key('profile-avatar-upload'),
                icon: CupertinoIcons.cloud_upload,
                label: state.status == ProfileStatus.failed ? '重试上传' : '使用此头像',
                loading: state.status == ProfileStatus.uploading,
                onPressed: state.status == ProfileStatus.uploading
                    ? null
                    : state.status == ProfileStatus.failed
                        ? widget.controller.retryAvatar
                        : widget.controller.uploadAvatar,
              ),
              const SizedBox(height: 12),
              ModernActionButton(
                icon: CupertinoIcons.clear,
                label: '取消预览',
                kind: ModernActionKind.secondary,
                onPressed: busy ? null : widget.controller.cancelPreview,
              ),
            ],
            const SizedBox(height: 12),
            ModernActionButton(
              icon: CupertinoIcons.person_crop_circle_badge_minus,
              label: '恢复默认头像',
              kind: ModernActionKind.secondary,
              onPressed: busy ? null : _restore,
            ),
            if (state.message != null) ...[
              const SizedBox(height: 12),
              Text(
                state.message!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: CupertinoColors.systemRed),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
