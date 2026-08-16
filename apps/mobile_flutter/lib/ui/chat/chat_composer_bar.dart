import 'package:flutter/cupertino.dart';

import '../foundation/changliao_icons.dart';
import '../foundation/wechat_tokens.dart';

final class ChatComposerBar extends StatelessWidget {
  const ChatComposerBar({
    super.key,
    required this.controller,
    required this.onAttachment,
    required this.onVoice,
    required this.onSend,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final VoidCallback onAttachment;
  final VoidCallback onVoice;
  final VoidCallback onSend;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(
          minHeight: WeChatDimensions.composerMinHeight,
        ),
        color: CupertinoTheme.of(context).barBackgroundColor,
        padding: const EdgeInsets.symmetric(
          horizontal: WeChatSpacing.sm,
          vertical: WeChatSpacing.xs,
        ),
        child: Row(
          children: [
            _ComposerIconButton(
              key: const Key('chat-composer-attachment'),
              icon: ChangliaoIcons.attachment,
              label: '添加附件',
              onPressed: onAttachment,
            ),
            _ComposerIconButton(
              key: const Key('chat-composer-voice'),
              icon: ChangliaoIcons.microphone,
              label: '语音消息',
              onPressed: onVoice,
            ),
            Expanded(
              child: CupertinoTextField(
                key: const Key('chat-composer-input'),
                controller: controller,
                placeholder: '输入加密消息',
                onSubmitted: onSubmitted,
                padding: const EdgeInsets.symmetric(
                  horizontal: WeChatSpacing.md,
                  vertical: WeChatSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: CupertinoTheme.of(context).scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(WeChatRadius.control),
                ),
              ),
            ),
            CupertinoButton(
              key: const Key('chat-composer-send'),
              minimumSize: const Size.square(
                WeChatDimensions.minimumTouchTarget,
              ),
              padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.sm),
              onPressed: onSend,
              child: const Text('发送'),
            ),
          ],
        ),
      );
}

final class _ComposerIconButton extends StatelessWidget {
  const _ComposerIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: CupertinoButton(
          minimumSize: const Size.square(
            WeChatDimensions.minimumTouchTarget,
          ),
          padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.sm),
          onPressed: onPressed,
          child: Icon(icon, size: 24),
        ),
      );
}
