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
///
/// 安全不变量（fail closed）：调用方**只能**在 [ScreenCaptureProtection.canReveal]
/// 为真时 reveal 受保护内容。[ScreenProtectionReadiness.failed] 与
/// [ScreenCaptureState.unknown] 一律不得视为“安全”。

/// 安全窗口（Android FLAG_SECURE / 租约）的**就绪状态**。
///
/// - [initializing]：尚未确认安全窗口可用（初始值）——不得 reveal；
/// - [ready]：原生安全窗口通道已确认可用——是否 reveal 还要看捕获状态；
/// - [failed]：安全窗口无法启用（通道缺失/返回异常）——必须 fail closed，
///   且应向用户明确提示能力不可用，绝不能静默继续显示原图。
enum ScreenProtectionReadiness { initializing, ready, failed }

/// 屏幕捕获（录屏/镜像）状态，三态。`unknown` 必须 fail closed。
///
/// - [unknown]：还没有拿到可信状态（快照调用失败且未收到平台事件）
///   ——不得 reveal；
/// - [inactive]：已确认当前未在录屏/镜像——允许（在就绪前提下）reveal；
/// - [active]：已确认正在录屏/镜像——禁止 reveal，已在 reveal 的立即销毁。
enum ScreenCaptureState { unknown, inactive, active }

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
///
/// 生产实现**不吞异常**：通道不可用必须抛出，让 [ScreenCaptureProtection.readiness]
/// 变成 `failed`（fail closed 的判定依据）。
typedef ScreenSecurityInvoker = Future<void> Function(String method);

/// 「当前是否正在录屏/镜像」的**同步快照**调用（MethodChannel
/// `chatflow/screen_security` → `getCurrentCaptureState`）。
///
/// 返回语义：
/// - `true`：已确认正在录屏/镜像；
/// - `false`：已确认未在录屏/镜像；
/// - `null`：平台不提供该上报能力（Android：FLAG_SECURE 在源头阻断），
///   在安全窗口已确认的前提下等价于「未在捕获」；
/// - **抛异常**：状态不可知 → Dart 侧保持 `unknown`（fail closed），
///   绝不当作 `inactive`。
typedef ScreenCaptureSnapshotInvoker = Future<bool?> Function();

final class ScreenCaptureProtection {
  ScreenCaptureProtection({
    ScreenSecurityInvoker? invoker,
    Stream<Object?>? captureEvents,
    ScreenCaptureSnapshotInvoker? captureStateSnapshot,
  })  : _invoker = invoker ?? _platformInvoke,
        _captureEvents = captureEvents,
        _captureStateSnapshot = captureStateSnapshot {
    _captureSubscription = _captureEvents?.listen(_onPlatformEvent);
  }

  /// 生产单例（首次访问时创建；测试可用 [debugOverride] 替换）。
  static ScreenCaptureProtection? _instance;
  static ScreenCaptureProtection get instance {
    final existing = _instance;
    if (existing != null) return existing;
    final created = ScreenCaptureProtection(
      captureEvents: const EventChannel('chatflow/screen_capture')
          .receiveBroadcastStream()
          .map<Object?>((event) => event),
      captureStateSnapshot: _platformCaptureSnapshot,
    );
    _instance = created;
    // 服务初始化即拉一次捕获状态快照：查看器不必等第一次 EventChannel
    // 事件（设备在查看器打开前就已在录屏时，这段空窗是 fail-open 的）。
    unawaited(created.initialize());
    return created;
  }

  @visibleForTesting
  static set debugOverride(ScreenCaptureProtection? value) => _instance = value;

  static const MethodChannel _methodChannel =
      MethodChannel('chatflow/screen_security');

  /// 生产实现：**不吞异常**。原生必须回租约计数（int）；否则视为安全窗口
  /// 不可用 → readiness = failed。
  static Future<void> _platformInvoke(String method) async {
    final result = await _methodChannel.invokeMethod<Object?>(method);
    if (result is! int) {
      throw PlatformException(
        code: 'screen_security_unavailable',
        message: 'secure window channel did not return a lease count',
      );
    }
  }

  /// 同步捕获状态快照。载荷：`{'supported': bool, 'active': bool}`。
  /// 载荷形状不对 → 抛异常 → Dart 侧按 `unknown` fail closed。
  static Future<bool?> _platformCaptureSnapshot() async {
    final raw =
        await _methodChannel.invokeMethod<Object?>('getCurrentCaptureState');
    if (raw is! Map) {
      throw PlatformException(
        code: 'screen_capture_snapshot_invalid',
        message: 'capture snapshot payload was not a map',
      );
    }
    if (raw['supported'] == false) return null; // Android：无捕获上报语义
    return raw['active'] == true;
  }

  final ScreenSecurityInvoker _invoker;
  final Stream<Object?>? _captureEvents;
  final ScreenCaptureSnapshotInvoker? _captureStateSnapshot;
  StreamSubscription<Object?>? _captureSubscription;
  final Set<Object> _tokens = <Object>{};
  final ValueNotifier<ScreenProtectionReadiness> _readiness =
      ValueNotifier<ScreenProtectionReadiness>(
          ScreenProtectionReadiness.initializing);
  final ValueNotifier<ScreenCaptureState> _captureState =
      ValueNotifier<ScreenCaptureState>(ScreenCaptureState.unknown);
  final ValueNotifier<bool> _captureActive = ValueNotifier<bool>(false);
  final StreamController<void> _screenshots =
      StreamController<void>.broadcast();
  Future<void>? _acquireInFlight;
  Future<void>? _initializeInFlight;
  bool _liveCaptureEventReceived = false;
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

  /// 是否**已确认**正在录屏/镜像（`unknown` 时为 false）。
  ///
  /// 兼容旧调用方；只用于文案展示。reveal 判定必须用 [canReveal]，
  /// 因为 `false` 也可能只是「状态未知」。
  ValueListenable<bool> get captureActive => _captureActive;

  /// 三态捕获状态；[ScreenCaptureState.unknown] 必须 fail closed。
  ValueListenable<ScreenCaptureState> get captureState => _captureState;

  /// 安全窗口就绪状态；只有 [ScreenProtectionReadiness.ready] 才允许 reveal。
  ValueListenable<ScreenProtectionReadiness> get readiness => _readiness;

  /// 是否满足 reveal 的全部前置条件：
  /// 安全窗口 `ready` **且** 捕获状态已知 **且** 未在录屏/镜像。
  bool get canReveal =>
      !_disposed &&
      _readiness.value == ScreenProtectionReadiness.ready &&
      _captureState.value == ScreenCaptureState.inactive;

  /// iOS 系统截图**完成之后**的通知流（用于立即销毁闪照的补救动作）。
  Stream<void> get screenshots => _screenshots.stream;

  /// 初始化：拉取一次捕获状态快照（幂等）。
  ///
  /// 上一次仍未得到已知状态时允许重试（通道瞬时失败可自愈）；失败始终按
  /// `unknown` fail closed。事件通道带来的实时更新优先级高于快照。
  Future<void> initialize() {
    if (_disposed) return Future<void>.value();
    if (_captureState.value != ScreenCaptureState.unknown) {
      return _initializeInFlight ?? Future<void>.value();
    }
    return _initializeInFlight = _loadCaptureSnapshot();
  }

  Future<void> _loadCaptureSnapshot() async {
    final snapshot = _captureStateSnapshot;
    if (snapshot == null) {
      // 未接入上报能力（等价 Android：FLAG_SECURE 在源头阻断）→ 未在捕获。
      _setCaptureState(ScreenCaptureState.inactive);
      return;
    }
    try {
      final active = await snapshot();
      if (_disposed || _liveCaptureEventReceived) return;
      _setCaptureState(active == null
          ? ScreenCaptureState.inactive
          : (active ? ScreenCaptureState.active : ScreenCaptureState.inactive));
    } catch (_) {
      // 快照失败 ≠ 未在录屏：保持 unknown（fail closed）。
      if (_disposed || _liveCaptureEventReceived) return;
      _setCaptureState(ScreenCaptureState.unknown);
    }
  }

  /// 申请安全窗口租约：第一个租约开启，后续租约只增加计数。
  ///
  /// **在返回前**必须已确认安全窗口状态（[readiness] 不再是 `initializing`），
  /// 因此调用方 `await acquire()` 之后即可安全地用 [canReveal] 判定。
  /// 平台失败不抛异常，而是把 readiness 置为 `failed`（调用方 fail closed）。
  Future<ScreenCaptureLease> acquire() async {
    final token = Object();
    _tokens.add(token);
    if (_tokens.length == 1) {
      _acquireInFlight = _enableSecureWindow();
    }
    await _acquireInFlight;
    await initialize();
    return ScreenCaptureLease._(this, token);
  }

  Future<void> _enableSecureWindow() async {
    try {
      await _invoker('acquireSecure');
      if (!_disposed) _setReadiness(ScreenProtectionReadiness.ready);
    } catch (_) {
      if (!_disposed) _setReadiness(ScreenProtectionReadiness.failed);
    }
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
  /// 计数不变，只重新应用当前状态）。重申失败 → fail closed（readiness failed）。
  Future<void> reassert() async {
    if (_tokens.isEmpty || _disposed) return;
    try {
      await _invoker('reassertSecure');
    } catch (_) {
      if (!_disposed) _setReadiness(ScreenProtectionReadiness.failed);
    }
  }

  void _onPlatformEvent(Object? event) {
    if (_disposed || event is! Map) return;
    switch (event['type']) {
      case 'captureState':
        // 实时事件优先于初始快照（快照可能更旧）。
        _liveCaptureEventReceived = true;
        _setCaptureState(event['active'] == true
            ? ScreenCaptureState.active
            : ScreenCaptureState.inactive);
      case 'screenshot':
        // 系统截图已完成：仅能作为“事后销毁”信号，绝不声称阻止截图。
        if (!_screenshots.isClosed) _screenshots.add(null);
    }
  }

  void _setReadiness(ScreenProtectionReadiness next) {
    if (_disposed) return;
    _readiness.value = next;
  }

  void _setCaptureState(ScreenCaptureState next) {
    if (_disposed) return;
    _captureState.value = next;
    // 兼容旧字段：只有「已确认 active」才为 true（unknown 不得被当成安全）。
    _captureActive.value = next == ScreenCaptureState.active;
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
    _readiness.dispose();
    _captureState.dispose();
    _captureActive.dispose();
    await _screenshots.close();
  }
}
