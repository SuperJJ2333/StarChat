import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';
import 'user_avatar.dart';

final class WeChatContactTile extends StatelessWidget {
  const WeChatContactTile({
    super.key,
    required this.nickname,
    required this.fallbackSeed,
    this.avatarUrl,
    this.onTap,
    this.trailing,
  });
  final String nickname;
  final String fallbackSeed;
  final String? avatarUrl;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: WeChatDimensions.contactTileHeight,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: onTap,
          child: Row(children: [
            const SizedBox(width: WeChatSpacing.lg),
            UserAvatar(
              nickname: nickname,
              fallbackSeed: fallbackSeed,
              avatarUrl: avatarUrl,
              size: WeChatDimensions.contactAvatar,
            ),
            const SizedBox(width: WeChatSpacing.md),
            Expanded(
              child: Text(nickname,
                  style: const TextStyle(
                      color: WeChatColors.lightTextPrimary,
                      fontSize: WeChatTypography.callout)),
            ),
            if (trailing != null) trailing!,
            const SizedBox(width: WeChatSpacing.lg),
          ]),
        ),
      );
}
