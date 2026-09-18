import 'dart:async';

import 'package:flutter/foundation.dart';

import 'room_timeline_controller.dart';

/// 引用消息（`m.in_reply_to`）原消息的加载状态。
///
/// **绝不使用单一 `loading=true`**：失败必须能被区分成「不存在」
/// 「无权限」「网络失败」，否则 UI 只能永久显示「原消息加载中」——
/// 那正是本次修复的缺陷（距离过远的引用目标永远停在 loading）。
enum ReplyMessageStatus {
  loading,
  loaded,
  notFound,
  permissionDenied,
  networkError,
}

/// 一次引用解析的不可变结果。
@immutable
final class ReplyMessageResolution {
  const ReplyMessageResolution._(this.status, this.message);

  const ReplyMessageResolution.loading()
      : this._(ReplyMessageStatus.loading, null);

  const ReplyMessageResolution.resolved(RoomMessageViewModel message)
      : this._(ReplyMessageStatus.loaded, message);

  const ReplyMessageResolution.notFound()
      : this._(ReplyMessageStatus.notFound, null);

  const ReplyMessageResolution.permissionDenied()
      : this._(ReplyMessageStatus.permissionDenied, null);

  const ReplyMessageResolution.networkError()
      : this._(ReplyMessageStatus.networkError, null);

  /// 把解析失败映射成状态；[ReplyMessageStatus.loaded] 不是失败态。
  factory ReplyMessageResolution.failed(ReplyMessageStatus status) =>
      switch (status) {
        ReplyMessageStatus.notFound => const ReplyMessageResolution.notFound(),
        ReplyMessageStatus.permissionDenied =>
          const ReplyMessageResolution.permissionDenied(),
        ReplyMessageStatus.networkError =>
          const ReplyMessageResolution.networkError(),
        ReplyMessageStatus.loading => const ReplyMessageResolution.loading(),
        ReplyMessageStatus.loaded =>
          throw ArgumentError('loaded is not a failure state'),
      };

  final ReplyMessageStatus status;

  /// 仅在 [ReplyMessageStatus.loaded] 时非空。
  final RoomMessageViewModel? message;

  bool get isLoading => status == ReplyMessageStatus.loading;
  bool get isLoaded => status == ReplyMessageStatus.loaded;

  /// 已到达终局（成功或失败）；终局结果不会被重复请求覆盖。
  bool get isSettled => status != ReplyMessageStatus.loading;

  /// 用户可点击重试的失败态。无权限是权威判定，不提供重试。
  bool get canRetry =>
      status == ReplyMessageStatus.networkError ||
      status == ReplyMessageStatus.notFound;

  /// 引用卡片上展示的文案（成功态由调用方渲染消息摘要）。
  String get label => switch (status) {
        ReplyMessageStatus.loading => '原消息加载中…',
        ReplyMessageStatus.loaded => '',
        ReplyMessageStatus.notFound => '原消息不存在或已被删除',
        ReplyMessageStatus.permissionDenied => '无权查看原消息',
        ReplyMessageStatus.networkError => '原消息加载失败，点击重试',
      };

  @override
  bool operator ==(Object other) =>
      other is ReplyMessageResolution &&
      other.status == status &&
      identical(other.message, message);

  @override
  int get hashCode => Object.hash(status, identityHashCode(message));

  @override
  String toString() => 'ReplyMessageResolution(${status.name})';
}

/// 解析结果的默认展示文案，供无解析状态的历史调用点复用。
const String replyMessageLoadingLabel = '原消息加载中…';

/// `原文` 引用卡片的加载/重试编排：单飞、超时、缓存、终局去重。
///
/// 设计约束：
/// - **单飞**：同一 `eventId` 并发请求共享同一个 future，关闭 N 行同时
///   渲染同一条引用的重复请求；
/// - **超时**：默认 3 秒后进入可重试的失败态，绝不无限 loading；
/// - **终局缓存**：成功/失败都记住，重复 `resolve` 不产生新请求；
/// - **不吞异常**：只把 [Exception] 归类成用户可见的失败态并发布，
///   编程错误（[Error]）继续抛出，不会被伪装成“加载失败”。
final class ReplyMessageResolver {
  ReplyMessageResolver({
    required this.lookup,
    this.timeout = const Duration(seconds: 3),
    this.onChanged,
    this.maxEntries = 200,
  });

  /// 按 event_id 解析消息；返回 null = 服务端权威确认不存在。
  /// 抛 [ReplyMessageLookupDenied] = 无权限；其余异常按网络失败处理。
  final Future<RoomMessageViewModel?> Function(String eventId) lookup;

  final Duration timeout;
  final VoidCallback? onChanged;

  /// 终局状态缓存上限（LRU，仅淘汰终局项，不淘汰进行中的请求）。
  final int maxEntries;

  final _states = <String, ReplyMessageResolution>{};
  final _inflight = <String, Future<ReplyMessageResolution>>{};
  final _generations = <String, int>{};
  bool _disposed = false;

  @visibleForTesting
  bool get isDisposed => _disposed;

  /// 当前已知状态；从未请求过时返回 null（调用方决定是否发起请求）。
  ReplyMessageResolution? stateOf(String eventId) =>
      _inflight.containsKey(eventId)
          ? const ReplyMessageResolution.loading()
          : _states[eventId];

  bool get hasPendingWork => _inflight.isNotEmpty;

  /// 请求解析；已有终局结果或进行中的请求时直接复用。
  Future<ReplyMessageResolution> resolve(String eventId,
      {RoomMessageViewModel? local}) {
    if (eventId.isEmpty || _disposed) {
      return Future.value(const ReplyMessageResolution.notFound());
    }
    if (local != null) {
      return Future.value(_settle(eventId, ReplyMessageResolution.resolved(local)));
    }
    final inflight = _inflight[eventId];
    if (inflight != null) return inflight;
    final settled = _states[eventId];
    if (settled != null && settled.isSettled) return Future.value(settled);
    return _start(eventId);
  }

  /// 忽略已有终局结果重新解析（引用卡片点击重试）。
  Future<ReplyMessageResolution> retry(String eventId) {
    if (eventId.isEmpty || _disposed) {
      return Future.value(const ReplyMessageResolution.notFound());
    }
    _states.remove(eventId);
    // 让在途的旧请求失效，并允许本次立刻发起新请求。
    _generations[eventId] = (_generations[eventId] ?? 0) + 1;
    _inflight.remove(eventId);
    return _start(eventId);
  }

  void forget(String eventId) {
    _states.remove(eventId);
    _inflight.remove(eventId);
    _generations[eventId] = (_generations[eventId] ?? 0) + 1;
  }

  void clear() {
    _states.clear();
    _inflight.clear();
    _generations.clear();
  }

  void dispose() {
    _disposed = true;
    _states.clear();
    _inflight.clear();
    _generations.clear();
  }

  Future<ReplyMessageResolution> _start(String eventId) {
    final generation = (_generations[eventId] ?? 0) + 1;
    _generations[eventId] = generation;
    final completer = Completer<ReplyMessageResolution>();
    final future = completer.future;
    _inflight[eventId] = future;
    _publish();
    _execute(eventId, generation).then((value) {
      if (identical(_inflight[eventId], future)) _inflight.remove(eventId);
      if (!completer.isCompleted) completer.complete(value);
    }, onError: (Object error, StackTrace stack) {
      if (identical(_inflight[eventId], future)) _inflight.remove(eventId);
      if (!completer.isCompleted) completer.completeError(error, stack);
    });
    return future;
  }

  Future<ReplyMessageResolution> _execute(String eventId, int generation) async {
    ReplyMessageResolution next;
    try {
      final message = await lookup(eventId).timeout(timeout);
      next = message == null
          ? const ReplyMessageResolution.notFound()
          : ReplyMessageResolution.resolved(message);
    } on ReplyMessageLookupDenied {
      next = const ReplyMessageResolution.permissionDenied();
    } on ReplyMessageLookupUnavailable {
      next = const ReplyMessageResolution.networkError();
    } on TimeoutException {
      next = const ReplyMessageResolution.networkError();
    } on StateError {
      // 本仓库用 StateError 表达「会话/租约暂时不可用」（例如 SDK 能力被
      // dispose、房间租约正在轮换）：这是可重试的暂时失败，而不是编程错误。
      next = const ReplyMessageResolution.networkError();
    } on Exception {
      // 归类为“可重试的网络失败”并**发布**（不是静默吞掉）：调用方与
      // 用户都能看到失败与重试入口。其它 Error（真正的编程错误，例如
      // TypeError/ArgumentError）继续向上抛，不会被伪装成加载失败。
      next = const ReplyMessageResolution.networkError();
    }
    if (_disposed || _generations[eventId] != generation) return next;
    return _settle(eventId, next);
  }

  ReplyMessageResolution _settle(String eventId, ReplyMessageResolution value) {
    if (_disposed) return value;
    if (value.isSettled) {
      _states.remove(eventId);
      _states[eventId] = value;
      _trim();
    }
    _publish();
    return value;
  }

  /// 终局缓存有界：只淘汰最早的终局项，进行中的请求不受影响。
  void _trim() {
    if (_states.length <= maxEntries) return;
    final excess = _states.length - maxEntries;
    final stale = _states.keys.take(excess).toList(growable: false);
    for (final id in stale) {
      if (_inflight.containsKey(id)) continue;
      _states.remove(id);
    }
  }

  /// 状态变化回调（调用方据此重建引用卡片）。永不吞掉状态：
  /// loading 与每个终局态都会通知一次。
  void _publish() {
    if (_disposed) return;
    onChanged?.call();
  }
}
