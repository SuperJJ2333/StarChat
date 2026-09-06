import 'package:flutter/cupertino.dart';

import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';

/// 通过朋友验证页（BUG 2）：新的朋友列表点击请求 → 展示
/// 头像/昵称/greeting → 通过验证 或 拒绝。私人备注和标签不展示。
///
/// 仅当用户点击「通过验证」时才由回调触发
/// `POST /friends/requests/{id}/accept`。
final class FriendRequestReviewPage extends StatelessWidget {
  const FriendRequestReviewPage({
    super.key,
    required this.request,
    required this.onAccept,
    required this.onReject,
    this.busy = false,
  });

  /// /friends/requests 列表项：
  /// {id, username, nickname, avatar_url, matrix_user_id, message,
  ///  remark, tags, status, requested_at}
  final Map request;

  /// 由「新的朋友」页提供的受理动作（accept 仅在点击通过验证时调用）。
  final Future<void> Function() onAccept;
  final Future<void> Function() onReject;
  final bool busy;

  bool get _pending => request['status']?.toString() == 'PENDING';

  String get _statusLabel => switch (request['status']?.toString()) {
        'ACCEPTED' => '已添加',
        'REJECTED' => '已拒绝',
        'EXPIRED' => '已过期',
        'CANCELLED' => '对方已撤销申请',
        _ => '等待验证',
      };

  String get _nickname => request['nickname']?.toString().isNotEmpty == true
      ? request['nickname'].toString()
      : request['username']?.toString() ?? '';

  String get _greeting {
    final message = request['message']?.toString() ?? '';
    return message.isEmpty ? '我是${request['username'] ?? ''}' : message;
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return WeChatPageScaffold.navigation(
      backgroundColor: dark
          ? WeChatColors.darkPageBackground
          : WeChatColors.lightPageBackground,
      navigationBar: const CupertinoNavigationBar(middle: Text('通过朋友验证')),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 32, 16, 24),
          children: [
            Center(
              child: UserAvatar(
                nickname: _nickname,
                fallbackSeed: request['username']?.toString() ?? '',
                avatarUrl: request['avatar_url']?.toString(),
                size: 84,
                diagnosticSource: 'friend-request-review',
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: Text(
                _nickname,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: dark
                      ? WeChatColors.darkTextPrimary
                      : WeChatColors.lightTextPrimary,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                '畅聊号：${request['username'] ?? ''}',
                style: const TextStyle(
                    fontSize: 13, color: WeChatColors.textSecondary),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: WeChatColors.elevatedSurface(context),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '打招呼',
                    style: TextStyle(
                        fontSize: 13, color: WeChatColors.textSecondary),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _greeting,
                    key: const Key('friend-request-greeting'),
                    style: const TextStyle(fontSize: 15),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            if (_pending) ...[
              SizedBox(
                height: 48,
                child: CupertinoButton(
                  key: const Key('friend-request-accept'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  alignment: Alignment.center,
                  color: WeChatColors.brandPrimary,
                  borderRadius: BorderRadius.circular(12),
                  onPressed: busy ? null : () => onAccept(),
                  child: busy
                      ? const CupertinoActivityIndicator(
                          color: CupertinoColors.white)
                      : const Text('通过验证',
                          style: TextStyle(
                              fontSize: 16, color: CupertinoColors.white)),
                ),
              ),
              const SizedBox(height: 12),
              CupertinoButton(
                key: const Key('friend-request-reject'),
                onPressed: busy ? null : () => onReject(),
                child: const Text('拒绝',
                    style: TextStyle(fontSize: 15, color: WeChatColors.danger)),
              ),
            ] else
              Center(
                child: Text(
                  _statusLabel,
                  key: const Key('friend-request-status'),
                  style: const TextStyle(
                      fontSize: 15, color: WeChatColors.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
