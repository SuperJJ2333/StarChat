import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../ui/foundation/wechat_tokens.dart';
import 'installation_reconciler.dart';
import 'session_failure.dart';

/// Delays application composition until the installation check has settled.
final class InstallationStartupGate extends StatefulWidget {
  const InstallationStartupGate({
    super.key,
    required this.reconcile,
    required this.start,
  });

  final Future<InstallationResetOutcome> Function() reconcile;
  final Future<Widget> Function() start;

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

  @override
  void initState() {
    super.initState();
    // Keep the platform launch surface until local startup is ready. This
    // removes the intermediate checking page without bypassing reconciliation.
    WidgetsBinding.instance.deferFirstFrame();
    _firstFrameDeferred = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_reconcileAndStart());
  }

  @override
  void dispose() {
    _releaseFirstFrame();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
    if (mounted) setState(() => _phase = _GatePhase.checking);

    InstallationResetOutcome outcome;
    try {
      outcome = await widget.reconcile();
    } catch (_) {
      outcome = InstallationResetOutcome.failed;
    } finally {
      _checking = false;
    }
    if (!mounted) return;
    if (outcome == InstallationResetOutcome.failed) {
      setState(() => _phase = _GatePhase.failed);
      _releaseFirstFrame();
      return;
    }

    _started = true;
    setState(() => _phase = _GatePhase.starting);
    try {
      final child = await widget.start();
      if (!mounted) return;
      setState(() {
        _child = child;
        _phase = _GatePhase.ready;
      });
      _releaseFirstFrame();
    } catch (error) {
      _started = false;
      if (!mounted) return;
      setState(() {
        _startFailure = sessionFailureMessage(error, stage: 'startup');
        _phase = _GatePhase.startFailed;
      });
      _releaseFirstFrame();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _GatePhase.ready) return _child!;
    if (_phase == _GatePhase.checking || _phase == _GatePhase.starting) {
      return const SizedBox.shrink();
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

enum _GatePhase { checking, failed, starting, startFailed, ready }
