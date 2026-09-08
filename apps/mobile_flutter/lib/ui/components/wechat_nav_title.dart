import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

/// Navigation titles use the same active brightness as their surfaces.
final class WeChatNavTitle extends StatelessWidget {
  const WeChatNavTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: WeChatColors.resolveTextPrimary(context)),
      );
}
