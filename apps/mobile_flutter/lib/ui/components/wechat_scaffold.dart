import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';
import 'network_status_capsule.dart';

final class WeChatPageScaffold extends StatelessWidget {
  const WeChatPageScaffold({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    // Null uses the theme; explicit product surfaces are resolved at build.
    this.backgroundColor,
  }) : navigationBar = null;

  const WeChatPageScaffold.bare({
    super.key,
    required this.child,
    this.backgroundColor = WeChatColors.lightPageBackground,
  })  : title = null,
        trailing = null,
        navigationBar = null;

  const WeChatPageScaffold.navigation({
    super.key,
    required this.navigationBar,
    required this.child,
    this.backgroundColor,
  })  : title = null,
        trailing = null;

  final String? title;
  final Widget child;
  final Widget? trailing;
  final ObstructingPreferredSizeWidget? navigationBar;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        backgroundColor: backgroundColor == null
            ? null
            : switch (backgroundColor) {
                WeChatColors.lightPageBackground ||
                WeChatColors.lightSurface ||
                WeChatColors.lightElevated =>
                  WeChatColors.resolve(context, backgroundColor!),
                _ => CupertinoDynamicColor.resolve(backgroundColor!, context),
              },
        navigationBar: navigationBar ??
            (title == null
                ? null
                : CupertinoNavigationBar(
                    backgroundColor: WeChatColors.navigationBackground(context),
                    automaticBackgroundVisibility: false,
                    enableBackgroundFilterBlur: false,
                    middle: Text(title!),
                    trailing: trailing,
                  )),
        child: SafeArea(
            child: Column(children: [
          // 顶部状态胶囊仅在真正离线/服务不可用时出现；
          // “正在连接”由首页行内提示承担，避免导航栏下方常驻加载感。
          WeChatNetworkStatusCapsule(showConnecting: false),
          Expanded(child: child),
        ])),
      );
}
