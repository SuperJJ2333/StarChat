import 'package:flutter/cupertino.dart';
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
                    onTap: _openDetails,
                    onQrCode: widget.onQrCode,
                  ),
                  const SizedBox(height: 12),
                  _ProfileMenuTile(
                    key: const Key('profile-details-entry'),
                    icon: CupertinoIcons.person_crop_circle,
                    label: '个人信息',
                    onTap: _openDetails,
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

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _copyCode(String code) async {
    try {
      await Clipboard.setData(ClipboardData(text: code));
      widget.controller.showMessage('邀请码已复制');
    } catch (_) {
      widget.controller.showMessage('复制失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final state = widget.controller.state;
    final invite = state.invite;
    final background =
        dark ? WeChatColors.darkElevated : WeChatColors.lightElevated;
    final foreground =
        dark ? WeChatColors.darkTextPrimary : WeChatColors.lightTextPrimary;
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
                              fontSize: 14,
                              color: WeChatColors.textSecondary)),
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
        _summaryRow(
          key: const Key('profile-invite-code-full'),
          leading: const Icon(CupertinoIcons.ticket,
              size: 21, color: WeChatColors.brandPrimary),
          label: '邀请码全称',
          trailing: Text(
            invite.code,
            key: const Key('profile-invite-code-full-value'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 15, letterSpacing: 1.5, color: foreground),
          ),
        ),
        _divider(),
        _summaryRow(
          key: const Key('profile-invite-remaining'),
          leading: const Icon(CupertinoIcons.person_2,
              size: 21, color: WeChatColors.brandPrimary),
          label: '剩余可用次数',
          trailing: Text(
            '${invite.remainingUses}',
            key: const Key('profile-invite-remaining-count'),
            style: TextStyle(fontSize: 15, color: foreground),
          ),
        ),
        _divider(),
        CupertinoButton(
          key: const Key('profile-invite-one-click-copy'),
          padding: EdgeInsets.zero,
          onPressed: () => _copyCode(invite.code),
          child: Container(
            height: 57,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const SizedBox(
                  width: 40,
                  child: Icon(CupertinoIcons.doc_on_doc,
                      size: 21, color: WeChatColors.brandPrimary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('一键复制',
                      style: TextStyle(fontSize: 16, color: foreground)),
                ),
                const Icon(CupertinoIcons.chevron_right,
                    size: 12, color: WeChatColors.textSecondary),
              ],
            ),
          ),
        ),
      ];

  Widget _summaryRow({
    required Key key,
    required Widget leading,
    required String label,
    required Widget trailing,
  }) =>
      Container(
        key: key,
        height: 57,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            SizedBox(width: 40, child: leading),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: DefaultTextStyle.of(context)
                      .style
                      .copyWith(fontSize: 16)),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      );

  Widget _divider() => Container(
        margin: const EdgeInsets.only(left: 68),
        height: .5,
        color: CupertinoTheme.of(context).brightness == Brightness.dark
            ? WeChatColors.darkDivider
            : WeChatColors.divider,
      );
}
