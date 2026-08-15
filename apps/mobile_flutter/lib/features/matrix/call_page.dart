import 'package:flutter/cupertino.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_avatar.dart';
import 'call_controller.dart';
import 'matrix_call_adapter.dart';

final class CallPage extends StatefulWidget {
  const CallPage({
    super.key,
    required this.controller,
    required this.displayName,
    required this.fallbackSeed,
    this.avatarUrl,
    this.incoming = false,
    this.mediaBackend,
  });

  final CallController controller;
  final String displayName;
  final String fallbackSeed;
  final String? avatarUrl;
  final bool incoming;
  final MatrixCallBackend? mediaBackend;

  @override
  State<CallPage> createState() => _CallPageState();
}

final class _CallPageState extends State<CallPage> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  @override
  void initState() {
    super.initState();
    _initializeRenderers();
    widget.controller.addListener(_changed);
  }

  Future<void> _initializeRenderers() async {
    await Future.wait(
        [_localRenderer.initialize(), _remoteRenderer.initialize()]);
    _updateStreams();
  }

  void _updateStreams() {
    _localRenderer.srcObject = widget.mediaBackend?.localMediaStream;
    _remoteRenderer.srcObject = widget.mediaBackend?.remoteMediaStream;
  }

  void _changed() {
    _updateStreams();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _localRenderer.dispose();
    _remoteRenderer.dispose();
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
              if (state.type == CallMediaType.video &&
                  widget.mediaBackend != null)
                Expanded(
                  flex: 3,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 360),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: RTCVideoView(_remoteRenderer),
                          ),
                          Positioned(
                            right: 12,
                            bottom: 12,
                            width: 100,
                            height: 140,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: RTCVideoView(_localRenderer, mirror: true),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
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
