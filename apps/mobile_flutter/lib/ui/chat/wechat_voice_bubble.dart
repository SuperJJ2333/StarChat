import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

enum VoicePlaybackState { idle, playing, failed }

final class WeChatVoiceBubble extends StatelessWidget {
  const WeChatVoiceBubble(
      {super.key,
      required this.duration,
      this.state = VoicePlaybackState.idle,
      this.onTap});
  final Duration duration;
  final VoicePlaybackState state;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final seconds = duration.inSeconds.clamp(1, 60);
    final width = 80 + (140 * (seconds / 60));
    return CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onTap,
        child: Container(
            width: width,
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.md),
            decoration: BoxDecoration(
                color: WeChatColors.bubbleOutgoing,
                borderRadius: BorderRadius.circular(WeChatRadius.bubble)),
            child: Row(children: [
              Icon(state == VoicePlaybackState.playing
                  ? CupertinoIcons.waveform
                  : CupertinoIcons.speaker_2_fill),
              const Spacer(),
              Text('$seconds″')
            ])));
  }
}
