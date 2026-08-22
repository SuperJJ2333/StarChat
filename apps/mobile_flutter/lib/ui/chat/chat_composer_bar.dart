import 'package:flutter/cupertino.dart';

import 'wechat_composer.dart';

/// Backwards-compatible name retained while pages migrate to WeChatComposer.
final class ChatComposerBar extends WeChatComposer {
  const ChatComposerBar({
    super.key,
    required super.controller,
    required super.onMore,
    required super.onVoice,
    required super.onEmoji,
    required super.onSend,
    super.focusNode,
    super.panel,
    super.onSubmitted,
  });

  /// Stable design-contract keys implemented by [WeChatComposer].
  static const componentKeys = <Key>[
    Key('composer-voice'),
    Key('composer-input'),
    Key('composer-emoji'),
    Key('composer-more'),
    Key('composer-send'),
  ];
}
