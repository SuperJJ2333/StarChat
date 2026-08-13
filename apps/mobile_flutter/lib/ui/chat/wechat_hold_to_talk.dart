import 'package:flutter/cupertino.dart';

import '../../features/matrix/voice_recording_controller.dart';
import '../foundation/wechat_tokens.dart';

final class WeChatHoldToTalk extends StatefulWidget {
  const WeChatHoldToTalk({super.key, required this.controller, required this.onStart, required this.onStop, required this.onCancel});
  final VoiceRecordingController controller;
  final Future<void> Function() onStart;
  final Future<void> Function(Duration duration) onStop;
  final Future<void> Function() onCancel;
  @override State<WeChatHoldToTalk> createState() => _WeChatHoldToTalkState();
}

final class _WeChatHoldToTalkState extends State<WeChatHoldToTalk> {
  DateTime? startedAt;
  Future<void> _start(LongPressStartDetails _) async {
    startedAt = DateTime.now();
    widget.controller.start();
    await widget.onStart();
  }
  void _move(LongPressMoveUpdateDetails detail) => widget.controller.updateDrag(detail.localOffsetFromOrigin.dy);
  Future<void> _end(LongPressEndDetails _) async {
    final elapsed = DateTime.now().difference(startedAt ?? DateTime.now());
    if (widget.controller.state == VoiceRecordingState.cancelArmed) {
      widget.controller.discard();
      await widget.onCancel();
      return;
    }
    widget.controller.release(elapsed);
    if (widget.controller.state == VoiceRecordingState.preview) await widget.onStop(elapsed);
  }
  @override Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (_, __) => GestureDetector(
      onLongPressStart: _start,
      onLongPressMoveUpdate: _move,
      onLongPressEnd: _end,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: widget.controller.state == VoiceRecordingState.cancelArmed ? WeChatColors.danger : CupertinoTheme.of(context).barBackgroundColor,
          borderRadius: BorderRadius.circular(WeChatRadius.control),
        ),
        child: Text(widget.controller.state == VoiceRecordingState.cancelArmed ? '松开取消' : '按住说话'),
      ),
    ),
  );
}
