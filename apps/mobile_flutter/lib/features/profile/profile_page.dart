import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';

import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/wechat_nav_title.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'profile_controller.dart';
import 'invite_controller.dart';
import 'profile_avatar_page.dart';

final class ProfileExperiencePage extends StatefulWidget {
  const ProfileExperiencePage({
    super.key,
    required this.controller,
    required this.onMoments,
    required this.onCaibi,
    required this.onWallet,
    required this.onInvite,
    required this.onSettings,
    this.onQrCode,
    this.inviteGateway,
  });

  final ProfileController controller;
  final VoidCallback onMoments;
  final VoidCallback onCaibi;
  final VoidCallback onWallet;

  /// 邀请码入口：好友注册填写邀请码，建立邀请关系。
  final VoidCallback onInvite;

  /// 邀请码数据源（转发给个人信息页“一键复制/剩余次数/全称”区域）；
  /// 缺省时该区域整体隐藏（保持旧页面行为）。
  final PersonalInvitationGateway? inviteGateway;

  /// “我的二维码”入口（身份卡右上角）；缺省时隐藏角标。
  final VoidCallback? onQrCode;
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

  void _openDetails() => Navigator.push(
        context,
        CupertinoPageRoute(
          builder: (_) => ProfileDetailsPage(
            controller: widget.controller,
            onInvite: widget.onInvite,
            inviteGateway: widget.inviteGateway,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final profile = state.profile;
    return WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.pageBackground(context),
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.navigationBackground(context),
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const WeChatNavTitle('我')),
      child: SafeArea(
        child: ListView(
          key: const Key('profile-home-list'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          children: [
            if (profile == null)
              _ProfileIdentityPlaceholder(
                failed: state.status == ProfileStatus.failed,
                onRetry: widget.controller.load,
              )
            else ...[
              _IdentityCard(
                profile: profile,
                onTap: _openDetails,
                onQrCode: widget.onQrCode,
              ),
            ],
            const SizedBox(height: 12),
            _ProfileMenuTile(
              key: const Key('profile-details-entry'),
              icon: CupertinoIcons.person_crop_circle,
              label: '个人信息',
              onTap: profile == null ? null : _openDetails,
            ),
            _ProfileMenuTile(
              icon: CupertinoIcons.photo_on_rectangle,
              label: '朋友圈',
              onTap: widget.onMoments,
            ),
            _ProfileMenuTile(
              icon: CupertinoIcons.money_dollar_circle,
              label: '点钻',
              onTap: widget.onCaibi,
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

final class _ProfileIdentityPlaceholder extends StatelessWidget {
  const _ProfileIdentityPlaceholder(
      {required this.failed, required this.onRetry});

  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
        height: 126,
        alignment: Alignment.center,
        color: WeChatColors.pageBackground(context),
        child: failed
            ? ModernActionButton(
                icon: ChangliaoIcons.retry,
                label: '重试资料',
                onPressed: onRetry,
              )
            : const CupertinoActivityIndicator(),
      );
}

final class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.profile,
    required this.onTap,
    this.onQrCode,
  });

  final ProfileData profile;
  final VoidCallback onTap;

  /// 右上角「二维码」入口：点击打开“我的二维码”页（微信式）。
  final VoidCallback? onQrCode;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final foreground =
        dark ? WeChatColors.darkTextPrimary : WeChatColors.lightTextPrimary;
    return CupertinoButton(
      key: const Key('profile-identity-card'),
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Stack(
        children: [
          Container(
            height: 126,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            color:
                dark ? WeChatColors.darkElevated : WeChatColors.lightElevated,
            child: Row(
              children: [
                SizedBox(
                  width: 72,
                  height: 72,
                  child: UserAvatar(
                    key: const Key('profile-identity-avatar'),
                    nickname: profile.nickname,
                    fallbackSeed: profile.fallbackSeed,
                    avatarUrl: profile.avatarUrl,
                    size: 72,
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
          if (onQrCode != null)
            Positioned(
              top: 0,
              right: 0,
              child: CupertinoButton(
                key: const Key('profile-qr-entry'),
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.all(10),
                onPressed: onQrCode,
                child: Icon(CupertinoIcons.qrcode,
                    size: 22, color: WeChatColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

final class _ProfileMenuTile extends StatelessWidget {
  const _ProfileMenuTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

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
  const ProfileDetailsPage({
    super.key,
    required this.controller,
    this.onInvite,
    this.inviteGateway,
  });

  final ProfileController controller;
  final VoidCallback? onInvite;

  /// 邀请码数据源（个人信息页邀请码区域：全称/剩余次数/一键复制）。
  final PersonalInvitationGateway? inviteGateway;

  @override
  State<ProfileDetailsPage> createState() => _ProfileDetailsPageState();
}

final class _ProfileDetailsPageState extends State<ProfileDetailsPage> {
  InviteCodeController? _inviteController;

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
    nickname.addListener(_change);
    signature.addListener(_change);
    final gateway = widget.inviteGateway;
    if (gateway != null) {
      final controller = InviteCodeController(gateway: gateway);
      _inviteController = controller;
      controller.addListener(_change);
      controller.load();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_change);
    _inviteController?.removeListener(_change);
    _inviteController?.dispose();
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
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
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
                  onTap: () => Navigator.push(
                    context,
                    CupertinoPageRoute(
                      builder: (_) => ProfileAvatarPage(
                        controller: widget.controller,
                      ),
                    ),
                  ),
                ),
                CupertinoListTile(
                  title: const Text('畅聊号'),
                  additionalInfo: Text(profile.username),
                ),
                CupertinoListTile(
                  title: const Text('邮箱'),
                  additionalInfo: Text(profile.maskedEmail),
                ),
                CupertinoListTile(
                  key: const Key('profile-nudge-row'),
                  title: const Text('拍一拍'),
                  additionalInfo: Text(profile.nudgeSuffix ?? '未设置'),
                  trailing: const CupertinoListTileChevron(),
                  onTap: () async {
                    await Navigator.push<void>(
                      context,
                      CupertinoPageRoute(
                        builder: (_) => _ProfileNudgePage(
                          controller: widget.controller,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (widget.onInvite != null) ...[
              _ProfileMenuTile(
                key: const Key('profile-invite-entry'),
                icon: CupertinoIcons.person_crop_circle_badge_plus,
                label: '邀请码',
                onTap: widget.onInvite!,
              ),
              if (_inviteController != null) ...[
                const SizedBox(height: 12),
                _InviteSummarySection(
                    key: const Key('profile-invite-summary'),
                    controller: _inviteController!),
              ],
              const SizedBox(height: 12),
            ],
            CupertinoTextField(
              controller: nickname,
              textAlign:
                  nickname.text.isEmpty ? TextAlign.left : TextAlign.right,
              placeholder: '昵称',
              padding: const EdgeInsets.all(16),
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: signature,
              textAlign:
                  signature.text.isEmpty ? TextAlign.left : TextAlign.right,
              placeholder: '个性签名',
              padding: const EdgeInsets.all(16),
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

final class _ProfileNudgePage extends StatefulWidget {
  const _ProfileNudgePage({required this.controller});
  final ProfileController controller;

  @override
  State<_ProfileNudgePage> createState() => _ProfileNudgePageState();
}

final class _ProfileNudgePageState extends State<_ProfileNudgePage> {
  late final suffix = TextEditingController(
    text: widget.controller.state.profile?.nudgeSuffix ?? '',
  );

  @override
  void dispose() {
    suffix.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.controller.state.profile!;
    final saving = widget.controller.state.status == ProfileStatus.saving;
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const Text('设置拍一拍'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: saving
              ? null
              : () async {
                  await widget.controller.save(
                    profile.nickname,
                    profile.signature,
                    nudgeSuffix: suffix.text.trim(),
                  );
                  if (context.mounted &&
                      widget.controller.state.status == ProfileStatus.ready) {
                    Navigator.pop(context);
                  }
                },
          child: const Text('保存'),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            CupertinoTextField(
              key: const Key('profile-nudge-field'),
              controller: suffix,
              maxLength: 10,
              autofocus: true,
              placeholder: '例如：拍了拍我',
              padding: const EdgeInsets.all(16),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 10, left: 4),
              child: Text('朋友拍一拍你时显示的后缀；拍自己也使用此后缀。'),
            ),
            if (widget.controller.state.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 10, left: 4),
                child: Text(
                  widget.controller.state.message!,
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 个人信息页邀请码区域（规格 #3）：邀请码全称 + 剩余可用次数 +
/// 一键复制。样式与“邀请码入口”行一致（同高度/圆角/背景/内边距），
/// 适配暗黑模式；数据来自 /invitations/mine，含加载/失败/重试状态。
final class _InviteSummarySection extends StatefulWidget {
  const _InviteSummarySection({super.key, required this.controller});

  final InviteCodeController controller;

  @override
  State<_InviteSummarySection> createState() => _InviteSummarySectionState();
}

final class _InviteSummarySectionState extends State<_InviteSummarySection> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  Timer? _toastTimer;
  String? _toast;

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _toastTimer?.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// 复制下载链接：先出二级选项（安卓/苹果），选中后复制对应
  /// 平台链接并提示“复制成功”。
  Future<void> _choosePlatformAndCopy() async {
    final platform = await showCupertinoModalPopup<String>(
      context: context,
      semanticsDismissible: true,
      builder: (sheetContext) => CupertinoActionSheet(
        key: const Key('invite-download-platform-sheet'),
        title: const Text('选择下载链接平台'),
        actions: [
          CupertinoActionSheetAction(
            key: const Key('invite-download-android'),
            onPressed: () => Navigator.pop(sheetContext, 'android'),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.android,
                    size: 22, color: WeChatColors.brandPrimary),
                SizedBox(width: 8),
                Text('安卓'),
              ],
            ),
          ),
          CupertinoActionSheetAction(
            key: const Key('invite-download-ios'),
            onPressed: () => Navigator.pop(sheetContext, 'ios'),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.phone_iphone,
                    size: 22, color: WeChatColors.brandPrimary),
                SizedBox(width: 8),
                Text('苹果'),
              ],
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('取消'),
        ),
      ),
    );
    if (platform == null) return;
    final url = platform == 'android'
        ? 'https://www.liuhetong888.com/download'
        : 'https://www.liuhetong888.com/download?platform=ios';
    await _copyLink(url);
  }

  void _showToast(String message) {
    if (!mounted) return;
    setState(() => _toast = message);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  Future<void> _copyLink(String url) async {
    try {
      await Clipboard.setData(ClipboardData(text: url));
      _showToast('复制成功');
    } catch (_) {
      _showToast('复制失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final state = widget.controller.state;
    final invite = state.invite;
    final foreground =
        dark ? WeChatColors.darkTextPrimary : WeChatColors.lightTextPrimary;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _sectionBody(context, state, invite, foreground, dark),
        if (_toast != null)
          Positioned(
            left: 0,
            right: 0,
            top: -46,
            child: Center(
              child: Container(
                key: const Key('invite-copy-toast'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xCC000000),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(_toast!,
                    style: const TextStyle(
                        fontSize: 13, color: CupertinoColors.white)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _sectionBody(BuildContext context, InviteCodeState state,
      PersonalInvitation? invite, Color foreground, bool dark) {
    final background =
        dark ? WeChatColors.darkElevated : WeChatColors.lightElevated;
    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...switch (state.status) {
            InviteCodeStatus.idle || InviteCodeStatus.loading => [
                const SizedBox(
                    height: 57,
                    child: Center(child: CupertinoActivityIndicator())),
              ],
            InviteCodeStatus.failed => [
                SizedBox(
                  height: 57,
                  child: Center(
                    child: CupertinoButton(
                      key: const Key('profile-invite-summary-retry'),
                      onPressed: widget.controller.load,
                      child: const Text('邀请码加载失败，点击重试',
                          style: TextStyle(
                              fontSize: 14, color: WeChatColors.textSecondary)),
                    ),
                  ),
                ),
              ],
            InviteCodeStatus.ready => _rows(invite!, foreground),
          },
        ],
      ),
    );
  }

  List<Widget> _rows(PersonalInvitation invite, Color foreground) => [
        _linkRow(
          key: const Key('profile-invite-copy-download-link'),
          icon: CupertinoIcons.share,
          label: '复制下载链接',
          onTap: _choosePlatformAndCopy,
        ),
      ];

  Widget _linkRow({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) =>
      CupertinoButton(
        key: key,
        padding: EdgeInsets.zero,
        onPressed: onTap,
        child: Container(
          height: 57,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: Icon(icon, size: 21, color: WeChatColors.brandPrimary),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(label)),
              const Icon(CupertinoIcons.chevron_right,
                  size: 12, color: WeChatColors.textSecondary),
            ],
          ),
        ),
      );


}
