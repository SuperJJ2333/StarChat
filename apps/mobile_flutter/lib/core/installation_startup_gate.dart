import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../ui/foundation/wechat_tokens.dart';
import 'installation_reconciler.dart';

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

final class _InstallationStartupGateState
    extends State<InstallationStartupGate> {
  _GatePhase _phase = _GatePhase.checking;
  Widget? _child;
  var _checking = false;
  var _started = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reconcileAndStart());
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
    } catch (_) {
      if (!mounted) return;
      setState(() => _phase = _GatePhase.startFailed);
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
                          ? '启动初始化失败，请关闭后重试'
                          : '正在检查启动状态…',
                  textAlign: TextAlign.center,
                ),
                if (failed) ...[
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
