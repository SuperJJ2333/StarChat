import 'package:flutter/cupertino.dart';

import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/changliao_icons.dart';
import 'contact_models.dart';

final class FriendIdentityCard extends StatelessWidget {
  const FriendIdentityCard({super.key, required this.contact});
  final ContactDetails contact;

  @override
  Widget build(BuildContext context) => Container(
        color: CupertinoTheme.of(context).scaffoldBackgroundColor,
        padding: const EdgeInsets.fromLTRB(24, 28, 20, 28),
        child: Row(children: [
          UserAvatar(
            nickname: contact.displayName,
            fallbackSeed: contact.username,
            avatarUrl: contact.avatarUrl,
            size: 72,
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contact.displayName,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '畅聊号：${contact.username}',
                  style: const TextStyle(
                    color: CupertinoColors.secondaryLabel,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ]),
      );
}

final class FriendMomentsPreview extends StatelessWidget {
  const FriendMomentsPreview({super.key, this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => CupertinoListSection(
        margin: const EdgeInsets.only(top: 12),
        children: [
          CupertinoListTile(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            title: const Text('朋友圈'),
            trailing: const Row(mainAxisSize: MainAxisSize.min, children: [
              _MomentSwatch(color: Color(0xFF576B95)),
              SizedBox(width: 6),
              _MomentSwatch(color: Color(0xFF95EC69)),
              SizedBox(width: 6),
              _MomentSwatch(color: Color(0xFFFA9D3B)),
              SizedBox(width: 8),
              CupertinoListTileChevron(),
            ]),
            onTap: onTap,
          ),
        ],
      );
}

final class _MomentSwatch extends StatelessWidget {
  const _MomentSwatch({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
        ),
      );
}

final class FriendActionRow extends StatelessWidget {
  const FriendActionRow({
    super.key,
    required this.onMessage,
    required this.onVoice,
    required this.onVideo,
  });
  final VoidCallback? onMessage;
  final VoidCallback? onVoice;
  final VoidCallback? onVideo;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 12),
        color: CupertinoTheme.of(context).scaffoldBackgroundColor,
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(children: [
          _FriendAction(
            icon: ChangliaoIcons.messages,
            label: '发消息',
            onPressed: onMessage,
          ),
          _FriendAction(
            icon: ChangliaoIcons.voiceCall,
            label: '语音通话',
            onPressed: onVoice,
          ),
          _FriendAction(
            icon: ChangliaoIcons.videoCall,
            label: '视频通话',
            onPressed: onVideo,
          ),
        ]),
      );
}

final class _FriendAction extends StatelessWidget {
  const _FriendAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Expanded(
        child: CupertinoButton(
          minimumSize: const Size(44, 64),
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 25),
            const SizedBox(height: 7),
            Text(label, style: const TextStyle(fontSize: 14)),
          ]),
        ),
      );
}
