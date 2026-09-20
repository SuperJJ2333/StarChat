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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_reconcileAndStart());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
    } catch (error) {
      _started = false;
      if (!mounted) return;
      setState(() {
        _startFailure = sessionFailureMessage(error, stage: 'startup');
        _phase = _GatePhase.startFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _GatePhase.ready) return _child!;
    final failed = _phase == _GatePhase.failed;
    final startFailed = _phase == _GatePhase.startFailed;
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('畅聊')),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(WeChatSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  failed || startFailed
                      ? CupertinoIcons.exclamationmark_circle
                      : CupertinoIcons.shield,
                  color: failed || startFailed
                      ? WeChatColors.danger
                      : WeChatColors.brandPrimary,
                  size: WeChatDimensions.minimumTouchTarget,
                ),
                const SizedBox(height: WeChatSpacing.lg),
                Text(
                  failed
                      ? '启动检查未完成，请重试'
                      : startFailed
                          ? (_startFailure ?? '本地聊天初始化失败，请解锁设备后重试')
                          : '正在检查启动状态…',
                  textAlign: TextAlign.center,
                ),
                if (failed || startFailed) ...[
                  const SizedBox(height: WeChatSpacing.lg),
                  CupertinoButton.filled(
                    key: const Key('installation-startup-retry'),
                    onPressed: _checking ? null : _reconcileAndStart,
                    child: const Text('重试'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _GatePhase { checking, failed, starting, startFailed, ready }
