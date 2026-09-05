import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

/// Navigation title for the pages whose colors are pinned by UI_DESIGN.md
/// 2.1 (chat pages and the four main tab roots). The bar stays light in both
/// brightnesses, so the title text must stay dark as well.
final class WeChatNavTitle extends StatelessWidget {
  const WeChatNavTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: WeChatColors.lightTextPrimary),
      );
}
