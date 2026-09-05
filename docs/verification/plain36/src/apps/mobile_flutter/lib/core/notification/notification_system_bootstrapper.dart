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
      await _start();
      _ready = true;
      _onReady();
      diagnostics.record(NotificationDiagStage.startup, '$_tag ready');
      return true;
    } catch (error) {
      _failed = true;
      // 只记异常类型：插件异常消息可能含路径等，且无助于分层定位。
      diagnostics.record(NotificationDiagStage.startup,
          '$_tag start failed: ${error.runtimeType}');
      return false;
    } finally {
      _starting = null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    _failed = false;
    _starting = null;
    try {
      await _stop();
    } catch (error) {
      diagnostics.record(NotificationDiagStage.startup,
          '$_tag dispose failed: ${error.runtimeType}');
    }
  }
}
