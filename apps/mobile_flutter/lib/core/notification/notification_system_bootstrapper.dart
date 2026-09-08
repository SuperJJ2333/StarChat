import 'dart:async';

import 'notification_diagnostics.dart';

/// 登录会话内通知系统的唯一启动器（修复重复初始化）：
///
/// - `ensureStarted()` 以 Future 备忘录保证并发/重复调用只装配一次
///   （一个 eventSource + 一个 coordinator + 一套安装回调）；
/// - 启动失败不抛出：置 [needsRetry]，由下一次生命周期恢复重试
///   （此前 AppHome 的 catch 注释承诺了重试但并不存在）；
/// - `dispose()` 幂等清理；会话结束后不得复活旧装配。
final class NotificationSystemBootstrapper {
  NotificationSystemBootstrapper({
    required Future<void> Function() start,
    required Future<void> Function() stop,
    required void Function() onReady,
    NotificationDiagnostics? diagnostics,
  })  : _start = start,
        _stop = stop,
        _onReady = onReady,
        diagnostics = diagnostics ?? NotificationDiagnostics.shared;

  final Future<void> Function() _start;
  final Future<void> Function() _stop;
  final void Function() _onReady;
  final NotificationDiagnostics diagnostics;

  static const _tag = 'notification system';

  bool _ready = false;
  bool _disposed = false;
  bool _failed = false;
  Future<bool>? _starting;
  Future<void>? _disposing;

  bool get isReady => _ready;

  /// 上次尝试失败且尚未成功：生命周期恢复时应重试。
  bool get needsRetry => _failed && !_ready && !_disposed;

  Future<bool> ensureStarted() {
    if (_disposed) return Future.value(false);
    if (_ready) return Future.value(true);
    return _starting ??= _runStart();
  }

  Future<bool> _runStart() async {
    _failed = false;
    try {
      await Future<void>.sync(_start);
      if (_disposed) return false;
      _ready = true;
      _onReady();
      diagnostics.record(NotificationDiagStage.startup, '$_tag ready');
      return true;
    } catch (error) {
      _failed = !_disposed;
      // 只记异常类型：插件异常消息可能含路径等，且无助于分层定位。
      diagnostics.record(NotificationDiagStage.startup,
          '$_tag start failed: ${error.runtimeType}');
      return false;
    } finally {
      _starting = null;
    }
  }

  Future<void> dispose() {
    final existing = _disposing;
    if (existing != null) return existing;
    _disposed = true;
    _ready = false;
    _failed = false;
    // Capture before _runStart's finally clears the flight. Shutdown callers
    // share this drain; a late successful start cannot install its handles.
    return _disposing = _drainAndStop(_starting);
  }

  Future<void> _drainAndStop(Future<bool>? starting) async {
    // Startup errors are converted to false by _runStart. Its managed Matrix
    // operations reject revoked capabilities rather than re-entering shutdown.
    if (starting != null) await starting;
    try {
      await _stop();
    } catch (error) {
      diagnostics.record(NotificationDiagStage.startup,
          '$_tag dispose failed: ${error.runtimeType}');
    }
  }
}
