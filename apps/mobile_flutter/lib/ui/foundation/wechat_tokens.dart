import 'package:flutter/cupertino.dart';

abstract final class WeChatColors {
  static const brandPrimary = Color(0xFF07C160);
  static const brandPressed = Color(0xFF06AD56);
  static const lightPageBackground = Color(0xFFEDEDED);
  // Fixed product-spec colors. Do not substitute theme-dependent surfaces.
  static const chatNavigationBackground = Color(0xFFF7F7F7);
  static const chatPageBackground = Color(0xFFEDEDED);
  static const tabRootPageBackground = Color(0xFFEDEDED);
  static const darkPageBackground = Color(0xFF111111);
  static const lightSurface = Color(0xFFF7F7F7);
  static const darkSurface = Color(0xFF191919);
  static const lightElevated = Color(0xFFFFFFFF);
  static const darkElevated = Color(0xFF232323);
  static const lightTextPrimary = Color(0xFF191919);
  static const darkTextPrimary = Color(0xFFF5F5F5);
  static const textSecondary = Color(0xFF888888);
  static const textTertiary = Color(0xFFB2B2B2);
  static const divider = Color(0xFFD9D9D9);
  static const darkDivider = Color(0xFF2C2C2C);
  static const controlBorder = divider;
  static const danger = CupertinoColors.systemRed;
  static const errorSurface = Color(0xFFFFF1F0);
  static const errorBorder = Color(0xFFFFCCC7);
  static const warning = Color(0xFFFA9D3B);
  static const bubbleOutgoing = Color(0xFF95EC69);
  static const socialLink = Color(0xFF576B95);
  static const networkCapsuleSurface = Color(0xD9FFFFFF);
  static const networkCapsuleBorder = Color(0x22000000);
  static const avatarFallbackBlue = Color(0xFFD8E8FF);
  static const avatarFallbackGreen = Color(0xFFDFF2E4);
  static const avatarFallbackOrange = Color(0xFFFFE5D5);
  static const avatarFallbackPurple = Color(0xFFEEE1FF);

  static Color elevatedSurface(BuildContext context) =>
      CupertinoTheme.brightnessOf(context) == Brightness.dark
          ? darkElevated
          : lightElevated;

  static Color navigationSurface(BuildContext context) =>
      CupertinoTheme.brightnessOf(context) == Brightness.dark
          ? darkSurface
          : lightPageBackground;
}

abstract final class WeChatSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const actionButtonHorizontal = lg;
  static const actionButtonVertical = md;
  static const actionButtonIconGap = sm;
  static const networkCapsuleHorizontal = 14.0;
  static const networkCapsuleVertical = sm;
  static const networkCapsuleIconGap = 6.0;
}

abstract final class WeChatRadius {
  static const tag = 4.0;
  static const control = 6.0;
  static const bubble = 8.0;
  static const redPacket = 10.0;
  static const dialog = 12.0;
  static const authCard = 12.0;
  static const authControl = 14.0;
  static const actionButton = authControl;
  static const networkCapsule = 22.0;
}

abstract final class WeChatDimensions {
  static const screenWidth = 393.0;
  static const screenHeight = 852.0;
  static const controlHeight = 48.0;
  static const minimumTouchTarget = 44.0;
  static const authCardMaxWidth = 345.0;
  static const authBrandMark = 64.0;
  static const conversationTileHeight = 72.0;
  static const contactTileHeight = 56.0;
  static const contactAvatar = 40.0;
  static const contactDividerIndent = 68.0;
  static const contactIndexFeedback = 64.0;
  static const conversationAvatar = 48.0;
  static const messageAvatar = 40.0;
  static const composerMinHeight = 56.0;
  static const callControl = 72.0;
}

abstract final class WeChatTypography {
  static const brand = 34.0;
  static const display = 28.0;
  static const title1 = 22.0;
  static const title2 = 18.0;
  static const body = 17.0;
  static const callout = 16.0;
  static const subhead = 14.0;
  static const caption = 12.0;
  static const badge = 11.0;
}

abstract final class WeChatEffects {
  static const authCardShadow = <BoxShadow>[
    BoxShadow(color: Color(0x1F000000), blurRadius: 16, offset: Offset(0, 4)),
  ];
  static const actionButtonShadow = <BoxShadow>[
    BoxShadow(color: Color(0x1F000000), blurRadius: 8, offset: Offset(0, 2)),
  ];
}

abstract final class WeChatMotion {
  static const actionPressDuration = Duration(milliseconds: 150);
}
