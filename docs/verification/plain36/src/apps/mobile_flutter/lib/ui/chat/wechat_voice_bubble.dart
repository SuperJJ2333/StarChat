import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import '../../features/matrix/voice_playback_controller.dart';
import '../foundation/wechat_tokens.dart';

enum VoicePlaybackState { idle, playing, paused, failed }

/// 语音气泡（QQ 语音样式）：
/// - 文字/图标为黑色（#000000），与普通文字消息气泡一致；
/// - 音纹波形贯穿气泡主体，空闲态整体半透明黑；
/// - 播放中一道高亮进度**从左到右逐渐扫过音纹区域**：已扫过条实心黑、
///   未扫过条半透明黑，进度与音频真实播放位置保持一致；
/// - 暂停时高亮**定格**在当前位置；自然结束/停止后复位为默认颜色；
/// - 扫过总时长等于语音时长。
///
/// 进度来源二选一：
/// - 传入 [playback]（播放控制器）：按真实播放位置计算（产品路径）；
/// - 未传：内置估算扫过（播放点击起算，测试/独立展示用）。
final class WeChatVoiceBubble extends StatefulWidget {
  const WeChatVoiceBubble(
      {super.key,
      required this.duration,
      this.state = VoicePlaybackState.idle,
      this.onTap,
      this.playback,
      this.messageId});
  final Duration duration;
  final VoicePlaybackState state;
  final VoidCallback? onTap;

  /// 播放控制器：提供真实播放位置驱动扫过进度与暂停定格。
  final VoicePlaybackController? playback;
  final String? messageId;

  @override
  State<WeChatVoiceBubble> createState() => _WeChatVoiceBubbleState();
}

final class _WeChatVoiceBubbleState extends State<WeChatVoiceBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep =
      AnimationController(vsync: this, value: 0);

  bool get _usesRealProgress =>
      widget.playback != null && widget.messageId != null;

  @override
  void initState() {
    super.initState();
    // 无真实进度源时的估算扫过：从点击瞬间起按语音时长推进。
    if (!_usesRealProgress && widget.state == VoicePlaybackState.playing) {
      final total = widget.duration <= Duration.zero
          ? const Duration(seconds: 1)
          : widget.duration;
      _sweep.duration = total;
      _sweep.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(covariant WeChatVoiceBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_usesRealProgress) return;
    final playing = widget.state == VoicePlaybackState.playing;
    final wasPlaying = oldWidget.state == VoicePlaybackState.playing;
    if (playing && !wasPlaying) {
      final total = widget.duration <= Duration.zero
          ? const Duration(seconds: 1)
          : widget.duration;
      _sweep.duration = total;
      _sweep.forward(from: 0);
    } else if (!playing && wasPlaying) {
      _sweep.stop();
      _sweep.value = 0;
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = widget.duration.inSeconds.clamp(1, 60);
    final width = 96 + (120 * (seconds / 60));
    return CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: widget.onTap,
        child: Container(
            width: width,
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.md),
            decoration: BoxDecoration(
                color: WeChatColors.bubbleOutgoing,
                borderRadius: BorderRadius.circular(WeChatRadius.bubble)),
            child: Row(children: [
              const Icon(CupertinoIcons.speaker_2_fill,
                  size: 12, color: CupertinoColors.black),
              const SizedBox(width: 6),
              Expanded(
                child: _usesRealProgress
                    ? AnimatedBuilder(
                        animation: widget.playback!,
                        builder: (_, __) => CustomPaint(
                          painter: _VoiceWavePainter(progress: _realProgress),
                        ),
                      )
                    : AnimatedBuilder(
                        animation: _sweep,
                        builder: (_, __) => CustomPaint(
                          painter: _VoiceWavePainter(progress: _sweep.value),
                        ),
                      ),
              ),
              const SizedBox(width: 6),
              Text('$seconds″',
                  style: const TextStyle(color: CupertinoColors.black))
            ])));
  }

  double get _realProgress {
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return 0;
    final position = widget.playback?.positionOf(widget.messageId!);
    return ((position?.inMilliseconds ?? 0) / total).clamp(0.0, 1.0);
  }
}

/// 音纹波形：按可用宽度自适应条数（每条约 8px 节距），高度按正弦
/// 包络起伏；[progress] 之前的条形实心黑（已播过），其余半透明黑。
final class _VoiceWavePainter extends CustomPainter {
  const _VoiceWavePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final bars = (size.width / 8).round().clamp(5, 14);
    final barWidth = size.width / (bars * 2 - 1);
    final centerY = size.height / 2;
    for (var i = 0; i < bars; i++) {
      // 容差避免浮点边界丢亮一根条。
      final lit = progress >= (i + 1) / bars - 0.001;
      final paint = Paint()
        ..color = lit
            ? CupertinoColors.black
            : CupertinoColors.black.withValues(alpha: .35)
        ..strokeWidth = barWidth
        ..strokeCap = StrokeCap.round;
      final envelope =
          0.35 + 0.65 * (0.5 + 0.5 * math.sin(i / bars * math.pi * 2.2));
      final barHeight = size.height * 0.72 * envelope;
      final x = barWidth / 2 + i * barWidth * 2;
      canvas.drawLine(Offset(x, centerY - barHeight / 2),
          Offset(x, centerY + barHeight / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceWavePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
