import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

final class NetworkStatusCapsule extends StatelessWidget {
  const NetworkStatusCapsule(
      {super.key, required this.onRetry, this.reconnecting = false});
  final VoidCallback onRetry;
  final bool reconnecting;
  @override
  Widget build(BuildContext context) => Center(
          child: GestureDetector(
        onTap: onRetry,
        child: Semantics(
            button: true,
            label: reconnecting ? '正在重新连接' : '网络不可用，点击重试',
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: WeChatColors.networkCapsuleSurface,
                borderRadius:
                    BorderRadius.circular(WeChatRadius.networkCapsule),
                border: Border.all(color: WeChatColors.networkCapsuleBorder),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: WeChatSpacing.networkCapsuleHorizontal,
                    vertical: WeChatSpacing.networkCapsuleVertical),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      reconnecting
                          ? CupertinoIcons.arrow_2_circlepath
                          : CupertinoIcons.wifi_slash,
                      size: WeChatTypography.callout),
                  const SizedBox(width: WeChatSpacing.networkCapsuleIconGap),
                  Text(reconnecting ? '正在重新连接' : '网络不可用，点击重试'),
                ]),
              ),
            )),
      ));
}
