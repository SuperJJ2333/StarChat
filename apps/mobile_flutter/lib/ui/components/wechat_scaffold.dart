import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

final class WeChatPageScaffold extends StatelessWidget {
  const WeChatPageScaffold(
      {super.key, required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: Text(title),
        trailing: trailing,
      ),
      child: SafeArea(child: child));
}
