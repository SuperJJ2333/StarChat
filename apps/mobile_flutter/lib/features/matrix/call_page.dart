import 'package:flutter/cupertino.dart';

import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_avatar.dart';
import 'call_controller.dart';

final class CallPage extends StatefulWidget {
  const CallPage({
    super.key,
    required this.controller,
    required this.displayName,
    required this.fallbackSeed,
    this.avatarUrl,
    this.incoming = false,
  });

  final CallController controller;
  final String displayName;
  final String fallbackSeed;
  final String? avatarUrl;
  final bool incoming;

  @override
  State<CallPage> createState() => _CallPageState();
}

final class _CallPageState extends State<CallPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  String get status => switch (widget.controller.state.phase) {
        CallPhase.idle => '准备通话',
        CallPhase.requestingPermission => '正在请求权限',
        CallPhase.ringing => widget.incoming ? '邀请你通话' : '正在呼叫',
        CallPhase.connected => '通话中',
        CallPhase.permissionDenied => '权限被拒绝',
        CallPhase.ended => widget.controller.state.message ?? '通话已结束',
        CallPhase.failed => widget.controller.state.message ?? '通话失败',
      };

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final active =
        state.phase == CallPhase.connected || state.phase == CallPhase.ringing;
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xfff5f5f5),
      navigationBar: CupertinoNavigationBar(
        middle: Text(state.type == CallMediaType.video ? '视频通话' : '语音通话'),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              UserAvatar(
                nickname: widget.displayName,
                fallbackSeed: widget.fallbackSeed,
                avatarUrl: widget.avatarUrl,
                size: 112,
              ),
              const SizedBox(height: 20),
              Text(
                widget.displayName,
                style:
                    const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Text(status),
              const Spacer(),
              if (widget.incoming && state.phase == CallPhase.ringing) ...[
                ModernActionButton(
                  icon: CupertinoIcons.phone_fill,
                  label: '接听',
                  onPressed: widget.controller.accept,
                ),
                const SizedBox(height: 10),
                ModernActionButton(
                  icon: CupertinoIcons.phone_down_fill,
                  label: '拒接',
                  kind: ModernActionKind.danger,
                  onPressed: widget.controller.reject,
                ),
              ] else if (active) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    CupertinoButton(
                      onPressed: widget.controller.toggleMute,
                      child: Icon(state.muted
                          ? CupertinoIcons.mic_off
                          : CupertinoIcons.mic),
                    ),
                    CupertinoButton(
                      onPressed: widget.controller.toggleSpeaker,
                      child: Icon(state.speaker
                          ? CupertinoIcons.speaker_3_fill
                          : CupertinoIcons.speaker_2),
                    ),
                    if (state.type == CallMediaType.video)
                      CupertinoButton(
                        onPressed: widget.controller.switchCamera,
                        child: const Icon(CupertinoIcons.camera_rotate),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                ModernActionButton(
                  icon: CupertinoIcons.phone_down_fill,
                  label: '挂断',
                  kind: ModernActionKind.danger,
                  onPressed: widget.controller.hangup,
                ),
              ] else
                ModernActionButton(
                  icon: CupertinoIcons.clear,
                  label: '关闭',
                  kind: ModernActionKind.secondary,
                  onPressed: () => Navigator.pop(context),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
