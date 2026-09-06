import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'call_controller.dart';
import 'call_notifications.dart';
import 'call_page.dart';
import '../contacts/user_display_name_resolver.dart';
import 'incoming_call_overlay_state.dart';
import 'matrix_call_adapter.dart';
import '../../ui/components/modern_action_button.dart';

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
    this.onMinimized,
    this.onRestored,
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
    return displayNameResolver?.resolveSync(matrixUserId) ??
        (id.startsWith('@') ? id.substring(1).split(':').first : id);
  }

  /// 业务侧钩子（消息提醒抑制/通话摘要），UI 决策留在本类。
  final void Function(CallPhase previous, CallPhase next)? onPhaseChanged;
  final VoidCallback? onMinimized;
  final VoidCallback? onRestored;
  bool _minimized = false;
  bool _outgoingSession = false;
  OverlayEntry? _returnEntry;

  bool get hasActiveCall => _active;

  bool get _active => switch (_controller?.state.phase) {
        CallPhase.ringing ||
        CallPhase.requestingPermission ||
        CallPhase.connecting ||
        CallPhase.connected =>
          true,
        _ => false,
      };

  void registerOutgoingCall() {
    _outgoingSession = true;
    _minimized = false;
    _removeReturnEntry();
  }

  /// Presentation-only: media is owned by CallController, never this route.
  void minimizeCall() {
    if (!_active) return;
    _minimized = true;
    _cancelClose();
    final route = _incomingRoute;
    _incomingRoute = null;
    if (route != null && route.isActive) {
      route.navigator?.removeRoute(route);
    }
    _showReturnEntry();
    onMinimized?.call();
    _handleCallState();
  }

  /// Explicit tap on the in-app, overlay or notification return entry.
  void restoreCall() {
    final controller = _controller;
    if (!_active || controller == null) return;
    _minimized = false;
    _removeReturnEntry();
    onRestored?.call();
    if (!_outgoingCallPageVisible()) _pushIncomingPage(controller);
  }

  void _removeReturnEntry() {
    _returnEntry?.remove();
    _returnEntry?.dispose();
    _returnEntry = null;
  }

  void _showReturnEntry() {
    if (_returnEntry != null) return;
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _returnEntry = OverlayEntry(
        builder: (context) => Positioned(
              top: MediaQuery.paddingOf(context).top + 52,
              right: 12,
              child: ModernActionButton(
                key: const Key('return-to-call'),
                icon: CupertinoIcons.phone_fill,
                label: '返回通话',
                onPressed: restoreCall,
              ),
            ));
    overlay.insert(_returnEntry!);
  }

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
    _removeReturnEntry();
    _minimized = false;
    _outgoingSession = false;
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

  /// 回到前台（审计 P1 修复）：按当前**非终态**重做呈现决策。
  ///
  /// 后台响铃期间未推过页面；用户回前台时 phase 不变，不会再触发
  /// _handleCallState——此前只取消通知会留下"通知没了、接听页也缺失"
  /// 的窗口。现在 ringing/connecting/connected 一律重跑呈现（推页幂等、
  /// 尊重主叫页），页面恢复后由该路径收起系统通知。
  /// Home/app switch leaves the route mounted, but still needs a system entry.
  void handleAppPaused() {
    if (_active) onMinimized?.call();
  }

  void handleAppResumed() {
    if (_active && !_minimized) onRestored?.call();
    final controller = _controller;
    if (controller == null) return;
    final phase = controller.state.phase;
    if (phase == CallPhase.ringing ||
        phase == CallPhase.connecting ||
        phase == CallPhase.connected) {
      _handleCallState();
      return;
    }
    // 无活动通话时的防御性清理（残留通知）。
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

    if (_minimized && _active) {
      _showReturnEntry();
      if (phase == CallPhase.connecting ||
          phase == CallPhase.connected ||
          (phase == CallPhase.ringing && _outgoingSession)) {
        unawaited(notifications.showOngoing(
          title: '点击返回通话',
          video: controller.state.type == CallMediaType.video,
        ));
      } else if (phase == CallPhase.ringing && !_outgoingSession) {
        unawaited(notifications.showIncoming(
          callerName: _callerDisplayName(controller.state.matrixUserId),
          video: controller.state.type == CallMediaType.video,
          ring: !isAppResumed(),
          fullScreenIntent: false,
        ));
      }
      return;
    }

    switch (phase) {
      case CallPhase.ringing:
        _cancelClose();
        if (_outgoingSession) {
          unawaited(notifications.showOngoing(
            title: '等待接听，点击返回通话',
            video: controller.state.type == CallMediaType.video,
          ));
        }
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
        if (isAppResumed() && !_outgoingCallPageVisible() && !_incomingOpen()) {
          _pushIncomingPage(controller);
        }
        // 通话中前台服务：切后台后麦克风/摄像头不回收。
        unawaited(notifications.showOngoing(
          title: '点击返回通话',
          video: controller.state.type == CallMediaType.video,
        ));
      case CallPhase.ended:
      case CallPhase.failed:
      case CallPhase.permissionDenied:
        _minimized = false;
        _outgoingSession = false;
        _removeReturnEntry();
        unawaited(notifications.hideIncoming());
        unawaited(notifications.hideOngoing());
        if (phase != CallPhase.permissionDenied) _scheduleClose();
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
      builder: (_) => FutureBuilder<String>(
        future:
            callerId == null ? null : displayNameResolver?.resolve(callerId),
        initialData: callerName,
        builder: (_, snapshot) => CallPage(
          controller: controller,
          displayName: snapshot.data ?? callerName,
          fallbackSeed: callerId ?? 'incoming-call',
          incoming: !_outgoingSession,
          onMinimize: minimizeCall,
          mediaBackend: _mediaBackend,
        ),
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
