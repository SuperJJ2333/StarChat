import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

/// Plain, centered system notice for a WeChat-style "拍一拍" event.
final class WeChatNudgeNotice extends StatelessWidget {
  const WeChatNudgeNotice({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Align(
        key: const Key('nudge-notice-align'),
        alignment: Alignment.center,
        child: Padding(
          key: const Key('nudge-notice'),
          padding: const EdgeInsets.symmetric(vertical: WeChatSpacing.sm),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: WeChatColors.textSecondary,
              fontSize: WeChatTypography.caption,
            ),
          ),
        ),
      );
}
