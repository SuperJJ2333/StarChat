import 'package:flutter/cupertino.dart';

abstract final class WeChatColors {
  static const brandPrimary = Color(0xFF07C160);
  static const brandPressed = Color(0xFF06AD56);
  static const lightPageBackground = Color(0xFFEDEDED);
  static const darkPageBackground = Color(0xFF111111);
  static const lightSurface = Color(0xFFF7F7F7);
  static const darkSurface = Color(0xFF191919);
  static const lightElevated = Color(0xFFFFFFFF);
  static const darkElevated = Color(0xFF232323);
  static const lightTextPrimary = Color(0xFF191919);
  static const darkTextPrimary = Color(0xFFF5F5F5);
  static const textSecondary = Color(0xFF888888);
  static const divider = Color(0xFFD9D9D9);
  static const danger = Color(0xFFFA5151);
  static const warning = Color(0xFFFA9D3B);
  static const bubbleOutgoing = Color(0xFF95EC69);
  static const socialLink = Color(0xFF576B95);
}

abstract final class WeChatSpacing { static const xs=4.0, sm=8.0, md=12.0, lg=16.0, xl=24.0, xxl=32.0; }
abstract final class WeChatRadius { static const tag=4.0, control=6.0, bubble=8.0, redPacket=10.0, dialog=12.0; }
abstract final class WeChatTypography { static const display=28.0, title1=22.0, title2=18.0, body=17.0, callout=16.0, subhead=14.0, caption=12.0, badge=11.0; }
