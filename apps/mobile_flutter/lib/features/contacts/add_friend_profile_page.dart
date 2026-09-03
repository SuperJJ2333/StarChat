import 'package:flutter/cupertino.dart';

import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'contact_models.dart';
import 'request_friend_page.dart';

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
  });

  final AddFriendGateway api;
  final String userId;
  final String username;
  final String nickname;

  /// NONE / REUSABLE / OUTGOING_PENDING / FRIEND。
  final String relationshipState;
  final String? avatarUrl;

  bool get _canRequest =>
      relationshipState == 'NONE' || relationshipState == 'REUSABLE';

  String get _stateLabel => switch (relationshipState) {
        'FRIEND' => '已是好友',
        'OUTGOING_PENDING' => '申请已发送，等待对方验证',
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
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return WeChatPageScaffold.navigation(
      backgroundColor: dark
          ? WeChatColors.darkPageBackground
          : WeChatColors.lightPageBackground,
      navigationBar: const CupertinoNavigationBar(middle: Text('用户资料')),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 48),
            UserAvatar(
              nickname: nickname,
              fallbackSeed: userId,
              avatarUrl: avatarUrl,
              size: 96,
              diagnosticSource: 'add-friend-profile',
            ),
            const SizedBox(height: 16),
            Text(
              nickname,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: dark
                    ? WeChatColors.darkTextPrimary
                    : WeChatColors.lightTextPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '畅聊号：$username',
              style: const TextStyle(
                fontSize: 14,
                color: WeChatColors.textSecondary,
              ),
            ),
            const SizedBox(height: 36),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: CupertinoButton(
                  key: const Key('add-friend-profile-add'),
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
