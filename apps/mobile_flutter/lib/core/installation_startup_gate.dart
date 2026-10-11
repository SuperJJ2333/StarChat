import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../ui/foundation/wechat_tokens.dart';
import 'installation_reconciler.dart';
import 'session_failure.dart';
import 'startup_failure_metadata.dart';

/// Delays application composition until the installation check has settled.
final class InstallationStartupGate extends StatefulWidget {
  const InstallationStartupGate({
    super.key,
    required this.reconcile,
    required this.start,
    this.onFailure,
    this.prepare,
    this.shellBuilder,
  });

  final Future<InstallationResetOutcome> Function() reconcile;
  final Future<Widget> Function() start;
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

  Future<void> _reconcileAndStart() async {
    if (_checking || _started) return;
    _checking = true;
    _beginPending();
    if (!_prepared && widget.prepare != null) {
      setState(() => _phase = _GatePhase.preparing);
      try {
        await widget.prepare!();
        _prepared = true;
      } catch (error) {
        _checking = false;
        _cancelPendingTimers();
        final failure = safeStartupFailure(error,
            boundary: StartupFailureBoundary.preferencesLoad);
        notifyStartupFailure(widget.onFailure, failure);
        if (!mounted) return;
        setState(() {
          _startFailure =
              sessionFailureCategoryMessage(failure.category, stage: 'startup');
          _phase = _GatePhase.startFailed;
        });
        _releaseFirstFrame();
        return;
      }
      if (!mounted) return;
    }
    if (mounted) setState(() => _phase = _GatePhase.checking);

    InstallationResetOutcome outcome;
    try {
      outcome = await widget.reconcile();
    } catch (error) {
      notifyStartupFailure(
          widget.onFailure,
          safeStartupFailure(error,
              boundary: StartupFailureBoundary.reconcile));
      outcome = InstallationResetOutcome.failed;
    } finally {
      _checking = false;
    }
    if (!mounted) return;
    if (outcome == InstallationResetOutcome.failed) {
      _cancelPendingTimers();
      setState(() => _phase = _GatePhase.failed);
      _releaseFirstFrame();
      return;
    }

    _started = true;
    setState(() => _phase = _GatePhase.starting);
    try {
      final child = await widget.start();
      if (!mounted) return;
      _cancelPendingTimers();
      setState(() {
        _child = child;
        _phase = _GatePhase.ready;
      });
      _releaseFirstFrame();
    } catch (error) {
      _started = false;
      _cancelPendingTimers();
      final failure = safeStartupFailure(error,
          boundary: StartupFailureBoundary.applicationStart);
      notifyStartupFailure(widget.onFailure, failure);
      if (!mounted) return;
      setState(() {
        _startFailure =
            sessionFailureCategoryMessage(failure.category, stage: 'startup');
        _phase = _GatePhase.startFailed;
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
