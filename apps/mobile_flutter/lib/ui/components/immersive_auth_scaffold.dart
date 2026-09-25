import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

final class ImmersiveAuthScaffold extends StatelessWidget {
  const ImmersiveAuthScaffold({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: CupertinoPageScaffold(
        child: Stack(fit: StackFit.expand, children: [
          const Positioned.fill(
              child: Image(
                  image: AssetImage('assets/landing.png'),
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter)),
          if (dark)
            Positioned.fill(
              child: ColoredBox(
                key: const Key('auth-background-scrim'),
                color: WeChatColors.darkPageBackground.withValues(alpha: .80),
              ),
            ),
          Positioned.fill(child: SafeArea(child: child)),
        ]),
      ),
    );
  }
}
