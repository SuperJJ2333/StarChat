enum ComposerPanel { none, voice, emoji, more }

final class ChatComposerState {
  const ChatComposerState({
    required this.focused,
    required this.hasText,
    required this.panel,
  });

  final bool focused;
  final bool hasText;
  final ComposerPanel panel;

  bool get showsSend => focused && hasText;
}
