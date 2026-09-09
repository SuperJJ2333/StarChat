import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

abstract final class MomentReactionTokens {
  static const background = CupertinoDynamicColor.withBrightness(
      color: WeChatColors.chatNavigationBackground,
      darkColor: WeChatColors.darkSurface);
  static const selected = CupertinoDynamicColor.withBrightness(
      color: WeChatColors.lightPageBackground,
      darkColor: WeChatColors.darkPageBackground);
  static const text = CupertinoDynamicColor.withBrightness(
      color: WeChatColors.lightTextPrimary,
      darkColor: WeChatColors.darkTextPrimary);
  static const name = CupertinoDynamicColor.withBrightness(
      color: WeChatColors.socialLink, darkColor: Color(0xff9aaece));
  static const muted = CupertinoDynamicColor.withBrightness(
      color: Color(0xff666666), darkColor: Color(0xff999999));
  static const divider = CupertinoDynamicColor.withBrightness(
      color: WeChatColors.divider, darkColor: WeChatColors.darkDivider);
  static const shadow = Color(0x12000000);
  static const radius = 8.0;
  static const avatarSize = 30.0;
  static const feedPadding = 10.0;
  static const detailPadding = 14.0;
  static const likeDuration = Duration(milliseconds: 700);
}
