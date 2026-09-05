import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'call_controller.dart';
import 'call_notifications.dart';
import 'call_page.dart';
import '../contacts/user_display_name_resolver.dart';
import 'incoming_call_overlay_state.dart';
import 'matrix_call_adapter.dart';

/// 全局根导航键（规格 §二）：由 main.dart 挂载到 CupertinoApp。
/// CallUiManager 用它在任意页面/路由之上推来电页；统计助手等
/// 无上下文导航复用同一根 Navigator。
final GlobalKey<NavigatorState> callNavigatorKey = GlobalKey<NavigatorState>();

/// 全局通话 UI 管理器（规格 §一）：**唯一**有权呈现/关闭来电页面的
/// 组件——普通页面禁止自听 CallController 呈现通话 UI。
///
/// - ringing + 前台：经全局 [navigatorKey] 在根 Navigator 顶推 CallPage
///   （盖在任意业务页面/设置子页之上——旧 overlay 方案在推入路由之下，
///   来电会被盖住，这是本管理器修复的 bug）；
/// - ringing + 后台/锁屏：全屏意图系统通知（calls_ring 渠道，系统铃声）；
/// - connecting/connected：保持页面不重建 + 通话中前台服务；
/// - ended/failed/permissionDenied：延迟 [closeDelay] 关闭；窗口内状态
///   回到 connected/connecting/ringing（抖动）则取消关闭。
final class CallUiManager {
  CallUiManager({
    required this.navigatorKey,
    required this.notifications,
    required this.isAppResumed,
    this.displayNameResolver,
    this.closeDelay = const Duration(seconds: 2),
    this.onPhaseChanged,
  });

  /// 根 Navigator 全局键（main.dart 的 callNavigatorKey）。
  final GlobalKey<NavigatorState> navigatorKey;
  final CallNotificationGateway notifications;
  final bool Function() isAppResumed;

  /// 终态→关闭的缓冲（抖动容忍窗口）。
  final Duration closeDelay;

  /// 规格#2：来电显示名（备注>昵称>Matrix名>username>MatrixID；
  /// 禁止直接显示 remoteUserId）。null 时回退 Matrix ID。
  final UserDisplayNameResolver? displayNameResolver;

  String _callerDisplayName(String? matrixUserId) {
    final id = matrixUserId ?? '加密来电';
    if (matrixUserId == null) return id;
    return displayNameResolver?.resolveSync(matrixUserId) ?? id;
  }

  /// 业务侧钩子（消息提醒抑制/通话摘要），UI 决策留在本类。
  final void Function(CallPhase previous, CallPhase next)? onPhaseChanged;

  final IncomingCallOverlayState _overlay = IncomingCallOverlayState();
  CallController? _controller;
  MatrixCallBackend? _mediaBackend;
  Route<void>? _incomingRoute;
  Timer? _closeTimer;
  CallPhase _lastPhase = CallPhase.idle;
  bool Function() _outgoingCallPageVisible = () => false;

  /// 来电响铃中（通知语义：全屏通知/铃声抑制）。
  bool get ringing => _overlay.ringing;

  /// 本管理器推入的来电页是否仍在导航栈。
  bool get isIncomingPageOpen => _incomingRoute?.isActive ?? false;

  /// 登录会话装配后挂接：本类成为 CallController 的 UI 监听者。
  void attach(
    CallController controller, {
    MatrixCallBackend? mediaBackend,
    bool Function()? outgoingCallPageVisible,
  }) {
    detach();
    _controller = controller;
    _mediaBackend = mediaBackend;
    _outgoingCallPageVisible = outgoingCallPageVisible ?? () => false;
    _lastPhase = controller.state.phase;
    controller.addListener(_handleCallState);
  }

  Future<void> detach() async {
    _controller?.removeListener(_handleCallState);
    _controller = null;
    _cancelClose();
    _incomingRoute = null;
    _overlay.reset();
  }

  /// 规格入口（§三）：来电呈现（前台推页 / 后台全屏通知）。幂等。
  void showIncomingCall(CallController controller) {
    if (_controller != controller) return;
    _handleCallState();
  }

  /// 回到前台且仍在响铃：收起系统全屏通知，改由应用内接听页呈现。
  void handleAppResumed() {
    if (_overlay.ringing) {
      unawaited(notifications.hideIncoming());
    }
  }

  void _handleCallState() {
    final controller = _controller;
    if (controller == null) return;
    final phase = controller.state.phase;
    final previous = _lastPhase;
    _lastPhase = phase;
    _overlay.update(phase, outgoingCallPageVisible: _outgoingCallPageVisible());
    onPhaseChanged?.call(previous, phase);

    switch (phase) {
      case CallPhase.ringing:
        _cancelClose();
        if (_outgoingCallPageVisible()) break; // 主叫回铃：不盖来电页
        if (isAppResumed()) {
          unawaited(notifications.hideIncoming());
          _pushIncomingPage(controller);
        } else if (!_incomingOpen()) {
          final caller = controller.state.matrixUserId;
          unawaited(notifications.showIncoming(
            callerName: _callerDisplayName(caller),
            video: controller.state.type == CallMediaType.video,
            ring: true,
          ));
        }
      case CallPhase.connecting:
      case CallPhase.connected:
        _cancelClose(); // 抖动恢复：取消挂起的关闭
        if (previous == CallPhase.ringing) {
          unawaited(notifications.hideIncoming());
        }
        // 回前台恢复通话页（覆盖 ringing/connecting/connected）：页面
        // 不存在则补开（后台经原生通知接听后回 App 必须能看到通话页），
        // 已在栈中则不重复压入；主叫页面在栈时不盖（outgoing 守卫）。
        if (isAppResumed() &&
            !_outgoingCallPageVisible() &&
            !_incomingOpen()) {
          _pushIncomingPage(controller);
        }
        // 通话中前台服务：切后台后麦克风/摄像头不回收。
        unawaited(notifications.showOngoing(title: '端到端加密通话进行中'));
      case CallPhase.ended:
      case CallPhase.failed:
      case CallPhase.permissionDenied:
        unawaited(notifications.hideIncoming());
        unawaited(notifications.hideOngoing());
        _scheduleClose();
      case CallPhase.idle:
      case CallPhase.requestingPermission:
        break;
    }
  }

  bool _incomingOpen() => _incomingRoute?.isActive ?? false;

  void _pushIncomingPage(CallController controller) {
    if (_incomingOpen()) return; // 幂等：同一通话只推一次
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    final state = controller.state;
    final callerId = state.matrixUserId;
    final callerName = _callerDisplayName(callerId);
    _incomingRoute = CupertinoPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => CallPage(
        controller: controller,
        displayName: callerName,
        fallbackSeed: callerId ?? 'incoming-call',
        incoming: true,
        mediaBackend: _mediaBackend,
      ),
    );
    navigator.push(_incomingRoute!);
  }

  /// 终态延迟关闭：窗口内回到 connected/connecting/ringing（抖动）不关闭。
  void _scheduleClose() {
    if (!_incomingOpen()) return;
    _cancelClose();
    _closeTimer = Timer(closeDelay, () {
      _closeTimer = null;
      final route = _incomingRoute;
      if (route == null || !route.isActive) return;
      final phase = _controller?.state.phase ?? CallPhase.idle;
      if (phase == CallPhase.connected ||
          phase == CallPhase.connecting ||
          phase == CallPhase.ringing) {
        return; // 抖动恢复：保留页面
      }
      final navigator = navigatorKey.currentState;
      if (navigator == null) return;
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
      _incomingRoute = null;
    });
  }

  void _cancelClose() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }
}
