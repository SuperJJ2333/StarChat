import 'package:flutter/cupertino.dart';

import '../../ui/components/wechat_scaffold.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../ui/components/call_control_button.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
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
    if (widget.mediaBackend != null) _initializeRenderers();
    widget.controller.addListener(_changed);
  }

  Future<void> _initializeRenderers() async {
    await Future.wait(
        [_localRenderer.initialize(), _remoteRenderer.initialize()]);
    _updateStreams();
  }

  void _updateStreams() {
    if (widget.mediaBackend == null) return;
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
        CallPhase.idle => '准备端到端加密通话',
        CallPhase.requestingPermission => '正在请求通话权限',
        CallPhase.ringing => widget.incoming ? '畅聊加密来电' : '正在等待对方接听…',
        CallPhase.connected =>
          widget.controller.state.muted ? '麦克风已关闭' : '端到端加密',
        CallPhase.permissionDenied =>
          widget.controller.state.message ?? '权限被拒绝',
        CallPhase.ended => widget.controller.state.message ?? '通话已结束',
        CallPhase.failed => widget.controller.state.message ?? '通话失败',
      };

  String get title {
    final type =
        widget.controller.state.type == CallMediaType.video ? '视频通话' : '语音通话';
    return '${widget.displayName} · $type';
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final active = state.phase == CallPhase.connected ||
        (state.phase == CallPhase.ringing && !widget.incoming);
    return WeChatPageScaffold.bare(
      backgroundColor: WeChatColors.darkSurface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(WeChatSpacing.xl),
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
                            borderRadius:
                                BorderRadius.circular(WeChatRadius.authControl),
                            child: RTCVideoView(_remoteRenderer),
                          ),
                          Positioned(
                            right: 12,
                            bottom: 12,
                            width: 100,
                            height: 140,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                WeChatRadius.dialog,
                              ),
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
                  size: WeChatDimensions.callControl,
                ),
              const SizedBox(height: WeChatSpacing.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: WeChatColors.darkTextPrimary,
                  fontSize: WeChatTypography.title1,
                  fontWeight: FontWeight.w700,
                  height: 30 / 22,
                ),
              ),
              const SizedBox(height: WeChatSpacing.md),
              Text(
                status,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: WeChatColors.textSecondary,
                  fontSize: WeChatTypography.subhead,
                ),
              ),
              const Spacer(),
              if (widget.incoming && state.phase == CallPhase.ringing) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    CallControlButton(
                      key: const Key('call-control-reject'),
                      icon: ChangliaoIcons.hangup,
                      label: '拒绝',
                      kind: CallControlKind.danger,
                      onPressed: widget.controller.reject,
                    ),
                    CallControlButton(
                      key: const Key('call-control-answer'),
                      icon: ChangliaoIcons.voiceCallFilled,
                      label: '接听',
                      kind: CallControlKind.accept,
                      onPressed: widget.controller.accept,
                    ),
                  ],
                ),
              ] else if (active) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    CallControlButton(
                      key: const Key('call-control-microphone'),
                      label: state.muted ? '取消静音' : '麦克风',
                      selected: state.muted,
                      onPressed: widget.controller.toggleMute,
                      icon: state.muted
                          ? ChangliaoIcons.microphoneOff
                          : ChangliaoIcons.microphone,
                    ),
                    CallControlButton(
                      key: const Key('call-control-hangup'),
                      icon: ChangliaoIcons.hangup,
                      label: '挂断',
                      kind: CallControlKind.danger,
                      onPressed: widget.controller.hangup,
                    ),
                    CallControlButton(
                      key: const Key('call-control-speaker'),
                      label: '扬声器',
                      selected: state.speaker,
                      onPressed: widget.controller.toggleSpeaker,
                      icon: state.speaker
                          ? ChangliaoIcons.speakerFilled
                          : ChangliaoIcons.speaker,
                    ),
                    if (state.type == CallMediaType.video)
                      CallControlButton(
                        key: const Key('call-control-camera'),
                        icon: ChangliaoIcons.switchCamera,
                        label: '切换镜头',
                        onPressed: widget.controller.switchCamera,
                      ),
                  ],
                ),
              ] else
                CallControlButton(
                  key: const Key('call-control-close'),
                  icon: ChangliaoIcons.close,
                  label: '关闭',
                  onPressed: () => Navigator.maybePop(context),
                ),
              const SizedBox(height: WeChatSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}
