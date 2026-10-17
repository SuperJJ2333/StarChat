import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../ui/foundation/wechat_tokens.dart';
import 'installation_reconciler.dart';
import 'session_failure.dart';
import 'startup_failure_metadata.dart';

/// One bounded cache admission attempt. Revocation prevents late secure reads
/// from publishing an owner after timeout, disposal, or Retry.
final class StartupAdmissionAttempt {
  StartupAdmissionAttempt(this._onMiss);
  final void Function() _onMiss;
  final _cancelled = Completer<Widget>();
  final _retire = <void Function()>[];
  bool _current = true;
  bool _resolved = false;
  bool get isCurrent => _current;
  void checkCurrent() {
    if (!_current) throw StateError('Startup admission retired');
  }

  void onRetire(void Function() retire) {
    if (_current) {
      _retire.add(retire);
    } else {
      retire();
    }
  }

  void cacheMiss() {
    checkCurrent();
    if (_resolved) return;
    _resolved = true;
    _onMiss();
  }

  void _cancel() {
    if (!_current) return;
    _current = false;
    for (final retire in _retire) {
      retire();
    }
    _retire.clear();
    _cancelled.completeError(StateError('Startup admission did not settle'));
  }

  void _accept() {
    _retire.clear();
  }
}

/// Delays application composition until the installation check has settled.
final class InstallationStartupGate extends StatefulWidget {
  const InstallationStartupGate({
    super.key,
    required this.reconcile,
    required this.start,
    this.onFailure,
    this.startWithAdmission,
    this.prepare,
    this.shellBuilder,
  });

  final Future<InstallationResetOutcome> Function() reconcile;
  final Future<Widget> Function() start;
  final Future<Widget> Function(StartupAdmissionAttempt attempt)?
      startWithAdmission;
  final StartupFailureObserver? onFailure;

  /// Local version/preferences initialization. It must not open account data.
  final Future<void> Function()? prepare;

  /// Also wraps the account-free pending view when used above the app root.
  final Widget Function(Widget child)? shellBuilder;

  @override
  State<InstallationStartupGate> createState() =>
      _InstallationStartupGateState();
}

final class _InstallationStartupGateState extends State<InstallationStartupGate>
    with WidgetsBindingObserver {
  _GatePhase _phase = _GatePhase.checking;
  Widget? _child;
  var _checking = false;
  var _started = false;
  String? _startFailure;
  bool _firstFrameDeferred = false;
  bool _prepared = false;
  bool _safeShellVisible = false;
  bool _pendingDetails = false;
  Timer? _shellTimer;
  Timer? _detailsTimer;
  Timer? _admissionTimer;
  StartupAdmissionAttempt? _admission;

  @override
  void initState() {
    super.initState();
    // Short startup keeps the platform launch surface. A slow local operation
    // releases only an account-free view; it never bypasses reconciliation.
    WidgetsBinding.instance.deferFirstFrame();
    _firstFrameDeferred = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_reconcileAndStart());
  }

  @override
  void dispose() {
    _cancelPendingTimers();
    _admissionTimer?.cancel();
    _admission?._cancel();
    _releaseFirstFrame();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _cancelPendingTimers() {
    _shellTimer?.cancel();
    _detailsTimer?.cancel();
  }

  void _beginPending() {
    _cancelPendingTimers();
    _pendingDetails = false;
    _shellTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() => _safeShellVisible = true);
      _releaseFirstFrame();
    });
    _detailsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _pendingDetails = true);
    });
  }

  void _releaseFirstFrame() {
    if (!_firstFrameDeferred) return;
    _firstFrameDeferred = false;
    WidgetsBinding.instance.allowFirstFrame();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        (_phase == _GatePhase.failed || _phase == _GatePhase.startFailed)) {
      unawaited(_reconcileAndStart());
    }
  }

  Future<void>? _preparation;
  Future<InstallationResetOutcome>? _reconciliation;

  Future<void> _reconcileAndStart() async {
    if (_checking || _started) return;
    _checking = true;
    final enhancedStart = widget.startWithAdmission;
    StartupAdmissionAttempt? attempt;
    if (enhancedStart == null) {
      _beginPending();
    } else {
      _cancelPendingTimers();
      attempt = StartupAdmissionAttempt(() {
        _admissionTimer?.cancel();
        if (!mounted) return;
        setState(() => _safeShellVisible = true);
        _releaseFirstFrame();
        _beginPending();
      });
      _admission = attempt;
      _admissionTimer = Timer(const Duration(seconds: 8), attempt._cancel);
    }
    var boundary = StartupFailureBoundary.preferencesLoad;
    bool current() => mounted && (attempt?.isCurrent ?? true);
    Future<Widget> compose() async {
      if (!_prepared && widget.prepare != null) {
        if (current()) setState(() => _phase = _GatePhase.preparing);
        // Retry joins outstanding minimum checks; it never starts concurrent
        // installation mutations while the retired attempt is still awaiting IO.
        final preparation = _preparation ??= widget.prepare!();
        try {
          await preparation;
        } catch (_) {
          if (identical(_preparation, preparation)) _preparation = null;
          rethrow;
        }
        if (!current()) throw StateError('Startup admission retired');
        _prepared = true;
      }
      if (!current()) throw StateError('Startup admission retired');
      boundary = StartupFailureBoundary.reconcile;
      setState(() => _phase = _GatePhase.checking);
      final reconciliation = _reconciliation ??= widget.reconcile();
      late final InstallationResetOutcome outcome;
      try {
        outcome = await reconciliation;
      } finally {
        if (identical(_reconciliation, reconciliation)) _reconciliation = null;
      }
      if (!current()) throw StateError('Startup admission retired');
      if (outcome == InstallationResetOutcome.failed) {
        throw StateError('Installation check did not settle');
      }
      boundary = StartupFailureBoundary.applicationStart;
      _started = true;
      setState(() => _phase = _GatePhase.starting);
      return enhancedStart == null ? widget.start() : enhancedStart(attempt!);
    }

    try {
      final child = await (attempt == null
          ? compose()
          : Future.any<Widget>([compose(), attempt._cancelled.future]));
      if (!current()) return;
      attempt?._accept();
      _admission = null;
      _admissionTimer?.cancel();
      _cancelPendingTimers();
      _checking = false;
      setState(() {
        _child = child;
        _phase = _GatePhase.ready;
      });
      _releaseFirstFrame();
    } catch (error) {
      if (!mounted || (attempt != null && !identical(_admission, attempt))) {
        return;
      }
      // Retire before presenting Retry. A late continuation must not publish or
      // open the original database under the replacement attempt.
      attempt?._cancel();
      _admission = null;
      _admissionTimer?.cancel();
      _checking = false;
      _started = false;
      _cancelPendingTimers();
      final failure = safeStartupFailure(error, boundary: boundary);
      notifyStartupFailure(widget.onFailure, failure);
      setState(() {
        _startFailure =
            sessionFailureCategoryMessage(failure.category, stage: 'startup');
        _phase = boundary == StartupFailureBoundary.reconcile
            ? _GatePhase.failed
            : _GatePhase.startFailed;
      });
      _releaseFirstFrame();
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = _buildPhase();
    return widget.shellBuilder?.call(child) ?? child;
  }

  Widget _buildPhase() {
    if (_phase == _GatePhase.ready) return _child!;
    if (_phase == _GatePhase.preparing ||
        _phase == _GatePhase.checking ||
        _phase == _GatePhase.starting) {
      if (!_safeShellVisible) return const SizedBox.shrink();
      return CupertinoPageScaffold(
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(WeChatSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CupertinoActivityIndicator(),
                  const SizedBox(height: WeChatSpacing.lg),
                  Text(
                      _pendingDetails
                          ? switch (_phase) {
                              _GatePhase.preparing => '正在读取本地设置，请稍候',
                              _GatePhase.checking => '正在检查本地安装状态，请稍候',
                              _ => '正在打开本地聊天，请稍候',
                            }
                          : '正在启动畅聊',
                      textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final failed = _phase == _GatePhase.failed;
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('畅聊')),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(WeChatSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  CupertinoIcons.exclamationmark_circle,
                  color: WeChatColors.danger,
                  size: WeChatDimensions.minimumTouchTarget,
                ),
                const SizedBox(height: WeChatSpacing.lg),
                Text(
                  failed
                      ? '启动检查未完成，请重试'
                      : (_startFailure ?? '本地聊天初始化失败，请解锁设备后重试'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: WeChatSpacing.lg),
                CupertinoButton.filled(
                  key: const Key('installation-startup-retry'),
                  onPressed: _checking ? null : _reconcileAndStart,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _GatePhase { preparing, checking, failed, starting, startFailed, ready }
