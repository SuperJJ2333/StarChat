import 'package:flutter/cupertino.dart';

final class ImmersiveAuthScaffold extends StatelessWidget {
  const ImmersiveAuthScaffold({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        child: Stack(fit: StackFit.expand, children: [
          const Positioned.fill(
              child: Image(
                  image: AssetImage('assets/landing.png'),
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter)),
          Positioned.fill(child: SafeArea(child: child)),
        ]),
      );
}
