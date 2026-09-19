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
  })  : navigationBar = null,
        showNetworkCapsule = true;

  const WeChatPageScaffold.bare({
    super.key,
    required this.child,
    this.backgroundColor = WeChatColors.lightPageBackground,
  })  : title = null,
        trailing = null,
        navigationBar = null,
        showNetworkCapsule = true;

  const WeChatPageScaffold.navigation({
    super.key,
    required this.navigationBar,
    required this.child,
    this.backgroundColor,
    // BUG-41（真机回归修订）：朋友圈等离线优先页面设为 false——
    // 内容来自本地缓存也能完整使用，网络状态由页内提示承担，
    // 不再出现常驻的「正在加载/网络不可用」状态栏。
    this.showNetworkCapsule = true,
  })  : title = null,
        trailing = null;

  final String? title;
  final Widget child;
  final Widget? trailing;
  final ObstructingPreferredSizeWidget? navigationBar;
  final Color? backgroundColor;

  /// 是否渲染顶部网络状态胶囊。
  final bool showNetworkCapsule;

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
          if (showNetworkCapsule) WeChatNetworkStatusCapsule(showConnecting: false),
          Expanded(child: child),
        ])),
      );
}
