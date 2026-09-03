import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../ui/components/call_control_button.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../../ui/components/wechat_scaffold.dart';
import 'call_controller.dart';
import 'matrix_call_adapter.dart';

/// 加密语音/视频通话页（微信式）：
/// - **语音**：深色背景 + 对方头像/昵称 + 状态（等待接听/通话时长）；
///   底部 静音、挂断、免提 三枚圆形按钮；
/// - **视频**：远端画面**全屏铺底**，本端画中画居右上；顶部对方昵称与
///   通话时长；底部 切换镜头、免提、挂断、静音；
/// - **来电**：全屏 + 震动铃声提醒，底部 拒绝（红）/ 接听（绿）；
/// - 通话期间屏幕常亮，挂断自动恢复。
final class CallPage extends StatefulWidget {
  const CallPage({
    super.key,
    required this.controller,
    required this.displayName,
    required this.fallbackSeed,
    this.avatarUrl,
    this.incoming = false,
    this.mediaBackend,
    this.autoCloseOnEnd = false,
  });

  final CallController controller;
  final String displayName;
  final String fallbackSeed;
  final String? avatarUrl;
  final bool incoming;
  final MatrixCallBackend? mediaBackend;

  /// 通话结束后自动关闭本页（直接回到消息会话页，不保留
  /// “通话已结束”独立页面）。来电覆盖层场景保持 false（由覆盖层
  /// 自身的可见性逻辑驱动）。
  final bool autoCloseOnEnd;

  @override
  State<CallPage> createState() => _CallPageState();
}

final class _CallPageState extends State<CallPage> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  Timer? _durationTicker;
  DateTime? _connectedAt;

  @override
  void initState() {
    super.initState();
    if (widget.mediaBackend != null) _initializeRenderers();
    widget.controller.addListener(_changed);
    // 通话界面打开期间屏幕常亮（微信语义），退出即恢复。
    unawaited(_setScreenOn(true));
    _syncDurationTicker();
  }

  Future<void> _setScreenOn(bool on) async {
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {
      // 平台不支持（如测试环境）时忽略，不影响通话。
    }
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

  bool _endPopHandled = false;

  void _changed() {
    _updateStreams();
    _syncDurationTicker();
    if (mounted) setState(() {});
    _autoCloseIfEnded();
  }

  /// 通话结束（挂断/失败/权限拒绝）即刻自动关闭通话页：
  /// 不保留“通话已结束”独立页面，直接回到消息会话页。
  void _autoCloseIfEnded() {
    if (!widget.autoCloseOnEnd || _endPopHandled) return;
    final phase = widget.controller.state.phase;
    final ended = phase == CallPhase.ended ||
        phase == CallPhase.failed ||
        phase == CallPhase.permissionDenied;
    if (!ended) return;
    _endPopHandled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  void _syncDurationTicker() {
    _connectedAt = widget.controller.state.connectedAt;
    final connected = widget.controller.state.phase == CallPhase.connected;
    if (connected && _durationTicker == null) {
      _durationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!connected && _durationTicker != null) {
      _durationTicker?.cancel();
      _durationTicker = null;
    }
  }

  String get _durationText {
    final connectedAt = _connectedAt;
    if (connectedAt == null) return '00:00';
    return formatCallDuration(DateTime.now().difference(connectedAt));
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _durationTicker?.cancel();
    unawaited(_setScreenOn(false));
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  String get status => switch (widget.controller.state.phase) {
        CallPhase.idle => '准备端到端加密通话',
        CallPhase.requestingPermission => '正在请求通话权限',
        CallPhase.ringing =>
          widget.incoming ? _incomingInviteText : '正在等待对方接听…',
        CallPhase.connected => widget.controller.state.muted ? '麦克风已关闭' : '端到端加密',
        CallPhase.permissionDenied =>
          widget.controller.state.message ?? '权限被拒绝',
        CallPhase.ended => widget.controller.state.message ?? '通话已结束',
        CallPhase.failed => widget.controller.state.message ?? '通话失败',
      };

  String get _incomingInviteText =>
      widget.controller.state.type == CallMediaType.video
          ? '邀请你进行视频通话'
          : '邀请你进行语音通话';

  String get title {
    final type =
        widget.controller.state.type == CallMediaType.video ? '视频通话' : '语音通话';
    return '${widget.displayName} $type';
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final connected = state.phase == CallPhase.connected;
    final outgoingRinging = state.phase == CallPhase.ringing && !widget.incoming;
    final videoCall = state.type == CallMediaType.video;

    final Widget body;
    if (videoCall &&
        widget.mediaBackend != null &&
        (connected || outgoingRinging)) {
      body = _videoBody(state, connected, outgoingRinging);
    } else {
      body = _voiceBody(state, connected, outgoingRinging);
    }
    return WeChatPageScaffold.bare(
      backgroundColor: WeChatColors.darkSurface,
      child: body,
    );
  }

  /// 语音体顶部预览区（需求：紧凑设备弹性高度）：
  /// - 视频预呼叫：远端画面弹性展示且不超过 360 高（Expanded+maxHeight）；
  /// - 语音呼叫：弹性占位 + 大头像。
  List<Widget> _voicePreviewWidgets(CallViewState state) {
    if (state.type == CallMediaType.video && widget.mediaBackend != null) {
      return [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(WeChatRadius.authControl),
                  child: RTCVideoView(_remoteRenderer),
                ),
              ),
            ),
          ),
        ),
      ];
    }
    return [
      const Spacer(),
      UserAvatar(
        nickname: widget.displayName,
        fallbackSeed: widget.fallbackSeed,
        avatarUrl: widget.avatarUrl,
        size: WeChatDimensions.callControl * 1.6,
      ),
    ];
  }

  /// 语音通话/来电/等待：居中头像 + 昵称 + 状态，底部操作区。
  Widget _voiceBody(CallViewState state, bool connected, bool outgoingRinging) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(WeChatSpacing.xl),
        child: Column(
          children: [
            ..._voicePreviewWidgets(state),
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
              connected ? _durationText : status,
              textAlign: TextAlign.center,
              key: const Key('call-status'),
              style: const TextStyle(
                color: WeChatColors.textSecondary,
                fontSize: WeChatTypography.subhead,
              ),
            ),
            const Spacer(),
            if (widget.incoming && state.phase == CallPhase.ringing)
              _incomingControls()
            else if (connected || outgoingRinging)
              _activeControls(state, connected)
            else
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
    );
  }

  /// 视频通话：远端全屏铺底，顶部信息，本端画中画右上（微信样式）。
  Widget _videoBody(CallViewState state, bool connected, bool outgoingRinging) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: CupertinoColors.black),
        RTCVideoView(
          _remoteRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
        SafeArea(
          child: Column(children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: WeChatSpacing.lg),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: WeChatColors.darkTextPrimary,
                          fontSize: WeChatTypography.title2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        connected ? _durationText : status,
                        key: const Key('call-status'),
                        style: const TextStyle(
                          color: WeChatColors.textSecondary,
                          fontSize: WeChatTypography.caption,
                        ),
                      ),
                    ],
                  ),
                ),
              ]),
            ),
            const Spacer(),
            // 本端画中画（微信位置：右上角，前置镜像）。
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(
                    right: WeChatSpacing.lg, top: WeChatSpacing.xl),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(WeChatRadius.dialog),
                  child: SizedBox(
                    width: 100,
                    height: 140,
                    child: RTCVideoView(_localRenderer, mirror: true),
                  ),
                ),
              ),
            ),
            const Spacer(),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: WeChatSpacing.lg),
                child: connected || state.phase == CallPhase.ringing
                    ? (widget.incoming && state.phase == CallPhase.ringing
                        ? _incomingControls()
                        : _videoControls(state, connected))
                    : CallControlButton(
                        key: const Key('call-control-close'),
                        icon: ChangliaoIcons.close,
                        label: '关闭',
                        onPressed: () => Navigator.maybePop(context),
                      ),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  /// 来电：拒绝（红）/ 接听（绿），微信式左右两枚大圆钮。
  Widget _incomingControls() {
    return Row(
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
    );
  }

  /// 语音通话中：静音 / 挂断 / 免提。
  Widget _activeControls(CallViewState state, bool connected) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        CallControlButton(
          key: const Key('call-control-microphone'),
          label: state.muted ? '取消静音' : '静音',
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
          label: '免提',
          selected: state.speaker,
          onPressed: widget.controller.toggleSpeaker,
          icon:
              state.speaker ? ChangliaoIcons.speakerFilled : ChangliaoIcons.speaker,
        ),
        if (state.type == CallMediaType.video)
          CallControlButton(
            key: const Key('call-control-camera'),
            icon: ChangliaoIcons.switchCamera,
            label: '切换镜头',
            onPressed: widget.controller.switchCamera,
          ),
      ],
    );
  }

  /// 视频通话中：切换镜头 / 静音 / 挂断 / 免提。
  Widget _videoControls(CallViewState state, bool connected) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        CallControlButton(
          key: const Key('call-control-camera'),
          icon: ChangliaoIcons.switchCamera,
          label: '切换镜头',
          onPressed: widget.controller.switchCamera,
        ),
        CallControlButton(
          key: const Key('call-control-microphone'),
          label: state.muted ? '取消静音' : '静音',
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
          label: '免提',
          selected: state.speaker,
          onPressed: widget.controller.toggleSpeaker,
          icon:
              state.speaker ? ChangliaoIcons.speakerFilled : ChangliaoIcons.speaker,
        ),
      ],
    );
  }
}
