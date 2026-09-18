import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';
import '../../core/support_identity_repository.dart';
import 'user_avatar.dart';
import 'wechat_gradient_divider.dart';
import 'wechat_official_name.dart';

/// 通讯录好友行：`surfaceElevated` 背景色 + 行底共享渐隐分割线。
///
/// 行高恒为 [WeChatDimensions.contactTileHeight]（字母索引跳转偏移量按它
/// 计算），分割线画在这一行内部，不额外增加行高。
final class WeChatContactTile extends StatelessWidget {
  const WeChatContactTile({
    super.key,
    required this.nickname,
    required this.fallbackSeed,
    this.avatarUrl,
    this.onTap,
    this.trailing,
    this.supportIdentities,
    this.userId,
    this.matrixUserId,
    this.showDivider = true,
  });
  final String nickname;
  final String fallbackSeed;
  final String? avatarUrl;
  final VoidCallback? onTap;
  final Widget? trailing;
  final SupportIdentityRepository? supportIdentities;
  final String? userId;
  final String? matrixUserId;

  /// 是否在行底画分割线；同一分组的最后一位好友传 false，
  /// 由分组标题承担分隔（避免线贴线）。
  final bool showDivider;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: WeChatDimensions.contactTileHeight,
        child: ColoredBox(
          key: const Key('wechat-contact-elevated-surface'),
          color: WeChatColors.elevatedSurface(context),
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
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
                      child: WeChatOfficialName(
                        name: nickname,
                        supportIdentities: supportIdentities,
                        userId: userId,
                        matrixUserId: matrixUserId,
                        nameStyle: TextStyle(
                            color: WeChatColors.resolveTextPrimary(context),
                            fontSize: WeChatTypography.callout),
                      ),
                    ),
                    if (trailing != null) trailing!,
                    const SizedBox(width: WeChatSpacing.lg),
                  ]),
                ),
              ),
              if (showDivider)
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: WeChatGradientDivider(
                    key: Key('wechat-contact-divider'),
                  ),
                ),
            ],
          ),
        ),
      );
}
