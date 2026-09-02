import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../features/matrix/voice_recording_controller.dart';
import '../foundation/wechat_tokens.dart';

/// “按住说话”按钮：Pointer 事件驱动。
///
/// 手指**按下瞬间**即开始录音并渲染覆盖层（不使用长按识别器，
/// 没有识别延迟，也不等待音频启动回调）；按下立即触发震动与
/// 背景加深动效；滑动目标区（取消/松手发送/转文字）由控制器按
/// 全局坐标判定，滑入目标区的瞬间触发震动；松手按 armed 目标
/// 或正常发送收尾。
final class WeChatHoldToTalk extends StatefulWidget {
  const WeChatHoldToTalk({
    super.key,
    required this.controller,
    required this.onStart,
    required this.onStop,
    required this.onCancel,
  });
  final VoiceRecordingController controller;
  final Future<void> Function() onStart;
  final Future<void> Function(Duration duration) onStop;

  /// [target] 区分滑入“取消”与“转文字”。
  final Future<void> Function(VoiceArmedTarget target) onCancel;

  @override
  State<WeChatHoldToTalk> createState() => _WeChatHoldToTalkState();
}

final class _WeChatHoldToTalkState extends State<WeChatHoldToTalk> {
  Offset? _pressOrigin;

  Future<void> _begin(PointerDownEvent details) async {
    _pressOrigin = details.position;
    // 按下瞬间的触觉反馈：不等待录音启动结果。
    HapticFeedback.mediumImpact();
    widget.controller.start();
    try {
      await widget.onStart();
    } catch (_) {
      widget.controller.discard();
    }
  }

  void _move(PointerMoveEvent detail) {
    final origin = _pressOrigin;
    if (origin == null) return;
    final before = widget.controller.state;
    widget.controller.updateDrag(
      delta: detail.position - origin,
      global: detail.position,
      page: MediaQuery.sizeOf(context),
    );
    // 滑入/切换目标区（取消、松手发送、转文字）时震动一次。
    if (widget.controller.state != before &&
        widget.controller.state != VoiceRecordingState.recording) {
      HapticFeedback.selectionClick();
    }
  }

  Future<void> _end(PointerUpEvent _) => _finish();

  Future<void> _canceled(PointerCancelEvent _) => _finish();

  Future<void> _finish() async {
    final state = widget.controller.state;
    if (state == VoiceRecordingState.cancelArmed ||
        state == VoiceRecordingState.textArmed) {
      final target = state == VoiceRecordingState.textArmed
          ? VoiceArmedTarget.text
          : VoiceArmedTarget.cancel;
      widget.controller.discard();
      await widget.onCancel(target);
      return;
    }
    // 时长由控制器按注入时钟计算，保证 1 秒/60 秒阈值稳定。
    widget.controller.release();
    if (widget.controller.state == VoiceRecordingState.preview) {
      await widget.onStop(widget.controller.duration ?? Duration.zero);
    } else {
      await widget.onCancel(VoiceArmedTarget.none);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (_, __) {
          final state = widget.controller.state;
          final pressed = state != VoiceRecordingState.idle;
          final cancelArmed = state == VoiceRecordingState.cancelArmed;
          final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
          return Listener(
            onPointerDown: _begin,
            onPointerMove: _move,
            onPointerUp: _end,
            onPointerCancel: _canceled,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 120),
              scale: pressed ? .97 : 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cancelArmed
                      ? WeChatColors.danger
                      : pressed
                          ? CupertinoDynamicColor.resolve(
                              CupertinoColors.systemGrey4, context)
                          : CupertinoTheme.of(context).barBackgroundColor,
                  borderRadius: BorderRadius.circular(WeChatRadius.control),
                ),
                child: Text(
                  switch (state) {
                    VoiceRecordingState.cancelArmed => '松开取消',
                    VoiceRecordingState.idle => '按住说话',
                    _ => '松开发送',
                  },
                  style: TextStyle(
                    color: cancelArmed
                        ? CupertinoColors.white
                        : dark
                            ? CupertinoColors.white
                            : CupertinoColors.black,
                  ),
                ),
              ),
            ),
          );
        },
      );
}
