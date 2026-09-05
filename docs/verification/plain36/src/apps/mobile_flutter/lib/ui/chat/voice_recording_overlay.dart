import 'dart:ui';

import 'package:flutter/cupertino.dart';

import '../../features/matrix/voice_recording_controller.dart';
import '../foundation/wechat_tokens.dart';

/// 录音状态覆盖层（严格对齐微信“按住说话”参考图）：
/// - **全屏宽度**毛玻璃背景（BackdropFilter 高斯模糊 + 半透明底色），
///   由调用方以 Positioned.fill 铺满聊天页，消除局部割裂；
/// - IgnorePointer：不拦截手势，手指持续操控底部“按住说话”按钮；
/// - 居中气泡（波形 + 状态提示文字）；
/// - 底部左右**圆形**目标区（“取消”/“滑到这里 转文字”）与中部
///   “松手发送”横条；滑入即整块高亮（颜色 + 放大 + 光晕），
///   命中几何与控制器共用常量，保证画到哪里就能在哪里触发；
/// - 页面在手指按下的同一帧渲染：控制器 start() 先于音频启动。
final class VoiceRecordingOverlay extends StatelessWidget {
  const VoiceRecordingOverlay({
    super.key,
    required this.controller,
    required this.elapsed,
  });

  final VoiceRecordingController controller;
  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final state = controller.state;
          final cancelArmed = state == VoiceRecordingState.cancelArmed;
          final textArmed = state == VoiceRecordingState.textArmed;
          final sendArmed = state == VoiceRecordingState.sendArmed;
          return ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                width: double.infinity,
                height: double.infinity,
                color: dark
                    ? CupertinoColors.black.withValues(alpha: .55)
                    : CupertinoColors.black.withValues(alpha: .25),
                child: Column(
                  children: [
                    const Spacer(flex: 5),
                    _VoiceBubble(
                      cancelArmed: cancelArmed,
                      textArmed: textArmed,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        switch (state) {
                          VoiceRecordingState.cancelArmed => '松开手指，取消发送',
                          VoiceRecordingState.textArmed => '松开手指，转文字',
                          VoiceRecordingState.sendArmed => '松开手指，发送语音',
                          _ => '滑到左下取消，右下转文字',
                        },
                        style: const TextStyle(
                            fontSize: 15, color: CupertinoColors.white),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${elapsed.inSeconds.clamp(0, 60)}″ / 60″',
                      key: const Key('voice-recording-elapsed'),
                      style: TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.white.withValues(alpha: .75),
                      ),
                    ),
                    const Spacer(flex: 3),
                    SafeArea(
                      top: false,
                      child: Padding(
                        // 目标区上移：底部间距 ≥150px，避开系统手势条，
                        // 也让手指滑入目标更从容。
                        padding: const EdgeInsets.fromLTRB(
                            VoiceRecordingController.targetEdgeInset,
                            0,
                            VoiceRecordingController.targetEdgeInset,
                            VoiceRecordingController.targetRowBottomInset),
                        child: SizedBox(
                          height: VoiceRecordingController.targetRowHeight,
                          child: Row(
                            children: [
                              _CircleTarget(
                                key: const Key('voice-target-cancel'),
                                icon: CupertinoIcons.xmark,
                                lines: const ['取消'],
                                armed: cancelArmed,
                                armedColor: WeChatColors.danger,
                              ),
                              const SizedBox(
                                  width:
                                      VoiceRecordingController.targetEdgeInset),
                              Expanded(
                                child: _SendZone(
                                  armed: sendArmed,
                                  dark: dark,
                                ),
                              ),
                              const SizedBox(
                                  width:
                                      VoiceRecordingController.targetEdgeInset),
                              _CircleTarget(
                                key: const Key('voice-target-text'),
                                icon: CupertinoIcons.text_bubble,
                                lines: const ['滑到这里', '转文字'],
                                armed: textArmed,
                                armedColor: WeChatColors.brandPrimary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

final class _VoiceBubble extends StatelessWidget {
  const _VoiceBubble({required this.cancelArmed, required this.textArmed});

  final bool cancelArmed;
  final bool textArmed;

  @override
  Widget build(BuildContext context) {
    final bubbleColor = textArmed || cancelArmed
        ? CupertinoColors.systemGrey4
        : const Color(0xFF9BE24A); // 参考图绿色气泡
    return Container(
      width: 168,
      height: 106,
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: CustomPaint(painter: _WaveformPainter()),
    );
  }
}

final class _WaveformPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = CupertinoColors.black.withValues(alpha: .75)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    const bars = 24;
    final centerY = size.height / 2;
    for (var i = 0; i < bars; i++) {
      final amplitude = size.height *
          .32 *
          (0.35 + 0.65 * (i.isEven ? 0.7 : 1) * (0.55 + 0.45 * ((i / bars * 6.28).abs() % 1)));
      final x = size.width * (i + 1) / (bars + 1);
      canvas.drawLine(
        Offset(x, centerY - amplitude / 2),
        Offset(x, centerY + amplitude / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) => false;
}

/// 左右**圆形**目标区：滑入时整圆填充品牌色并放大 + 光晕，清晰可辨。
final class _CircleTarget extends StatelessWidget {
  const _CircleTarget({
    super.key,
    required this.icon,
    required this.lines,
    required this.armed,
    required this.armedColor,
  });

  final IconData icon;
  final List<String> lines;
  final bool armed;
  final Color armedColor;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return AnimatedScale(
      duration: const Duration(milliseconds: 120),
      scale: armed ? 1.08 : 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: VoiceRecordingController.targetRowHeight,
        height: VoiceRecordingController.targetRowHeight,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: armed
              ? armedColor
              : (dark
                  ? CupertinoColors.systemGrey3.withValues(alpha: .35)
                  : CupertinoColors.systemGrey5.withValues(alpha: .9)),
          border: Border.all(
            color: armed
                ? armedColor.withValues(alpha: .55)
                : (dark
                    ? CupertinoColors.white.withValues(alpha: .25)
                    : CupertinoColors.black.withValues(alpha: .12)),
            width: armed ? 8 : 1,
          ),
          boxShadow: armed
              ? [
                  BoxShadow(
                    color: armedColor.withValues(alpha: .45),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ]
              : const [],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 22,
              color: armed ? CupertinoColors.white : CupertinoColors.label,
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) const SizedBox(height: 1),
              Text(
                lines[i],
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.1,
                  fontWeight: FontWeight.w600,
                  color: armed ? CupertinoColors.white : CupertinoColors.label,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 中部“松手发送”横条：滑入时填充品牌绿并高亮。
final class _SendZone extends StatelessWidget {
  const _SendZone({required this.armed, required this.dark});

  final bool armed;
  final bool dark;

  @override
  Widget build(BuildContext context) => AnimatedScale(
        duration: const Duration(milliseconds: 120),
        scale: armed ? 1.04 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: armed
                ? WeChatColors.brandPrimary
                : (dark
                    ? CupertinoColors.systemGrey3.withValues(alpha: .35)
                    : CupertinoColors.systemGrey5.withValues(alpha: .9)),
            borderRadius: BorderRadius.circular(
                VoiceRecordingController.targetRowHeight / 2),
            border: Border.all(
              color: armed
                  ? WeChatColors.brandPressed
                  : (dark
                      ? CupertinoColors.white.withValues(alpha: .25)
                      : CupertinoColors.black.withValues(alpha: .12)),
              width: armed ? 3 : 1,
            ),
            boxShadow: armed
                ? [
                    BoxShadow(
                      color: WeChatColors.brandPrimary.withValues(alpha: .4),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ]
                : const [],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                CupertinoIcons.paperplane_fill,
                size: 18,
                color: armed ? CupertinoColors.white : CupertinoColors.label,
              ),
              const SizedBox(width: 6),
              Text(
                '松手发送',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: armed ? CupertinoColors.white : CupertinoColors.label,
                ),
              ),
            ],
          ),
        ),
      );
}
