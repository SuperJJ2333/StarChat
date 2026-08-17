import 'package:flutter/cupertino.dart';

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
                      color: const Color(0xd9ffffff),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: const Color(0x22000000))),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(
                            reconnecting
                                ? CupertinoIcons.arrow_2_circlepath
                                : CupertinoIcons.wifi_slash,
                            size: 16),
                        const SizedBox(width: 6),
                        Text(reconnecting ? '正在重新连接' : '网络不可用，点击重试')
                      ]))))));
}
