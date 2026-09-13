import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';
import '../../core/support_identity_repository.dart';
import 'wechat_official_name.dart';

/// Navigation titles use the same active brightness as their surfaces.
final class WeChatNavTitle extends StatelessWidget {
  const WeChatNavTitle(this.text,
      {super.key, this.supportIdentities, this.userId, this.matrixUserId});

  final String text;
  final SupportIdentityRepository? supportIdentities;
  final String? userId;
  final String? matrixUserId;

  @override
  Widget build(BuildContext context) => WeChatOfficialName(
        name: text,
        supportIdentities: supportIdentities,
        userId: userId,
        matrixUserId: matrixUserId,
        nameStyle: TextStyle(color: WeChatColors.resolveTextPrimary(context)),
      );
}
