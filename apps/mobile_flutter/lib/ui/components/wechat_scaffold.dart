import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

final class WeChatPageScaffold extends StatelessWidget {
  const WeChatPageScaffold({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    // Null falls back to the theme scaffold background so pages follow the
    // active brightness; pages pinned by UI_DESIGN.md 2.1 pass fixed tokens.
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
        backgroundColor: backgroundColor,
        navigationBar: navigationBar ??
            (title == null
                ? null
                : CupertinoNavigationBar(
                    backgroundColor: WeChatColors.chatNavigationBackground,
                    automaticBackgroundVisibility: false,
                    enableBackgroundFilterBlur: false,
                    middle: Text(title!),
                    trailing: trailing,
                  )),
        child: SafeArea(child: child),
      );
}
