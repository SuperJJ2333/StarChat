import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

abstract final class WeChatTheme {
  static CupertinoThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final primaryText =
        dark ? WeChatColors.darkTextPrimary : WeChatColors.lightTextPrimary;
    // Navigation surfaces follow the surfacePrimary token pair; the pages
    // pinned by UI_DESIGN.md 2.1 pass their fixed colors explicitly.
    final navigationSurface = dark
        ? WeChatColors.darkSurface
        : WeChatColors.chatNavigationBackground;
    return CupertinoThemeData(
      brightness: brightness,
      primaryColor: WeChatColors.brandPrimary,
      scaffoldBackgroundColor: dark
          ? WeChatColors.darkPageBackground
          : WeChatColors.lightPageBackground,
      barBackgroundColor: navigationSurface,
      textTheme: CupertinoTextThemeData(
          textStyle: TextStyle(
              fontSize: WeChatTypography.body,
              height: 24 / 17,
              color: primaryText),
          navTitleTextStyle: TextStyle(
              fontSize: WeChatTypography.body,
              fontWeight: FontWeight.w600,
              color: primaryText),
          // Cupertino's default navActionTextStyle is inherit:false while a
          // literal navTitleTextStyle is inherit:true; the nav-bar hero
          // flight lerps one into the other and throws
          // "Failed to interpolate TextStyles with different inherit
          // values" whenever a page is pushed or popped. Keep both styles
          // inherit:true so the transition can interpolate them.
          navActionTextStyle: TextStyle(
              fontSize: WeChatTypography.body,
              color: WeChatColors.socialLink)),
    );
  }
}
