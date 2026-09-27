import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 产品级网络状态（与 Matrix、HTTP、账号完全无关）。
///
/// Business-level network quality. It deliberately knows nothing about Matrix,
/// business APIs, accounts, or retry mechanisms, so any layer may report into
/// it and observe it.
enum NetworkState {
  /// 请求正常且往返延迟可接受。
  online,

  /// 请求仍能成功，但往返延迟偏高，或出现了单次网络失败。
  weak,

  /// 传输层不可用，或连续多次网络失败且中间没有成功。
  offline,

  /// 进入离线后正在重试（由 `report(recovering: true)` 显式上报）。
  recovering,
}

/// 判定一个错误是否算"网络失败"的注入点。
///
/// Injection point for failure classification. A classifier must return false
/// for business/protocol errors (for example HTTP 400 + JSON body), which must
/// never degrade connectivity state.
typedef NetworkFailureClassifier = bool Function(Object error);

/// 「消息确认因网络原因未发出」的类型化异常（2026-09-19 房间瘫痪修复）。
///
/// Compatibility for adapters returning no acknowledgement. The production
/// SDK preserves its actual protocol/transport exception instead of returning
/// null on failure. An absent acknowledgement remains retryable with its txid.
final class MessageSendNetworkException implements Exception {
  const MessageSendNetworkException(this.message);
  final String message;
  @override
  String toString() => 'MessageSendNetworkException: $message';
}

/// 默认分类器：SocketException / TimeoutException / HttpException /
/// package:http 的 ClientException / HTTP 429/5xx / [MessageSendNetworkException]。
///
/// 该默认实现刻意不导入 `package:http`：`ClientException` 通过运行时类型名
/// 识别，HTTP响应读取statusCode或response.statusCode。429/5xx可重试，
/// 但reportFailure不会据此把设备判离线。需要更精确的判定时自行注入
/// [NetworkFailureClassifier]。
bool defaultNetworkFailureClassifier(Object error) {
  if (error is SocketException) return true; // DNS/连接/重置失败
  if (error is TimeoutException) return true; // 请求超时
  if (error is HttpException) return true; // 连接中途被关闭
  if (error is MessageSendNetworkException) return true; // 发送重试耗尽
  final status = networkFailureHttpStatus(error);
  if (status != null) return status == 429 || (status >= 500 && status < 600);
  return error.runtimeType.toString() == 'ClientException';
}

/// HTTP responses are retry evidence, not evidence that the device is offline.
int? networkFailureHttpStatus(Object error) {
  try {
    final dynamic candidate = error;
    final Object? status = candidate.statusCode;
    if (status is int) return status;
  } catch (_) {
    // 没有 statusCode 的属性即视为非 HTTP 错误。
  }
  try {
    final dynamic candidate = error;
    final Object? status = candidate.response?.statusCode;
    if (status is int) return status;
  } catch (_) {}
  return null;
}

bool isRetryableServerFailure(Object error) {
  final status = networkFailureHttpStatus(error);
  return status == 429 || (status != null && status >= 500 && status < 600);
}

/// 产品级网络状态机。
///
/// 只回答"当前网络好不好"这一件事：不订阅数据源、不发起请求、不创建任何
/// 定时器。所有变化都由上层调用 [report] / [reportFailure] / [reportSuccess]
/// 上报驱动，因此本文件可被 Matrix、业务 API、同步看门狗等任意层导入。
///
/// 判定优先级（自上而下）：
/// 1. 显式 `recovering: true` 且尚未被成功/失败上报关闭；
/// 2. 传输层显式不可用（`transportAvailable: false`）；
/// 3. 连续网络失败次数 >= [offlineFailureStreak]；
/// 4. 单次网络失败，或往返延迟 > [weakRoundTripThreshold]；
/// 5. 否则 [NetworkState.online]。
///
/// 状态迁移幂等：值不变时不通知监听者。一次成功请求即证明传输层可用，因此
/// [reportSuccess] / `serverReachable: true` 会把传输层事实翻回可用；同一次
/// [report] 里显式传入的 `transportAvailable` 仍然优先。反之，失败不会自行
/// 判定传输层不可用——连续失败由计数阈值升级为离线。
final class NetworkStateManager {
  NetworkStateManager({
    this.weakRoundTripThreshold = const Duration(seconds: 2),
    this.offlineFailureStreak = 2,
    NetworkFailureClassifier? classifyFailure,
  })  : assert(weakRoundTripThreshold > Duration.zero),
        assert(offlineFailureStreak >= 2),
        _classifyFailure = classifyFailure ?? defaultNetworkFailureClassifier;

  /// 组合根写入的进程级实例；测试与纯逻辑层可以保持 null。
  static NetworkStateManager? shared;

  /// 成功但往返耗时超过该阈值即判为 [NetworkState.weak]。
  final Duration weakRoundTripThreshold;

  /// 连续网络失败达到该次数（>=2）即判为 [NetworkState.offline]。
  final int offlineFailureStreak;

  final NetworkFailureClassifier _classifyFailure;

  final ValueNotifier<NetworkState> _state =
      ValueNotifier<NetworkState>(NetworkState.online);
  final List<Completer<void>> _whenOnlineWaiters = <Completer<void>>[];
  int _failures = 0;
  bool? _transportAvailable;
  bool? _serviceReachable;
  Duration? _lastRoundTrip;
  bool _recovering = false;
  bool _disposed = false;

  /// 当前网络状态；只在真正变化时通知监听者。
  ValueListenable<NetworkState> get state => _state;

  /// [state] 的当前值。
  NetworkState get current => _state.value;

  /// Last explicitly observed transport fact. Null means no current evidence.
  bool? get transportAvailable => _transportAvailable;

  /// Last reachability signal for the service bound by the composition root
  /// (currently Matrix). Null means it has not been observed, or a later
  /// transport outage invalidated it. The Matrix connection phase is still a
  /// separate signal; Business API traces use their own HTTP response facts.
  bool? get serviceReachable => _serviceReachable;

  /// 上报一次观测事实。
  ///
  /// - [transportAvailable]：传输层是否可用（只在显式传入时更新，且优先于
  ///   同一次调用里的成功上报）；
  /// - [serverReachable]：调用方目标服务本次是否可达（true 等价于一次成功，并证明
  ///   传输层可用）；
  /// - [recovering]：是否正在重试（true 覆盖离线/失败事实，直到下一次成功
  ///   或失败上报关闭它）；
  /// - [lastRoundTrip]：本次成功请求的往返耗时；未传即视为未测量并清空旧值。
  void report({
    bool? transportAvailable,
    bool? serverReachable,
    bool? recovering,
    Duration? lastRoundTrip,
  }) {
    if (_disposed) return;
    final transportReported = transportAvailable != null;
    if (transportReported) {
      _transportAvailable = transportAvailable;
      if (transportAvailable == false) _serviceReachable = null;
    }
    if (recovering != null) _recovering = recovering;
    if (serverReachable != null) {
      _serviceReachable = serverReachable;
      if (serverReachable) {
        // 一次完成的上报比在途标记更可信，同时证明传输层可用。
        _clearFailures(roundTrip: lastRoundTrip);
        if (!transportReported) _transportAvailable = true;
      } else {
        _failures++;
        _recovering = false;
      }
    } else if (lastRoundTrip != null) {
      _lastRoundTrip = lastRoundTrip;
    }
    _refresh();
  }

  /// 上报一次网络异常；非网络类错误（[defaultNetworkFailureClassifier] 返回
  /// false，或注入的分类器返回 false）不改变任何状态。
  void reportFailure(Object error) {
    if (_disposed) return;
    // A response proves the endpoint answered. Backoff belongs to the failed
    // operation; it must not pause unrelated rooms through a global offline flag.
    if (networkFailureHttpStatus(error) != null) {
      _serviceReachable = true;
      return;
    }
    if (!_classifyFailure(error)) return;
    _serviceReachable = false;
    _failures++;
    _recovering = false;
    _refresh();
  }

  /// 上报一次成功请求/同步：清空失败连续计数与 recovering 标记，并把传输层
  /// 事实翻回可用（成功即证明链路通）。
  void reportSuccess({Duration? roundTrip}) {
    if (_disposed) return;
    _clearFailures(roundTrip: roundTrip);
    _transportAvailable = true;
    _serviceReachable = true;
    _refresh();
  }

  /// 等待恢复。
  ///
  /// 已经 [NetworkState.online] 或 [NetworkState.recovering] 时立即完成；否则
  /// 在下一次进入 online/recovering 时完成。等待者由 [report] /
  /// [reportFailure] / [reportSuccess] 驱动，不创建任何定时器（无轮询），
  /// [dispose] 时会全部完成以免悬挂。
  Future<void> whenOnline() {
    if (_disposed) return Future<void>.value();
    if (_isRecovered) return Future<void>.value();
    final waiter = Completer<void>();
    _whenOnlineWaiters.add(waiter);
    return waiter.future;
  }

  /// 回到初始 [NetworkState.online]，清空失败计数、延迟测量、recovering 标记
  /// 与全部等待者（例如退出登录后重置会话级判定）。
  void reset() {
    if (_disposed) return;
    _failures = 0;
    _transportAvailable = null;
    _serviceReachable = null;
    _lastRoundTrip = null;
    _recovering = false;
    _set(NetworkState.online);
  }

  /// 释放资源；可重复调用，之后所有上报与等待均为安全空操作。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _completeWaiters();
    _state.dispose();
  }

  bool get _isRecovered =>
      _state.value == NetworkState.online ||
      _state.value == NetworkState.recovering;

  void _clearFailures({Duration? roundTrip}) {
    _failures = 0;
    _recovering = false;
    _lastRoundTrip = roundTrip;
  }

  void _refresh() => _set(_evaluate());

  NetworkState _evaluate() {
    if (_recovering) return NetworkState.recovering;
    if (_transportAvailable == false) return NetworkState.offline;
    if (_failures >= offlineFailureStreak) return NetworkState.offline;
    if (_failures > 0) return NetworkState.weak;
    final roundTrip = _lastRoundTrip;
    if (roundTrip != null && roundTrip > weakRoundTripThreshold) {
      return NetworkState.weak;
    }
    return NetworkState.online;
  }

  void _set(NetworkState next) {
    if (_disposed || _state.value == next) return;
    _state.value = next;
    if (_isRecovered) _completeWaiters();
  }

  void _completeWaiters() {
    if (_whenOnlineWaiters.isEmpty) return;
    final waiters = List<Completer<void>>.of(_whenOnlineWaiters);
    _whenOnlineWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }
}
