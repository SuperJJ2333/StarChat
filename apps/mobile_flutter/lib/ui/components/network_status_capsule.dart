import 'dart:async';
import 'package:flutter/cupertino.dart';

import '../../core/app_connection_status.dart';
import '../foundation/wechat_tokens.dart';

final class NetworkStatusCapsule extends StatelessWidget {
  const NetworkStatusCapsule(
      {super.key,
      required this.onRetry,
      this.reconnecting = false,
      this.disabled = false,
      this.label});
  final VoidCallback onRetry;
  final bool reconnecting, disabled;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final text = label ?? (reconnecting ? '正在重新连接' : '网络不可用，点击重试');
    return Center(
        child: GestureDetector(
            onTap: disabled ? null : onRetry,
            child: Semantics(
                button: !disabled,
                label: text,
                child: DecoratedBox(
                    decoration: BoxDecoration(
                        color: WeChatColors.resolve(
                            context, WeChatColors.networkCapsuleSurface),
                        borderRadius:
                            BorderRadius.circular(WeChatRadius.networkCapsule),
                        border: Border.all(
                            color: WeChatColors.resolve(
                                context, WeChatColors.networkCapsuleBorder))),
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
                          const SizedBox(
                              width: WeChatSpacing.networkCapsuleIconGap),
                          Flexible(
                              child: Text(text, maxLines: 2, softWrap: true))
                        ]))))));
  }
}

final class WeChatNetworkStatusCapsule extends StatelessWidget {
  WeChatNetworkStatusCapsule({super.key, AppConnectionStatusHub? hub})
      : hub = hub ?? AppConnectionStatusHub.shared;
  final AppConnectionStatusHub hub;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<AppConnectionStatus>(
          valueListenable: hub.status,
          builder: (context, status, _) {
            final label = switch (status) {
              AppConnectionStatus.offline => '网络不可用，联网后自动重试',
              AppConnectionStatus.connecting => '正在连接…',
              AppConnectionStatus.serviceUnavailable => '服务暂时不可用',
              _ => null,
            };
            if (label == null) return const SizedBox.shrink();
            return Semantics(
                liveRegion: true,
                label: label,
                child: NetworkStatusCapsule(
                    key: const Key('network-status-capsule'),
                    label: label,
                    reconnecting: status == AppConnectionStatus.connecting,
                    disabled: status == AppConnectionStatus.connecting,
                    onRetry: () => unawaited(hub.retry().catchError((_) {}))));
          });
}
