import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

abstract final class WeChatTheme {
  static CupertinoThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final primaryText = dark ? WeChatColors.darkTextPrimary : WeChatColors.lightTextPrimary;
    return CupertinoThemeData(
      brightness: brightness,
      primaryColor: WeChatColors.brandPrimary,
      scaffoldBackgroundColor: dark ? WeChatColors.darkPageBackground : WeChatColors.lightPageBackground,
      barBackgroundColor: dark ? WeChatColors.darkSurface : WeChatColors.lightSurface,
      textTheme: CupertinoTextThemeData(textStyle: TextStyle(fontSize: WeChatTypography.body, height: 24/17, color: primaryText)),
    );
  }
}
