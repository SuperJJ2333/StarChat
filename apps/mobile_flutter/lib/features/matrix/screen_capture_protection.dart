import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 屏幕捕获保护服务（Task E）。
///
/// 平台能力边界（不夸大）：
/// - **Android**：`WindowManager.LayoutParams.FLAG_SECURE` 可阻止系统截图、
///   普通录屏与最近任务预览快照；原生侧按 **lease 引用计数** 开关，
///   count > 0 时保持开启，归零才清除（防止多查看器互相误关）。
/// - **iOS**：第三方 App **没有**官方等价的通用截图阻止 API。这里只做
///   两件事：① 通过 `UIScreen.isCaptured` / scene capture state 上报
///   「正在录屏或镜像」状态（用于禁止 reveal）；② 监听
///   `UIApplication.userDidTakeScreenshot`——该通知在系统截图**完成之后**
///   才触发，因此只能做“截图后立即销毁闪照”的补救，**不能声称阻止截图**。
///
/// 不涉及：相册权限、扫描/删除用户截图、上传任何内容。
final class ScreenCaptureLease {
  ScreenCaptureLease._(this._owner, this.token);

  final ScreenCaptureProtection _owner;
  final Object token;
  bool _released = false;

  /// 释放租约；重复调用安全（幂等，不会让原生计数变负）。
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _owner._releaseToken(token);
  }
}

/// 平台安全窗口开关（可注入，测试用假实现）。
typedef ScreenSecurityInvoker = Future<void> Function(String method);

final class ScreenCaptureProtection {
  ScreenCaptureProtection({
    ScreenSecurityInvoker? invoker,
    Stream<Object?>? captureEvents,
  })  : _invoker = invoker ?? _platformInvoke,
        _captureEvents = captureEvents {
    _captureSubscription = _captureEvents?.listen(_onPlatformEvent);
  }

  /// 生产单例（首次访问时创建；测试可用 [debugOverride] 替换）。
  static ScreenCaptureProtection? _instance;
  static ScreenCaptureProtection get instance =>
      _instance ??= ScreenCaptureProtection(
        captureEvents: const EventChannel('chatflow/screen_capture')
            .receiveBroadcastStream()
            .map<Object?>((event) => event),
      );

  @visibleForTesting
  static set debugOverride(ScreenCaptureProtection? value) =>
      _instance = value;

  static const MethodChannel _methodChannel =
      MethodChannel('chatflow/screen_security');

  static Future<void> _platformInvoke(String method) async {
    try {
      await _methodChannel.invokeMethod<void>(method);
    } catch (_) {
      // 平台不支持/通道不可用时静默降级：安全能力缺失不得让 UI 崩溃。
    }
  }

  final ScreenSecurityInvoker _invoker;
  final Stream<Object?>? _captureEvents;
  StreamSubscription<Object?>? _captureSubscription;
  final Set<Object> _tokens = <Object>{};
  final ValueNotifier<bool> _captureActive = ValueNotifier<bool>(false);
  final StreamController<void> _screenshots = StreamController<void>.broadcast();
  bool _disposed = false;

  /// 平台调用一律失败静默：安全能力缺失不得让 UI 崩溃或抛异常。
  Future<void> _safeInvoke(String method) async {
    try {
      await _invoker(method);
    } catch (_) {}
  }

  /// 当前生效的安全窗口租约数（> 0 表示原生 FLAG_SECURE 已开启）。
  @visibleForTesting
  int get leaseCount => _tokens.length;

  /// 是否正在录屏/镜像（iOS 上报；Android 由 FLAG_SECURE 从源头阻断）。
  ValueListenable<bool> get captureActive => _captureActive;

  /// iOS 系统截图**完成之后**的通知流（用于立即销毁闪照的补救动作）。
  Stream<void> get screenshots => _screenshots.stream;

  /// 申请安全窗口租约：第一个租约开启，后续租约只增加计数。
  Future<ScreenCaptureLease> acquire() async {
    final token = Object();
    _tokens.add(token);
    if (_tokens.length == 1) {
      await _safeInvoke('acquireSecure');
    }
    return ScreenCaptureLease._(this, token);
  }

  Future<void> _releaseToken(Object token) async {
    if (!_tokens.remove(token)) return; // 重复释放：不影响计数
    if (_tokens.isEmpty) {
      await _safeInvoke('releaseSecure');
    }
  }

  /// 账号切换/异常兜底：释放全部租约。
  Future<void> releaseAll() async {
    if (_tokens.isEmpty) return;
    _tokens.clear();
    await _safeInvoke('releaseSecure');
  }

  /// 重申安全窗口（Android Activity 重建/回前台后 FLAG_SECURE 可能丢失，
  /// 计数不变，只重新应用当前状态）。
  Future<void> reassert() async {
    if (_tokens.isEmpty || _disposed) return;
    await _safeInvoke('reassertSecure');
  }

  void _onPlatformEvent(Object? event) {
    if (_disposed || event is! Map) return;
    switch (event['type']) {
      case 'captureState':
        _captureActive.value = event['active'] == true;
      case 'screenshot':
        // 系统截图已完成：仅能作为“事后销毁”信号，绝不声称阻止截图。
        if (!_screenshots.isClosed) _screenshots.add(null);
    }
  }

  @visibleForTesting
  void emitCaptureStateForTest(bool active) =>
      _onPlatformEvent({'type': 'captureState', 'active': active});

  @visibleForTesting
  void emitScreenshotForTest() => _onPlatformEvent({'type': 'screenshot'});

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _captureSubscription?.cancel();
    _captureSubscription = null;
    _tokens.clear();
    _captureActive.dispose();
    await _screenshots.close();
  }
}
