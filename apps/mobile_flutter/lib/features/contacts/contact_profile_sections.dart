import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'contact_models.dart';
import 'user_identity.dart';
import '../matrix/profile_repository.dart';

final class FriendIdentityCard extends StatelessWidget {
  const FriendIdentityCard(
      {super.key, required this.contact, this.identityCache, this.now});
  final ProfileRepository? identityCache;
  final ContactDetails contact;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) => ProfileIdentityCard(
        key: const Key('friend-identity-card'),
        userId: contact.userId,
        username: contact.username,
        matrixUserId: contact.matrixUserId,
        nickname: contact.nickname,
        remark: contact.remark,
        avatarUrl: contact.avatarUrl,
        identityCache: identityCache,
        lastSeenAt: contact.lastSeenAt,
        lastSeenKnown: contact.lastSeenKnown,
        now: now,
      );
}

/// Shared identity layout for friend and user profile pages.
final class ProfileIdentityCard extends StatelessWidget {
  const ProfileIdentityCard(
      {super.key,
      required this.userId,
      required this.username,
      this.matrixUserId,
      this.nickname,
      this.remark,
      this.avatarUrl,
      this.identityCache,
      this.statusLabel,
      this.lastSeenAt,
      this.lastSeenKnown = false,
      this.now});
  final String userId;
  final String username;
  final String? matrixUserId;
  final String? nickname;
  final String? remark;
  final String? avatarUrl;
  final ProfileRepository? identityCache;
  final String? statusLabel;
  final DateTime? lastSeenAt;
  final bool lastSeenKnown;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final identity = identityCache?.resolveIdentity(
        userId: userId,
        matrixUserId: matrixUserId,
        username: username,
        nickname: nickname,
        avatarUrl: avatarUrl);
    final displayName = identity?.displayName ??
        identityDisplayName(
            userId: userId,
            matrixUserId: matrixUserId,
            username: username,
            nickname: nickname,
            remark: remark);
    return Container(
      constraints: const BoxConstraints(minHeight: 126),
      color: CupertinoTheme.of(context).brightness == Brightness.dark
          ? WeChatColors.darkElevated
          : WeChatColors.lightElevated,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Row(
        children: [
          UserAvatar(
            nickname: displayName,
            fallbackSeed: identity?.cacheKey ?? userId,
            avatarUrl: identity == null ? avatarUrl : identity.avatarUrl,
            size: 72,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: WeChatTypography.title1,
                    fontWeight: FontWeight.w700,
                    height: 30 / 22,
                  ),
                ),
                if (remark != null && remark!.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '昵称：${remark!.trim()}',
                    key: const Key('profile-remark-row'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: WeChatColors.textSecondary,
                      fontSize: WeChatTypography.subhead,
                      height: 20 / 14,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  '畅聊号：$username',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: WeChatColors.textSecondary,
                    fontSize: WeChatTypography.subhead,
                    height: 20 / 14,
                  ),
                ),
                if (statusLabel != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    statusLabel!,
                    style: const TextStyle(
                      color: WeChatColors.textSecondary,
                      fontSize: WeChatTypography.subhead,
                      height: 20 / 14,
                    ),
                  ),
                ] else if (lastSeenKnown) ...[
                  const SizedBox(height: 4),
                  _LastSeenStatusLine(lastSeenAt: lastSeenAt, now: now),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps only the relative-presence row fresh while this profile is visible.
/// The timer is paused outside the foreground and restarted on resume.
final class _LastSeenStatusLine extends StatefulWidget {
  const _LastSeenStatusLine({this.lastSeenAt, this.now});

  final DateTime? lastSeenAt;
  final DateTime Function()? now;

  @override
  State<_LastSeenStatusLine> createState() => _LastSeenStatusLineState();
}

final class _LastSeenStatusLineState extends State<_LastSeenStatusLine>
    with WidgetsBindingObserver {
  Timer? _timer;
  var _isForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _isForeground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (_isForeground) _scheduleNextTick();
  }

  @override
  void didUpdateWidget(covariant _LastSeenStatusLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isForeground &&
        (oldWidget.lastSeenAt != widget.lastSeenAt ||
            oldWidget.now != widget.now)) {
      _scheduleNextTick();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isForeground = true;
      _scheduleNextTick(rebuild: true);
    } else {
      _isForeground = false;
      _timer?.cancel();
      _timer = null;
    }
  }

  void _scheduleNextTick({bool rebuild = false}) {
    _timer?.cancel();
    if (rebuild && mounted) setState(() {});
    if (widget.lastSeenAt == null) return;
    final now = (widget.now ?? DateTime.now)();
    final untilNextMinute = Duration(minutes: 1) -
        Duration(seconds: now.second, milliseconds: now.millisecond);
    _timer = Timer(untilNextMinute, () {
      if (!mounted) return;
      setState(() {});
      _scheduleNextTick();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
        formatLastSeenLabel(widget.lastSeenAt,
            now: (widget.now ?? DateTime.now)()),
        key: const Key('friend-last-seen-status'),
        style: const TextStyle(
          color: WeChatColors.textSecondary,
          fontSize: WeChatTypography.subhead,
          height: 20 / 14,
        ),
      );
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
                style: TextStyle(
                  fontSize: WeChatTypography.callout,
                  color: WeChatColors.resolveTextPrimary(context),
                ),
              ),
            ],
          ),
        ),
      );
}
