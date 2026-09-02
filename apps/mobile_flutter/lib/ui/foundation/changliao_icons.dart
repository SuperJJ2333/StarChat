import 'package:flutter/cupertino.dart';

/// Semantic icon names shared by the Figma library and Flutter UI.
///
/// Call sites depend on the semantic name rather than a concrete glyph, so the
/// icon can be refined without changing feature code or its DOM-equivalent
/// widget hierarchy.
abstract final class ChangliaoIcons {
  static const IconData messages = CupertinoIcons.chat_bubble_2;
  static const IconData messagesFilled = CupertinoIcons.chat_bubble_2_fill;
  static const IconData contacts = CupertinoIcons.person_2;
  static const IconData contactsFilled = CupertinoIcons.person_2_fill;
  static const IconData discover = CupertinoIcons.compass;
  static const IconData discoverFilled = CupertinoIcons.compass_fill;
  static const IconData me = CupertinoIcons.person_crop_circle;
  static const IconData meFilled = CupertinoIcons.person_crop_circle_fill;
  static const IconData voiceCall = CupertinoIcons.phone;
  static const IconData voiceCallFilled = CupertinoIcons.phone_fill;
  static const IconData videoCall = CupertinoIcons.video_camera;
  static const IconData microphone = CupertinoIcons.mic;
  static const IconData microphoneOff = CupertinoIcons.mic_slash;
  static const IconData camera = CupertinoIcons.camera;
  static const IconData search = CupertinoIcons.search;
  static const IconData settings = CupertinoIcons.settings;
  static const IconData wallet = CupertinoIcons.creditcard;
  static const IconData gift = CupertinoIcons.gift;
  static const IconData transfer = CupertinoIcons.money_dollar_circle;
  static const IconData transferFilled = CupertinoIcons.money_dollar_circle_fill;
  static const IconData add = CupertinoIcons.add;
  static const IconData confirm = CupertinoIcons.check_mark;
  static const IconData retry = CupertinoIcons.refresh;
  static const IconData back = CupertinoIcons.back;
  static const IconData more = CupertinoIcons.ellipsis;
  static const IconData attachment = CupertinoIcons.paperclip;
  static const IconData emoji = CupertinoIcons.smiley;
  static const IconData muted = CupertinoIcons.bell_slash;
  static const IconData speaker = CupertinoIcons.speaker_2;
  static const IconData speakerFilled = CupertinoIcons.speaker_3_fill;
  static const IconData hangup = CupertinoIcons.phone_down_fill;
  static const IconData switchCamera = CupertinoIcons.camera_rotate;
  static const IconData close = CupertinoIcons.clear;
}
