import 'package:flutter/cupertino.dart';

import '../foundation/changliao_icons.dart';
import '../foundation/wechat_tokens.dart';
import 'chat_composer_state.dart';

/// Public component contract for encrypted text, attachment and voice input.
class WeChatComposer extends StatefulWidget {
  const WeChatComposer({
    super.key,
    required this.controller,
    required this.onMore,
    required this.onVoice,
    required this.onEmoji,
    required this.onSend,
    this.focusNode,
    this.panel = ComposerPanel.none,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ComposerPanel panel;
  final VoidCallback onMore;
  final VoidCallback onVoice;
  final VoidCallback onEmoji;
  final VoidCallback onSend;
  final ValueChanged<String>? onSubmitted;

  @override
  State<WeChatComposer> createState() => _WeChatComposerState();
}

final class _WeChatComposerState extends State<WeChatComposer> {
  late final FocusNode _ownedFocusNode;
  FocusNode get _focusNode => widget.focusNode ?? _ownedFocusNode;

  @override
  void initState() {
    super.initState();
    _ownedFocusNode = FocusNode();
    widget.controller.addListener(_refresh);
    _focusNode.addListener(_refresh);
  }

  @override
  void didUpdateWidget(WeChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownedFocusNode).removeListener(_refresh);
      _focusNode.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _focusNode.removeListener(_refresh);
    _ownedFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ChatComposerState(
      focused: _focusNode.hasFocus,
      hasText: widget.controller.text.trim().isNotEmpty,
      panel: widget.panel,
    );
    return Container(
      key: const Key('chat-composer'),
      constraints:
          const BoxConstraints(minHeight: WeChatDimensions.composerMinHeight),
      color: CupertinoTheme.of(context).barBackgroundColor,
      padding: const EdgeInsets.symmetric(
          horizontal: WeChatSpacing.sm, vertical: WeChatSpacing.xs),
      child: Row(children: [
        _ComposerIconButton(
            key: const Key('composer-voice'),
            icon: ChangliaoIcons.microphone,
            label: '语音消息',
            onPressed: widget.onVoice),
        Expanded(
            child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: CupertinoTextField(
            key: const Key('composer-input'),
            controller: widget.controller,
            focusNode: _focusNode,
            placeholder: '输入加密消息',
            minLines: 1,
            maxLines: 4,
            onSubmitted: widget.onSubmitted,
            padding: const EdgeInsets.symmetric(
                horizontal: WeChatSpacing.md, vertical: 10),
            decoration: BoxDecoration(
                color: CupertinoTheme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(WeChatRadius.control)),
          ),
        )),
        _ComposerIconButton(
            key: const Key('composer-emoji'),
            icon: ChangliaoIcons.emoji,
            label: '表情',
            onPressed: widget.onEmoji),
        if (state.showsSend)
          _ComposerIconButton(
              key: const Key('composer-send'),
              icon: CupertinoIcons.paperplane_fill,
              label: '发送',
              surfaceKey: const Key('composer-send-surface'),
              backgroundColor: WeChatColors.brandPressed,
              iconColor: CupertinoColors.white,
              onPressed: widget.onSend)
        else
          _ComposerIconButton(
              key: const Key('composer-more'),
              icon: CupertinoIcons.add_circled,
              label: '更多',
              onPressed: widget.onMore),
      ]),
    );
  }
}

final class _ComposerIconButton extends StatelessWidget {
  const _ComposerIconButton(
      {super.key,
      required this.icon,
      required this.label,
      required this.onPressed,
      this.surfaceKey,
      this.backgroundColor,
      this.iconColor});
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Key? surfaceKey;
  final Color? backgroundColor;
  final Color? iconColor;
  @override
  Widget build(BuildContext context) => DecoratedBox(
        key: surfaceKey,
        decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(WeChatRadius.control)),
        child: SizedBox.square(
          dimension: WeChatDimensions.minimumTouchTarget,
          child: Semantics(
              button: true,
              label: label,
              child: CupertinoButton(
                minimumSize:
                    const Size.square(WeChatDimensions.minimumTouchTarget),
                padding: EdgeInsets.zero,
                onPressed: onPressed,
                child: Icon(icon, size: 24, color: iconColor),
              )),
        ),
      );
}
