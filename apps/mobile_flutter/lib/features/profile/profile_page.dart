import 'package:flutter/cupertino.dart';

import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'profile_controller.dart';

final class ProfileExperiencePage extends StatefulWidget {
  const ProfileExperiencePage({
    super.key,
    required this.controller,
    required this.onMoments,
    required this.onCaibi,
    required this.onRedPacket,
    required this.onWallet,
    required this.onSettings,
  });

  final ProfileController controller;
  final VoidCallback onMoments;
  final VoidCallback onCaibi;
  final VoidCallback onRedPacket;
  final VoidCallback onWallet;
  final VoidCallback onSettings;

  @override
  State<ProfileExperiencePage> createState() => _ProfileExperiencePageState();
}

final class _ProfileExperiencePageState extends State<ProfileExperiencePage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_change);
    widget.controller.load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_change);
    super.dispose();
  }

  void _change() {
    if (mounted) setState(() {});
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
                        icon: ChangliaoIcons.retry,
                        label: '重试',
                        onPressed: widget.controller.load,
                      )
                    : const CupertinoActivityIndicator(),
              )
            : ListView(
                key: const Key('profile-home-list'),
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                children: [
                  _IdentityCard(
                    profile: profile,
                    onTap: () => Navigator.push(
                      context,
                      CupertinoPageRoute(
                        builder: (_) => ProfileDetailsPage(
                          controller: widget.controller,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ProfileMenuTile(
                    icon: CupertinoIcons.photo_on_rectangle,
                    label: '朋友圈',
                    onTap: widget.onMoments,
                  ),
                  _ProfileMenuTile(
                    icon: CupertinoIcons.money_dollar_circle,
                    label: '彩币',
                    onTap: widget.onCaibi,
                  ),
                  _ProfileMenuTile(
                    icon: ChangliaoIcons.gift,
                    label: '红包',
                    onTap: widget.onRedPacket,
                  ),
                  _ProfileMenuTile(
                    icon: ChangliaoIcons.wallet,
                    label: '钱包',
                    onTap: widget.onWallet,
                  ),
                  _ProfileMenuTile(
                    icon: ChangliaoIcons.settings,
                    label: '设置',
                    onTap: widget.onSettings,
                  ),
                ],
              ),
      ),
    );
  }
}

final class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.profile, required this.onTap});

  final ProfileData profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final foreground =
        dark ? WeChatColors.darkTextPrimary : WeChatColors.lightTextPrimary;
    return CupertinoButton(
      key: const Key('profile-identity-card'),
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Container(
        height: 126,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        color: dark ? WeChatColors.darkElevated : WeChatColors.lightElevated,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 72,
                height: 72,
                child: profile.avatarUrl == null
                    ? ColoredBox(
                        color: WeChatColors.brandPrimary,
                        child: Center(
                          child: Text(
                            profile.nickname.characters.first,
                            style: const TextStyle(
                              color: CupertinoColors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      )
                    : Image.network(profile.avatarUrl!, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.nickname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 22,
                      height: 30 / 22,
                      fontWeight: FontWeight.w700,
                      color: foreground,
                    ),
                  ),
                  Text(
                    '畅聊号：${profile.username}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: WeChatColors.textSecondary,
                      fontSize: 14,
                      height: 20 / 14,
                    ),
                  ),
                  Text(
                    profile.signature?.isNotEmpty == true
                        ? profile.signature!
                        : '还没有设置个性签名',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: WeChatColors.textSecondary,
                      fontSize: 14,
                      height: 20 / 14,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ProfileMenuTile extends StatelessWidget {
  const _ProfileMenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
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
              child: Icon(icon, size: 21, color: foreground),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 16, color: foreground),
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

final class ProfileDetailsPage extends StatefulWidget {
  const ProfileDetailsPage({super.key, required this.controller});

  final ProfileController controller;

  @override
  State<ProfileDetailsPage> createState() => _ProfileDetailsPageState();
}

final class _ProfileDetailsPageState extends State<ProfileDetailsPage> {
  late final nickname = TextEditingController(
    text: widget.controller.state.profile?.nickname ?? '',
  );
  late final signature = TextEditingController(
    text: widget.controller.state.profile?.signature ?? '',
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_change);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_change);
    nickname.dispose();
    signature.dispose();
    super.dispose();
  }

  void _change() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final profile = state.profile!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('个人信息'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: state.status == ProfileStatus.saving
              ? null
              : () => widget.controller.save(
                    nickname.text.trim(),
                    signature.text.trim(),
                  ),
          child: const Text('保存'),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            CupertinoListSection.insetGrouped(
              margin: EdgeInsets.zero,
              children: [
                CupertinoListTile(
                  title: const Text('头像'),
                  trailing: UserAvatar(
                    nickname: profile.nickname,
                    fallbackSeed: profile.fallbackSeed,
                    avatarUrl: profile.avatarUrl,
                    size: 48,
                  ),
                  onTap: widget.controller.chooseAvatar,
                ),
                CupertinoListTile(
                  title: const Text('畅聊号'),
                  additionalInfo: Text(profile.username),
                ),
                CupertinoListTile(
                  title: const Text('邮箱'),
                  additionalInfo: Text(profile.maskedEmail),
                ),
              ],
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: nickname,
              placeholder: '昵称',
              padding: const EdgeInsets.all(16),
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: signature,
              placeholder: '个性签名',
              padding: const EdgeInsets.all(16),
            ),
            const SizedBox(height: 16),
            ModernActionButton(
              icon: CupertinoIcons.photo,
              label: '选择并裁剪头像',
              onPressed: widget.controller.chooseAvatar,
            ),
            if (state.candidate != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(state.candidate!.bytes, height: 160),
              ),
              const SizedBox(height: 8),
              ModernActionButton(
                icon: CupertinoIcons.cloud_upload,
                label: state.status == ProfileStatus.failed ? '重试上传' : '确认上传',
                loading: state.status == ProfileStatus.uploading,
                onPressed: state.status == ProfileStatus.failed
                    ? widget.controller.retryAvatar
                    : widget.controller.uploadAvatar,
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
          ],
        ),
      ),
    );
  }
}
