import 'dart:async';

import 'package:flutter/services.dart';

import 'call_controller.dart';

/// 原生待接听请求（用户动作先于 Matrix 响铃同步到达时暂存）。
final class PendingUserAnswer {
  const PendingUserAnswer({
    required this.callId,
    required this.requestedAt,
    required this.deadlineAt,
  });

  /// 绑定的原生通话呈现标识（null = 未知绑定，消费时保守校验）。
  final String? callId;
  final DateTime requestedAt;
  final DateTime deadlineAt;
}

/// 原生来电仲裁器（纯逻辑，可测）：只处理"用户明确接听"的登记与消费。
///
/// 红线：来电事件（incomingCall）本身绝不产生接听动作——接听只能由
/// 用户明确动作（通知[接听]/CallActivity[接听]/Telecom onAnswer）发起。
///
/// 待接听请求的生命周期：
/// - **绑定**：请求绑定当时的原生通话 callId；
/// - **期限**：超过 [answerDeadline] 未匹配 Matrix 响铃即作废；
/// - **取消**：对应原生通话结束、Matrix 通话结束/失败、新通话（不同
///   callId）呈现、账号会话结束，任一发生即作废——过期或被取消的
///   请求绝不应用到下一通电话。
final class NativeCallArbiter {
  NativeCallArbiter({
    this.answerDeadline = const Duration(seconds: 15),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration answerDeadline;
  final DateTime Function() _clock;

  String? _presentedCallId;
  bool _presentationClosed = false;
  PendingUserAnswer? _pendingAnswer;

  /// Native wakeup IDs are independent of Matrix session IDs. Only reject a
  /// known mismatch against the currently registered native presentation.
  bool matchesPresentation(String? callId) =>
      !_presentationClosed &&
      (_presentedCallId == null || callId == _presentedCallId);

  /// 原生来电呈现登记（推送唤醒）。
  void registerIncoming(String? callId) {
    _presentationClosed = false;
    final pending = _pendingAnswer;
    if (pending != null &&
        pending.callId != null &&
        callId != null &&
        pending.callId != callId) {
      // 新通话呈现：旧通话的待接听请求必须作废，不得串到新电话上。
      _pendingAnswer = null;
    }
    if (callId != null) _presentedCallId = callId;
  }

  /// 原生通话呈现结束（远端取消/超时/挂断）：作废与之绑定的待接听。
  void registerEnded(String? callId) {
    if (callId == null || callId == _presentedCallId) {
      // Keep the binding closed until a new presentation arrives. Clearing it
      // here would make a delayed action look like an unbound cold-start action.
      _presentationClosed = true;
    }
    final pending = _pendingAnswer;
    if (pending != null &&
        (callId == null ||
            pending.callId == null ||
            pending.callId == callId)) {
      _pendingAnswer = null;
    }
  }

  /// 用户明确请求接听（绑定当前呈现的通话）。
  void requestAnswer(String? callId) {
    final now = _clock();
    _pendingAnswer = PendingUserAnswer(
      callId: callId ?? _presentedCallId,
      requestedAt: now,
      deadlineAt: now.add(answerDeadline),
    );
  }

  /// Matrix 响铃到达：存在匹配且未过期的待接听则消费（仅一次）。
  ///
  /// 过期或绑定已不匹配（呈现中的通话变了）同样消费掉并返回 false——
  /// 丢弃而不是留给下一通电话。
  bool consumePendingAnswer() {
    final pending = _pendingAnswer;
    if (pending == null) return false;
    _pendingAnswer = null;
    if (_clock().isAfter(pending.deadlineAt)) return false;
    final presented = _presentedCallId;
    if (pending.callId != null &&
        presented != null &&
        pending.callId != presented) {
      return false;
    }
    return true;
  }

  void clear() {
    _pendingAnswer = null;
    if (_presentedCallId != null) _presentationClosed = true;
  }

  /// 是否存在待接听请求（诊断/测试）。
  bool get hasPendingAnswer => _pendingAnswer != null;
}

/// native_call 通道抽象（测试注入替身；生产为 MethodChannel）。
abstract interface class NativeCallChannel {
  Future<Object?> invoke(String method, [Object? arguments]);
}

final class MethodChannelNativeCallChannel implements NativeCallChannel {
  const MethodChannelNativeCallChannel([
    this.channel = const MethodChannel('native_call'),
  ]);

  final MethodChannel channel;

  @override
  Future<Object?> invoke(String method, [Object? arguments]) =>
      channel.invokeMethod<Object?>(method, arguments);
}

/// 原生通话协调器：AppHome 与原生通话层（Telecom/CallStyle 通知/
/// CallActivity）之间的唯一 Dart 侧接线。
///
/// 事件语义（严格区分，修复"收到来电事件即自动接听"）：
/// - **incomingCall**：仅登记呈现，绝不接听；
/// - **callAccepted**：用户明确请求接听 → 仅对当前响铃的 Matrix 通话
///   执行一次 accept（权限与会话有效性由 CallController.accept 校验）；
///   Matrix 响铃未同步到时登记绑定式待接听等待匹配；
/// - **callRejected**：用户明确请求拒绝/挂断，按当前相位执行；
/// - **callEnded**：原生呈现结束，只作废对应待接听；Matrix 决定媒体终态。
///
/// 状态回报：每次 CallController 相位变化经 reportCallState 推送
/// Matrix/WebRTC 事实（语音/视频类型以同步结果为准）；原生层只负责
/// 系统呈现，动作请求与状态回报单向流动，不回发形成循环。
final class NativeCallCoordinator {
  NativeCallCoordinator({
    required this.calls,
    required this.onPresentIncoming,
    this.onDismissNativeLayer,
    NativeCallChannel? channel,
    NativeCallArbiter? arbiter,
    this.pendingActionMaxAge = const Duration(seconds: 30),
    DateTime Function()? clock,
  })  : channel = channel ?? const MethodChannelNativeCallChannel(),
        arbiter = arbiter ?? NativeCallArbiter(),
        _clock = clock ?? DateTime.now;

  final CallController calls;

  /// 呈现来电页（CallUiManager.showIncomingCall）。
  final void Function() onPresentIncoming;

  /// Flutter 已接管通话呈现（收起原生前台服务/通知层）。
  final void Function()? onDismissNativeLayer;

  final NativeCallChannel channel;
  final NativeCallArbiter arbiter;

  /// 原生暂存动作的最大可信年龄（冷启动耗时过长即丢弃）。
  final Duration pendingActionMaxAge;

  final DateTime Function() _clock;

  /// 接听执行中（重复事件/双通道通知/连点去重）。
  bool _accepting = false;

  /// 原生 → Flutter 消息入口（MethodCallHandler 转发到这里）。
  Future<Object?> handleNativeMessage(String method, Object? arguments) async {
    final callId = arguments is Map && arguments['callId'] is String
        ? arguments['callId'] as String?
        : null;
    switch (method) {
      case 'incomingCall':
        // 来电登记：仅呈现与提醒，绝不触发接听。
        arbiter.registerIncoming(callId);
        onPresentIncoming();
        return true;
      case 'callAccepted':
        await answerFromUser(callId);
        return true;
      case 'callRejected':
        if (!arbiter.matchesPresentation(callId)) return true;
        await rejectFromUser();
        return true;
      case 'callEnded':
        arbiter.registerEnded(callId);
        return true;
    }
    return true;
  }

  /// 用户明确接听：只对当前响铃通话执行一次 accept；响铃未同步到则
  /// 登记绑定式待接听（[NativeCallArbiter]；有期限与取消条件）。
  Future<void> answerFromUser(String? nativeCallId) async {
    if (!arbiter.matchesPresentation(nativeCallId)) return;
    switch (calls.state.phase) {
      case CallPhase.ringing:
        if (_accepting) return;
        // 直接接听即视为消费了任何待接听请求（含绑定的呈现标识）。
        arbiter.consumePendingAnswer();
        _accepting = true;
        try {
          // 权限不足保持响铃、Matrix 会话失效转入 failed；不假定接通成功。
          await calls.accept();
        } finally {
          _accepting = false;
        }
      case CallPhase.connecting:
      case CallPhase.connected:
      case CallPhase.requestingPermission:
        // 接听处理中/已接通（重复点击、双通道）：仅恢复呈现，不重复接听。
        break;
      case CallPhase.idle:
      case CallPhase.ended:
      case CallPhase.failed:
      case CallPhase.permissionDenied:
        arbiter.requestAnswer(nativeCallId);
    }
    onPresentIncoming();
    if (calls.state.phase != CallPhase.ringing) {
      onDismissNativeLayer?.call();
    }
  }

  /// 用户明确结束：响铃时拒接，正在连接或已连接时挂断。
  Future<void> rejectFromUser() async {
    if (calls.state.phase == CallPhase.ringing) {
      await calls.reject();
    } else if (calls.state.phase == CallPhase.requestingPermission ||
        calls.state.phase == CallPhase.connecting ||
        calls.state.phase == CallPhase.connected) {
      await calls.hangup();
    }
    arbiter.clear();
    onDismissNativeLayer?.call();
  }

  /// CallController 相位变化钩子（由 calls 监听器转发）：
  /// 待接听匹配消费 + 状态回报 + 终态请求作废。
  void onCallPhaseChanged() {
    final phase = calls.state.phase;
    if (phase == CallPhase.ringing && arbiter.consumePendingAnswer()) {
      // 用户已在原生层请求接听，Matrix 响铃到达即接听一次；
      // microtask 避免 notifyListeners 重入期内同步改状态。
      scheduleMicrotask(() {
        if (calls.state.phase != CallPhase.ringing || _accepting) return;
        _accepting = true;
        calls.accept().whenComplete(() => _accepting = false);
      });
    }
    if (phase == CallPhase.ended || phase == CallPhase.failed) {
      // 通话取消/接听失败：旧接听请求必须失效。
      arbiter.clear();
    }
    unawaited(_reportState(phase));
  }

  Future<void> _reportState(CallPhase phase) async {
    try {
      await channel.invoke('reportCallState', {
        'phase': phase.name,
        'video': calls.state.type == CallMediaType.video,
      });
    } catch (_) {
      // 原生层未就绪/非 Android：状态回报尽力而为，不影响通话。
    }
  }

  /// 冷启动恢复：Flutter 就绪握手。
  ///
  /// ① 通知原生业务处理器已就绪并取回暂存的用户动作（answer/reject，
  ///    含关联 callId 与动作时间；原生侧取出即标记消费，超龄在此再
  ///    校验一次后丢弃）；
  /// ② getActiveCall 权威查询核对原生呈现状态（接口的真实业务调用方）。
  Future<void> restorePendingState() async {
    try {
      final result = await channel.invoke('ready');
      _applyPendingActions(result is Map ? result['actions'] : null);
    } catch (_) {
      // 原生层不可用（iOS/桌面/引擎异常）：冷启动恢复跳过。
    }
    try {
      await channel.invoke('getActiveCall');
    } catch (_) {
      // 查询失败不阻塞恢复。
    }
  }

  void _applyPendingActions(Object? actions) {
    if (actions is! List) return;
    final now = _clock();
    for (final action in actions) {
      if (action is! Map) continue;
      final kind = action['action'];
      final callId =
          action['callId'] is String ? action['callId'] as String? : null;
      final at = action['at'] is int ? action['at'] as int : null;
      if (at != null &&
          now.difference(DateTime.fromMillisecondsSinceEpoch(at)) >
              pendingActionMaxAge) {
        continue; // 过期动作丢弃。
      }
      switch (kind) {
        case 'answer':
          scheduleMicrotask(() => answerFromUser(callId));
        case 'reject':
          scheduleMicrotask(() => handleNativeMessage('callRejected', {
                'callId': callId,
              }));
      }
    }
  }

  /// 会话结束（登出/账号变化）：作废待接听并尽力通知原生清理呈现。
  Future<void> dispose() async {
    arbiter.clear();
    _accepting = false;
    try {
      await channel.invoke('endCall');
    } catch (_) {
      // 原生层不可用时静默。
    }
  }
}
