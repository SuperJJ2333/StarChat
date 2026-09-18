import 'dart:async';
import 'dart:io';

import 'room_navigation_coordinator.dart';
import 'room_visibility_policy.dart';

/// 打开会话的失败分类（**唯一**失败模型）。
///
/// 为什么需要它：审计发现打开路径上存在 `catch (_) {}`——通知/推送/搜索在
/// 离线时最长等待 10–12 秒后**静默放弃**，用户看到的是"点了没反应"。
/// 打开失败必须是一个**有类型、可分类、可翻译成用户文案**的对象。
enum RoomOpenFailureKind {
  /// 设备/传输离线（无网络连接）。
  offline,

  /// 网络不可达或超时（有网络但服务/同步没回应）。
  networkUnavailable,

  /// 无权打开（例如账号已撤销、非成员且不可自动加入）。
  permissionDenied,

  /// 房间不存在：本地与远端都没有，或该房间不可打开（控制房间 fail-closed）。
  roomNotFound,

  /// 房间存在但当前账号尚未加入，且本入口不允许自动入群。
  notJoined,

  /// 其它可重试的临时失败（未知异常、租约/路由失败）。
  temporaryFailure,
}

/// 一次打开失败的**用户可见**结果。
///
/// [userMessage] 是唯一允许展示给用户的文案来源：所有入口统一使用它，
/// 不允许各入口自造文案或静默吞掉异常。
final class RoomOpenFailure implements Exception {
  const RoomOpenFailure(
    this.kind, {
    required this.roomId,
    required this.source,
    this.cause,
  });

  final RoomOpenFailureKind kind;
  final String roomId;
  final RoomOpenSource source;

  /// 原始异常（只用于诊断，不展示给用户）。
  final Object? cause;

  /// 用户可见文案（禁止包含房间内容、成员、消息等敏感情报）。
  String get userMessage => switch (kind) {
        RoomOpenFailureKind.offline ||
        RoomOpenFailureKind.networkUnavailable =>
          '网络不可用，请稍后重试',
        RoomOpenFailureKind.permissionDenied => '无法打开该会话',
        RoomOpenFailureKind.roomNotFound => '会话不存在或已被删除',
        RoomOpenFailureKind.notJoined => '尚未加入该会话，请稍后重试',
        RoomOpenFailureKind.temporaryFailure => '无法打开会话，请检查网络',
      };

  /// 是否值得让用户重试（"重试"按钮据此显示）。
  bool get isRetryable => switch (kind) {
        RoomOpenFailureKind.offline ||
        RoomOpenFailureKind.networkUnavailable ||
        RoomOpenFailureKind.temporaryFailure =>
          true,
        RoomOpenFailureKind.permissionDenied ||
        RoomOpenFailureKind.roomNotFound ||
        RoomOpenFailureKind.notJoined =>
          false,
      };

  @override
  String toString() =>
      'RoomOpenFailure(${kind.name}, source=${source.wireName}, room=$roomId'
      '${cause == null ? '' : ', cause=${cause.runtimeType}'})';
}

/// 打开前的**本地事实**探针：只读、零网络、同步。
///
/// 实现必须只读本机 SDK store 与 accountData，绝不触发 `/sync`、
/// `waitForRoomInSync`、`/members` 等网络调用——这是"离线优先"的前提。
abstract interface class RoomOpenLocalProbe {
  /// 本地 SDK store 是否已知该房间（任意 membership）。
  bool knowsRoom(String roomId);

  /// 本地 SDK store 中该房间是否为我方已加入。
  bool isJoined(String roomId);

  /// accountData 引用的控制房间 roomId（账号级系统房间）。
  Set<String> get controlRoomIds;
}

/// 兜底探针：一切未知、无控制房间。用于测试与"矩阵尚未就绪"的场景。
final class UnknownRoomOpenLocalProbe implements RoomOpenLocalProbe {
  const UnknownRoomOpenLocalProbe();

  @override
  bool knowsRoom(String roomId) => false;

  @override
  bool isJoined(String roomId) => false;

  @override
  Set<String> get controlRoomIds => const <String>{};
}

/// 策略判定结果。
enum RoomOpenDecision {
  /// 可以立即打开（本地已加入）。
  openNow,

  /// 需要一次**有界**的本地房间等待（本地未加入/未知，但入口允许等）。
  awaitLocalRoom,

  /// 拒绝打开（终态，携带失败原因）。
  deny,
}

/// 策略判定（纯数据，便于测试断言与诊断）。
final class RoomOpenVerdict {
  const RoomOpenVerdict._(this.decision, this.reason, [this.failure]);

  const RoomOpenVerdict.openNow(String reason)
      : this._(RoomOpenDecision.openNow, reason);

  const RoomOpenVerdict.awaitLocalRoom(String reason)
      : this._(RoomOpenDecision.awaitLocalRoom, reason);

  const RoomOpenVerdict.deny(RoomOpenFailure failure, String reason)
      : this._(RoomOpenDecision.deny, reason, failure);

  final RoomOpenDecision decision;

  /// 稳定、可断言的判定原因（无用户内容）。
  final String reason;

  /// 仅当 [decision] == deny 时非空。
  final RoomOpenFailure? failure;

  @override
  String toString() => 'RoomOpenVerdict(${decision.name}, $reason)';
}

/// 诊断阶段（供日志/埋点使用；不含消息内容）。
enum RoomOpenOutcome { openedLocal, openedAfterWait, denied, failed }

/// 打开诊断事件。roomId 是 Matrix 不透明房间号（与既有通知诊断同源）。
final class RoomOpenDiagnostic {
  const RoomOpenDiagnostic({
    required this.source,
    required this.mode,
    required this.roomId,
    required this.outcome,
    required this.reason,
    this.failureKind,
  });

  final RoomOpenSource source;
  final RoomOpenMode mode;
  final String roomId;
  final RoomOpenOutcome outcome;
  final String reason;
  final RoomOpenFailureKind? failureKind;

  String get line => 'room-open source=${source.wireName} mode=${mode.name} '
      'outcome=${outcome.name} reason=$reason room=$roomId'
      '${failureKind == null ? '' : ' failure=${failureKind!.name}'}';
}

/// **Room Opening Policy Engine**：所有入口进入
/// `RoomNavigationCoordinator` **之前**的统一策略层。
///
/// 职责边界（严格）：
/// - ✅ 打开前判定：来源/网络姿态、本地 joined 事实、可见性、失败分类；
/// - ✅ 有界网络等待的**编排**（等待函数由组合根注入）；
/// - ❌ 不创建页面、不取/释放租约、不做导航去重（仍归
///   `RoomNavigationCoordinator`）；
/// - ❌ 不发起 Matrix/业务请求（等待函数由组合根注入，便于测试与替换）。
///
/// 调用形态（组合根只写一次）：
/// ```dart
/// await policy.open(
///   request,
///   navigate: coordinator.open,
///   awaitLocalRoom: awaitRoomLocally,
/// );
/// ```
final class RoomOpeningPolicy {
  RoomOpeningPolicy({required this.probe, this.diagnostics});

  final RoomOpenLocalProbe probe;

  /// 诊断出口（可选）。只写入口来源/网络姿态/结果原因，不写消息内容。
  final void Function(RoomOpenDiagnostic diagnostic)? diagnostics;

  /// 当前可见性策略（每次判定都从本地 accountData 事实重建，避免缓存过期）。
  RoomVisibilityPolicy get visibility =>
      RoomVisibilityPolicy.forRoomIds(probe.controlRoomIds);

  /// 纯判定：不做 I/O、不创建页面、不管理租约。
  ///
  /// 规则（离线优先铁律）：
  /// - 空 roomId → [RoomOpenFailureKind.roomNotFound]；
  /// - 控制房间（accountData 引用）→ [RoomOpenFailureKind.roomNotFound]
  ///   （fail-closed，且不泄露内部房间是否存在）；
  /// - 本地已加入 → **立即打开**（三种模式一致，绝不等待网络）；
  /// - 本地已知但未加入：
  ///   - [RoomOpenMode.requireNetwork] → 拒绝（前提不成立）；
  ///   - 其余 → 有界等待；
  /// - 本地未知：
  ///   - [RoomOpenMode.requireNetwork] → 拒绝；
  ///   - [RoomOpenMode.offlineFirst] / [RoomOpenMode.localThenNetwork] →
  ///     有界等待（"只有本地不存在，才允许 network fallback"）。
  RoomOpenVerdict evaluate(RoomOpenRequest request) {
    final roomId = request.roomId.trim();
    if (roomId.isEmpty) {
      return RoomOpenVerdict.deny(
        RoomOpenFailure(
          RoomOpenFailureKind.roomNotFound,
          roomId: '',
          source: request.source,
        ),
        'empty_room_id',
      );
    }
    if (!visibility.isOpenable(roomId)) {
      return RoomOpenVerdict.deny(
        RoomOpenFailure(
          RoomOpenFailureKind.roomNotFound,
          roomId: roomId,
          source: request.source,
        ),
        'hidden_control_room',
      );
    }
    if (probe.isJoined(roomId)) {
      return const RoomOpenVerdict.openNow('local_joined');
    }
    final known = probe.knowsRoom(roomId);
    if (request.mode == RoomOpenMode.requireNetwork) {
      return RoomOpenVerdict.deny(
        RoomOpenFailure(
          RoomOpenFailureKind.notJoined,
          roomId: roomId,
          source: request.source,
        ),
        known ? 'local_not_joined' : 'local_missing_requires_network',
      );
    }
    return RoomOpenVerdict.awaitLocalRoom(
        known ? 'local_not_joined' : 'local_missing');
  }

  /// 统一打开：判定 →（必要时）有界等待 → 委托导航。
  ///
  /// 任何失败都以 [RoomOpenFailure] 抛出（**绝不静默**），由组合根统一
  /// 转成用户可见提示。成功时 `navigate` 的 future 在页面关闭后完成。
  Future<void> open(
    RoomOpenRequest request, {
    required Future<void> Function(RoomOpenRequest request) navigate,
    Future<bool> Function(String roomId)? awaitLocalRoom,
  }) async {
    final verdict = evaluate(request);
    switch (verdict.decision) {
      case RoomOpenDecision.deny:
        final failure = verdict.failure!;
        _report(request, RoomOpenOutcome.denied, verdict.reason,
            failureKind: failure.kind);
        throw failure;
      case RoomOpenDecision.openNow:
        _report(request, RoomOpenOutcome.openedLocal, verdict.reason);
        await _navigate(request, navigate);
      case RoomOpenDecision.awaitLocalRoom:
        final waiter = awaitLocalRoom;
        if (waiter == null) {
          // 入口允许等待但没有提供等待能力：按可重试失败处理，绝不静默。
          final failure = RoomOpenFailure(
            RoomOpenFailureKind.temporaryFailure,
            roomId: request.roomId.trim(),
            source: request.source,
          );
          _report(request, RoomOpenOutcome.failed, 'no_await_capability',
              failureKind: failure.kind);
          throw failure;
        }
        final ready = await _awaitLocalRoom(request, waiter);
        if (!ready) {
          final failure = RoomOpenFailure(
            RoomOpenFailureKind.temporaryFailure,
            roomId: request.roomId.trim(),
            source: request.source,
          );
          _report(request, RoomOpenOutcome.failed, 'local_room_timeout',
              failureKind: failure.kind);
          throw failure;
        }
        _report(request, RoomOpenOutcome.openedAfterWait, verdict.reason);
        await _navigate(request, navigate);
    }
  }

  Future<bool> _awaitLocalRoom(
    RoomOpenRequest request,
    Future<bool> Function(String roomId) waiter,
  ) async {
    try {
      return await waiter(request.roomId.trim());
    } on RoomOpenFailure {
      rethrow;
    } catch (error) {
      throw classify(error, request);
    }
  }

  Future<void> _navigate(
    RoomOpenRequest request,
    Future<void> Function(RoomOpenRequest request) navigate,
  ) async {
    try {
      await navigate(request);
    } on RoomOpenFailure {
      rethrow;
    } catch (error) {
      final failure = classify(error, request);
      _report(request, RoomOpenOutcome.failed, 'navigate_failed',
          failureKind: failure.kind);
      throw failure;
    }
  }

  /// 把任意异常映射为失败分类（本地打开失败同样是可见失败，不静默）。
  RoomOpenFailure classify(
    Object error,
    RoomOpenRequest request, {
    RoomOpenFailureKind fallback = RoomOpenFailureKind.temporaryFailure,
  }) {
    if (error is RoomOpenFailure) return error;
    final kind = switch (error) {
      TimeoutException() => RoomOpenFailureKind.networkUnavailable,
      SocketException() => RoomOpenFailureKind.offline,
      HttpException() => RoomOpenFailureKind.offline,
      _ => _classifyByMessage(error, fallback),
    };
    return RoomOpenFailure(kind,
        roomId: request.roomId.trim(), source: request.source, cause: error);
  }

  static RoomOpenFailureKind _classifyByMessage(
    Object error,
    RoomOpenFailureKind fallback,
  ) {
    if (error is StateError) {
      final message = error.message.toLowerCase();
      if (message.contains('unavailable') ||
          message.contains('不存在') ||
          message.contains('not found')) {
        return RoomOpenFailureKind.roomNotFound;
      }
      if (message.contains('not joined') || message.contains('尚未加入')) {
        return RoomOpenFailureKind.notJoined;
      }
      if (message.contains('access') ||
          message.contains('revoked') ||
          message.contains('permission')) {
        return RoomOpenFailureKind.permissionDenied;
      }
    }
    return fallback;
  }

  void _report(
    RoomOpenRequest request,
    RoomOpenOutcome outcome,
    String reason, {
    RoomOpenFailureKind? failureKind,
  }) {
    diagnostics?.call(RoomOpenDiagnostic(
      source: request.source,
      mode: request.mode,
      roomId: request.roomId.trim(),
      outcome: outcome,
      reason: reason,
      failureKind: failureKind,
    ));
  }
}
