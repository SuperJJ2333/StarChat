import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

final class WeChatTimestamp extends StatelessWidget {
  const WeChatTimestamp({super.key, required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: WeChatSpacing.sm),
      child: Text(label,
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: WeChatTypography.caption,
              color: WeChatColors.textSecondary)));
}
