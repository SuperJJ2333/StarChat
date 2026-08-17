import 'package:flutter/cupertino.dart';

import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'contact_models.dart';

final class FriendIdentityCard extends StatelessWidget {
  const FriendIdentityCard({super.key, required this.contact});
  final ContactDetails contact;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('friend-identity-card'),
        height: 126,
        color: CupertinoTheme.of(context).brightness == Brightness.dark
            ? WeChatColors.darkElevated
            : WeChatColors.lightElevated,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Row(
          children: [
            UserAvatar(
              nickname: contact.displayName,
              fallbackSeed: contact.username,
              avatarUrl: contact.avatarUrl,
              size: 72,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: WeChatTypography.title1,
                      fontWeight: FontWeight.w700,
                      height: 30 / 22,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '畅聊号：${contact.username}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: WeChatColors.textSecondary,
                      fontSize: WeChatTypography.subhead,
                      height: 20 / 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '刚刚在线',
                    style: TextStyle(
                      color: WeChatColors.textSecondary,
                      fontSize: WeChatTypography.subhead,
                      height: 20 / 14,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

final class FriendMomentsPreview extends StatelessWidget {
  const FriendMomentsPreview({super.key, this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final elevated = CupertinoTheme.of(context).brightness == Brightness.dark
        ? WeChatColors.darkElevated
        : WeChatColors.lightElevated;
    final preview = CupertinoTheme.of(context).brightness == Brightness.dark
        ? WeChatColors.darkSurface
        : WeChatColors.lightSurface;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: CupertinoButton(
        key: const Key('friend-moments-section'),
        minimumSize: Size.zero,
        padding: EdgeInsets.zero,
        onPressed: onTap,
        child: Container(
          height: 120,
          color: elevated,
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final previewWidth =
                  ((constraints.maxWidth - 100) / 3).clamp(0, 87).toDouble();
              return Row(
                children: [
                  const SizedBox(
                    width: 80,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '朋友圈',
                        style: TextStyle(
                          fontSize: WeChatTypography.callout,
                          color: CupertinoColors.label,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  for (var index = 0; index < 3; index++) ...[
                    Container(
                      key: Key('friend-moment-preview-$index'),
                      width: previewWidth,
                      height: 88,
                      color: preview,
                      alignment: Alignment.center,
                      child: Text(
                        '动态 ${index + 1}',
                        style: const TextStyle(
                          fontSize: WeChatTypography.badge,
                          color: WeChatColors.textSecondary,
                        ),
                      ),
                    ),
                    if (index < 2) const SizedBox(width: 4),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

final class FriendActionColumn extends StatelessWidget {
  const FriendActionColumn({
    super.key,
    required this.onMessage,
    required this.onVoice,
    required this.onVideo,
  });

  final VoidCallback? onMessage;
  final VoidCallback? onVoice;
  final VoidCallback? onVideo;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Column(
          children: [
            _FriendActionButton(
              actionKey: 'message',
              icon: ChangliaoIcons.messages,
              label: '发消息',
              onPressed: onMessage,
            ),
            const SizedBox(height: 12),
            _FriendActionButton(
              actionKey: 'voice',
              icon: ChangliaoIcons.voiceCall,
              label: '语音通话',
              onPressed: onVoice,
            ),
            const SizedBox(height: 12),
            _FriendActionButton(
              actionKey: 'video',
              icon: ChangliaoIcons.videoCall,
              label: '视频通话',
              onPressed: onVideo,
            ),
          ],
        ),
      );
}

final class _FriendActionButton extends StatelessWidget {
  const _FriendActionButton({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final String actionKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        key: Key('friend-action-$actionKey'),
        width: double.infinity,
        height: 48,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          color: CupertinoTheme.of(context).brightness == Brightness.dark
              ? WeChatColors.darkElevated
              : WeChatColors.lightElevated,
          borderRadius: BorderRadius.circular(WeChatRadius.authControl),
          onPressed: onPressed,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: WeChatColors.brandPrimary),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: WeChatTypography.callout,
                  color: CupertinoColors.label,
                ),
              ),
            ],
          ),
        ),
      );
}
