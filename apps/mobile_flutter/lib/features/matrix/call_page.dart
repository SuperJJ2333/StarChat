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
import 'media_renderer_binding.dart';
import '../settings/notification/call_permission_checklist.dart';

/// 加密语音/视频通话页（微信式）：
/// - **语音**：深色背景 + 对方头像/昵称 + 状态（等待接听/通话时长）；
///   底部 静音、挂断、免提 三枚圆形按钮；
/// - **视频**：主叫等待期本地画面铺满（微信语义），接通后远端画面
///   全屏铺底、本端画中画定位屏幕右上；顶部对方昵称与通话时长；
///   底部 切换镜头、免提、挂断、静音；
/// - **来电**（语音/视频一致）：头像 + 昵称 + 邀请类型 + 拒绝（红）/
///   接听（绿），不渲染未就绪的远端画面；
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
    this.onMinimize,
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
  final VoidCallback? onMinimize;

  @override
  State<CallPage> createState() => _CallPageState();
}

final class _CallPageState extends State<CallPage> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  Timer? _durationTicker;
  DateTime? _connectedAt;

  /// P1-3：渲染器就绪/页面销毁守卫——初始化与 dispose 竞争时不得再向
  /// renderer 写 srcObject（初始化未完成写入会抛异常；销毁后写入泄漏）。
  bool _renderersReady = false;
  bool _disposed = false;
  StreamSubscription<void>? _streamChangesSub;

  /// P1-3：绑定单元（读 backend 流 → 写 renderer，幂等/可注入测试）。
  late final MediaRendererBinding _localBinding = MediaRendererBinding(
    readStream: () => widget.mediaBackend?.localMediaStream,
    applyStream: (stream) => _localRenderer.srcObject = stream,
  );
  late final MediaRendererBinding _remoteBinding = MediaRendererBinding(
    readStream: () => widget.mediaBackend?.remoteMediaStream,
    applyStream: (stream) => _remoteRenderer.srcObject = stream,
  );

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
    // 初始化期间页面可能已被销毁（快速退出/来电页被替换）。
    if (_disposed || !mounted) return;
    _renderersReady = true;
    _updateStreams();
    // P1-3：流在初始化/状态通知之后到达或重建时，独立触发重绑——
    // 不再依赖"恰好有下一次 controller 事件"。
    _streamChangesSub?.cancel();
    final changes = widget.mediaBackend?.mediaStreamChanges;
    if (changes != null) {
      _streamChangesSub = changes.listen((_) => _updateStreams());
    }
  }

  void _updateStreams() {
    if (!_renderersReady || _disposed || widget.mediaBackend == null) return;
    // 幂等绑定：仅流实例真正变化时写 renderer（计时器 setState 不重绑）。
    _localBinding.update();
    _remoteBinding.update();
  }

  bool _endPopHandled = false;

  /// 规格§四：接通过至少一次（此后终态有抖动缓冲，短暂 ended 不立即退出）。
  bool _hasConnectedOnce = false;
  Timer? _endGraceTimer;

  /// 接通过一次后的终态→退出缓冲窗口。
  static const _endGrace = Duration(seconds: 3);

  void _changed() {
    if (widget.controller.state.phase == CallPhase.connected) {
      _hasConnectedOnce = true;
    }
    _updateStreams();
    _syncDurationTicker();
    if (mounted) setState(() {});
    _autoCloseIfEnded();
  }

  /// 通话结束（挂断/失败/权限拒绝）自动关闭本页：
  /// - 从未接通（拒接/取消/失败）：立即关闭，不拖失败页；
  /// - 接通过一次（hasConnectedOnce）：留 [_endGrace] 缓冲——短暂
  ///   网络抖动（ended 后又恢复 connected/connecting/ringing）会取消
  ///   关闭；缓冲期后仍为终态才退出。
  void _autoCloseIfEnded() {
    if (!widget.autoCloseOnEnd || _endPopHandled) return;
    final phase = widget.controller.state.phase;
    if (phase == CallPhase.permissionDenied) return;
    final ended = phase == CallPhase.ended ||
        phase == CallPhase.failed ||
        phase == CallPhase.permissionDenied;
    if (!ended) {
      // 抖动恢复：取消挂起的关闭。
      _endGraceTimer?.cancel();
      _endGraceTimer = null;
      return;
    }
    if (!_hasConnectedOnce) {
      _popOnce();
      return;
    }
    _endGraceTimer ??= Timer(_endGrace, () {
      _endGraceTimer = null;
      final now = widget.controller.state.phase;
      final stillEnded = now == CallPhase.ended ||
          now == CallPhase.failed ||
          now == CallPhase.permissionDenied;
      // Timer 回调不在 build 期：直接 pop（postFrame 推迟在此场景可能
      // 因无后续帧而不执行）。
      if (stillEnded) _popOnce(defer: false);
    });
  }

  void _popOnce({bool defer = true}) {
    if (_endPopHandled) return;
    _endPopHandled = true;
    if (!mounted) return;
    if (!defer) {
      _popRoute();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _popRoute();
    });
  }

  void _popRoute() {
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = route.navigator;
    if (route.isCurrent) {
      if (navigator?.canPop() == true) navigator!.pop();
    } else {
      navigator?.removeRoute(route);
    }
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
    // 时钟取自控制器（可注入 fake clock；与 connectedAt 同源）。
    return formatCallDuration(widget.controller.now().difference(connectedAt));
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_streamChangesSub?.cancel());
    _localBinding.dispose();
    _remoteBinding.dispose();
    widget.controller.removeListener(_changed);
    _durationTicker?.cancel();
    _endGraceTimer?.cancel();
    unawaited(_setScreenOn(false));
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  String get status => switch (widget.controller.state.phase) {
        CallPhase.idle => '准备端到端加密通话',
        CallPhase.requestingPermission => '正在请求通话权限',
        CallPhase.ringing => widget.incoming
            ? widget.controller.state.message ?? _incomingInviteText
            : '正在等待对方接听…',
        CallPhase.connecting => '正在建立加密连接…',
        CallPhase.connected =>
          widget.controller.state.muted ? '麦克风已关闭' : '端到端加密',
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
    final outgoingRinging =
        state.phase == CallPhase.ringing && !widget.incoming;
    final videoCall = state.type == CallMediaType.video;

    final Widget body;
    if (videoCall &&
        widget.mediaBackend != null &&
        (connected || outgoingRinging)) {
      body = _videoBody(state, connected, outgoingRinging);
    } else {
      body = _voiceBody(state, connected, outgoingRinging);
    }
    final active = switch (state.phase) {
      CallPhase.requestingPermission ||
      CallPhase.ringing ||
      CallPhase.connecting ||
      CallPhase.connected =>
        true,
      _ => false,
    };
    return PopScope(
      canPop: !active || widget.onMinimize == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && active) widget.onMinimize?.call();
      },
      child: WeChatPageScaffold.bare(
        backgroundColor: WeChatColors.darkSurface,
        child: Stack(fit: StackFit.expand, children: [
          body,
          if (active && widget.onMinimize != null)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 4,
              left: 8,
              child: CupertinoButton(
                key: const Key('call-minimize'),
                onPressed: widget.onMinimize,
                child: const Icon(CupertinoIcons.arrow_down_right_arrow_up_left,
                    color: CupertinoColors.white),
              ),
            ),
        ]),
      ),
    );
  }

  /// 语音体顶部预览区（审计 P2：等待态不渲染远端画面）：
  /// - 视频主叫等待/接通：由 [_videoBody] 呈现（等待期本地画面）；
  /// - 来电响铃/语音呼叫/建立中：头像呈现——远端画面尚未就绪，渲染
  ///   _remoteRenderer 只会得到黑色区域（与语音来电观感不一致）。
  List<Widget> _voicePreviewWidgets(CallViewState state) {
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
              _endedControls(),
            const SizedBox(height: WeChatSpacing.xxl),
          ],
        ),
      ),
    );
  }

  /// 视频通话（审计 P2：等待/接通分态呈现）：
  /// - 主叫等待：本地画面铺满（微信语义：等待时看自己），接通切换远端；
  /// - 接通：远端全屏铺底 + 本端画中画**屏幕右上角**（Positioned 定位，
  ///   此前 Align 嵌在 Column 内无法到达屏幕角落）+ 顶部信息 + 底部控制。
  Widget _videoBody(CallViewState state, bool connected, bool outgoingRinging) {
    final safeTop = MediaQuery.of(context).padding.top;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: CupertinoColors.black),
        RTCVideoView(
          // 等待期远端无画面：主叫等待显示本地镜像；接通后切远端。
          connected ? _remoteRenderer : _localRenderer,
          mirror: !connected,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
        // 本端画中画（仅接通后：微信位置=屏幕右上角，前置镜像）。
        if (connected)
          Positioned(
            top: safeTop + 64,
            right: WeChatSpacing.lg,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(WeChatRadius.dialog),
              child: SizedBox(
                width: 100,
                height: 140,
                child: RTCVideoView(_localRenderer, mirror: true),
              ),
            ),
          ),
        SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.lg),
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
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: WeChatSpacing.lg),
                child: connected || state.phase == CallPhase.ringing
                    ? (widget.incoming && state.phase == CallPhase.ringing
                        ? _incomingControls()
                        : _videoControls(state, connected))
                    : _endedControls(),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  /// 结束/失败态控制：失败且可回拨时提供「重试」（会话仍在→再接听，
  /// 已终止→回拨），其余仅关闭。
  Widget _endedControls() {
    final state = widget.controller.state;
    if (state.phase == CallPhase.requestingPermission ||
        state.phase == CallPhase.connecting) {
      return CallControlButton(
        key: const Key('call-control-hangup'),
        icon: ChangliaoIcons.hangup,
        label: '挂断',
        kind: CallControlKind.danger,
        onPressed: widget.controller.hangup,
      );
    }
    if (state.phase == CallPhase.permissionDenied) {
      return Column(children: [
        CupertinoButton(
          key: const Key('call-permission-settings'),
          onPressed: () => Navigator.of(context).push(CupertinoPageRoute<void>(
            builder: (_) => const CallPermissionSettingsPage(),
          )),
          child: const Text('检查通话权限'),
        ),
        CupertinoButton(
          onPressed: () => Navigator.maybePop(context),
          child: const Text('关闭'),
        ),
      ]);
    }
    final canRetry = state.phase == CallPhase.failed &&
        state.roomId != null &&
        state.matrixUserId != null;
    if (!canRetry) {
      return CallControlButton(
        key: const Key('call-control-close'),
        icon: ChangliaoIcons.close,
        label: '关闭',
        onPressed: () => Navigator.maybePop(context),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        CallControlButton(
          key: const Key('call-control-retry'),
          icon: ChangliaoIcons.voiceCallFilled,
          label: '重试',
          kind: CallControlKind.accept,
          onPressed: () => widget.controller.retryAfterFailure(),
        ),
        CallControlButton(
          key: const Key('call-control-close'),
          icon: ChangliaoIcons.close,
          label: '关闭',
          onPressed: () => Navigator.maybePop(context),
        ),
      ],
    );
  }

  /// 来电：拒绝（红）/ 接听（绿），微信式左右两枚大圆钮。
  Widget _incomingControls() {
    return Column(children: [
      if (widget.controller.state.message != null)
        CupertinoButton(
          key: const Key('call-permission-settings'),
          onPressed: () => Navigator.of(context).push(CupertinoPageRoute<void>(
            builder: (_) => const CallPermissionSettingsPage(),
          )),
          child: const Text('检查通话权限'),
        ),
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
    ]);
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
          icon: state.speaker
              ? ChangliaoIcons.speakerFilled
              : ChangliaoIcons.speaker,
        ),
      ],
    );
  }
}
