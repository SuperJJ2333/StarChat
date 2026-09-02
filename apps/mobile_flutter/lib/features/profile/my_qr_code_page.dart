import 'package:flutter/cupertino.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_nav_title.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/friend_qr.dart';
import 'profile_controller.dart';

/// 「我的二维码」页（微信式）：头像 + 昵称 + 二维码 + 扫码提示。
/// 二维码载荷为 `changliao://u/<畅聊号>`，好友「扫一扫」识别后
/// 进入「申请添加朋友」页（不会直接发送请求）。
final class MyQrCodePage extends StatelessWidget {
  const MyQrCodePage({super.key, required this.profile});

  final ProfileData profile;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final foreground =
        dark ? WeChatColors.darkTextPrimary : WeChatColors.lightTextPrimary;
    final payload = buildFriendQrPayload(profile.username);
    return WeChatPageScaffold.navigation(
      backgroundColor:
          dark ? WeChatColors.darkPageBackground : WeChatColors.lightPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const WeChatNavTitle('我的二维码'),
      ),
      child: SafeArea(
        child: ListView(
          key: const Key('my-qr-page'),
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              decoration: BoxDecoration(
                color:
                    dark ? WeChatColors.darkElevated : WeChatColors.lightElevated,
                borderRadius: BorderRadius.circular(WeChatRadius.dialog),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      UserAvatar(
                        key: const Key('my-qr-avatar'),
                        nickname: profile.nickname,
                        fallbackSeed: profile.fallbackSeed,
                        avatarUrl: profile.avatarUrl,
                        size: 28,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          profile.nickname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600, color: foreground),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Container(
                    key: const Key('my-qr-image'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: CupertinoColors.white,
                      borderRadius: BorderRadius.circular(WeChatRadius.control),
                    ),
                    child: QrImageView(
                      data: payload,
                      version: QrVersions.auto,
                      size: 220,
                      backgroundColor: CupertinoColors.white,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '扫一扫上面的二维码图案，加我为朋友',
                    key: const Key('my-qr-hint'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, color: WeChatColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '畅聊号：${profile.username}',
                    style: TextStyle(
                        fontSize: 12, color: WeChatColors.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
