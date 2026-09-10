import 'contact_actions.dart';
import 'package:flutter/cupertino.dart';

import 'contact_profile_sections.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'contact_models.dart';
import '../matrix/profile_repository.dart';
import 'request_friend_page.dart';
import '../../core/business_api_client.dart';
import '../moments/moment_profile_preview.dart';

/// 用户资料页（BUG 2 流程：搜索 → 用户资料 → 添加到通讯录 → 申请页）。
///
/// 搜索结果点击先进入本页查看对方资料；「添加到通讯录」才进入
/// 申请添加朋友页编辑 greeting/remark/tags 后发送——禁止跳过资料
/// 确认直接发送请求。
final class AddFriendProfilePage extends StatelessWidget {
  const AddFriendProfilePage({
    super.key,
    required this.api,
    required this.userId,
    required this.username,
    required this.nickname,
    required this.relationshipState,
    this.avatarUrl,
    this.identityCache,
    this.contactActions,
  });

  final AddFriendGateway api;
  final ContactActions? contactActions;
  final ProfileRepository? identityCache;
  final String userId;
  final String username;
  final String nickname;

  /// NONE / REUSABLE / OUTGOING_PENDING / FRIEND。
  final String relationshipState;
  final String? avatarUrl;

  bool get _canRequest =>
      relationshipState == 'NONE' || relationshipState == 'REUSABLE';

  String get _stateLabel => switch (relationshipState) {
        'SELF' => '我',
        'FRIEND' => '已是好友',
        'OUTGOING_PENDING' => '申请已发送，等待对方验证',
        'INCOMING_PENDING' => '等待好友验证',
        _ => '',
      };

  void _openRequestPage(BuildContext context) {
    Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (_) => RequestFriendPage(
          api: api,
          userId: userId,
          username: username,
          nickname: nickname,
          avatarUrl: avatarUrl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => identityCache == null
      ? _buildContent(context)
      : ListenableBuilder(
          listenable: identityCache!,
          builder: (context, _) => _buildContent(context));
  Widget _buildContent(BuildContext context) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return WeChatPageScaffold.navigation(
      backgroundColor: dark
          ? WeChatColors.darkPageBackground
          : WeChatColors.lightPageBackground,
      navigationBar: const CupertinoNavigationBar(
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: Text('用户资料'),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            ProfileIdentityCard(
              userId: userId,
              username: username,
              nickname: nickname,
              avatarUrl: avatarUrl,
              identityCache: identityCache,
            ),
            if (api is BusinessApiClient)
              MomentProfilePreview(
                contactActions: contactActions,
                identityCache: identityCache,
                  api: api as BusinessApiClient,
                  userId: userId,
                  displayName: nickname),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                    minHeight: 48, minWidth: double.infinity),
                child: CupertinoButton(
                  key: const Key('add-friend-profile-add'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  alignment: Alignment.center,
                  color: WeChatColors.brandPrimary,
                  borderRadius: BorderRadius.circular(12),
                  onPressed:
                      _canRequest ? () => _openRequestPage(context) : null,
                  child: Text(
                    _canRequest ? '添加到通讯录' : _stateLabel,
                    style: const TextStyle(
                        fontSize: 16, color: CupertinoColors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
