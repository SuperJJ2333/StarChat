import 'package:flutter/cupertino.dart';

import 'core/session_bootstrap_controller.dart';
import 'ui/components/modern_action_button.dart';
import 'ui/components/network_status_capsule.dart';

final class SessionGate extends StatefulWidget {
  const SessionGate({
    super.key,
    required this.controller,
    required this.unauthenticatedBuilder,
    required this.authenticatedBuilder,
    this.cachedMessagesBuilder,
    this.onConfirmNewDeviceRecovery,
  });

  final SessionBootstrapController controller;
  final WidgetBuilder unauthenticatedBuilder;
  final WidgetBuilder authenticatedBuilder;
  final WidgetBuilder? cachedMessagesBuilder;
  final Future<void> Function()? onConfirmNewDeviceRecovery;

  @override
  State<SessionGate> createState() => _SessionGateState();
}

final class _SessionGateState extends State<SessionGate>
    with WidgetsBindingObserver {
  String? _shownSessionMessage;
  late bool _wasAuthenticated;
  bool _rootResetPending = false;
  bool _recoveryBusy = false;
  bool _recoveryDeferred = false;
  String? _recoveryError;

  Future<void> _confirmNewDeviceRecovery() async {
    final confirm = widget.onConfirmNewDeviceRecovery;
    if (confirm == null || _recoveryBusy) return;
    setState(() {
      _recoveryBusy = true;
      _recoveryError = null;
    });
    try {
      await confirm();
      await widget.controller.bootstrapAfterConfirmedNewDevice();
    } catch (_) {
      if (mounted) {
        setState(() => _recoveryError = '建立新设备未完成，旧聊天数据已保留，请重试');
      }
    } finally {
      if (mounted) setState(() => _recoveryBusy = false);
    }
  }

  bool get _isAuthenticated => switch (widget.controller.state.status) {
        SessionBootstrapStatus.authenticated ||
        SessionBootstrapStatus.offlineAuthenticated =>
          true,
        _ => false,
      };

  @override
  void initState() {
    super.initState();
    _wasAuthenticated = _isAuthenticated;
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    _showSessionMessage();
  }

  @override
  void didUpdateWidget(covariant SessionGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      if (_wasAuthenticated && !_isAuthenticated) _clearOldAccountRoutes();
      _wasAuthenticated = _isAuthenticated;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      widget.controller.checkSessionValidity();
    }
  }

  void _changed() {
    if (widget.controller.state.status !=
        SessionBootstrapStatus.recoveryRequired) {
      _recoveryDeferred = false;
      _recoveryError = null;
    }
    final authenticated = _isAuthenticated;
    if (_wasAuthenticated && !authenticated) _clearOldAccountRoutes();
    _wasAuthenticated = authenticated;
    setState(() {});
    _showSessionMessage();
  }

  void _clearOldAccountRoutes() {
    if (_rootResetPending) return;
    _rootResetPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rootResetPending = false;
      if (!mounted) return;
      Navigator.maybeOf(context, rootNavigator: true)
          ?.popUntil((route) => route.isFirst);
    });
  }

  void _showSessionMessage() {
    final state = widget.controller.state;
    final message = state.message;
    if (state.status != SessionBootstrapStatus.unauthenticated) {
      _shownSessionMessage = null;
      return;
    }
    if (message == null || message == _shownSessionMessage) return;
    _shownSessionMessage = message;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.controller.state.message != message ||
          widget.controller.state.status !=
              SessionBootstrapStatus.unauthenticated) {
        return;
      }
      showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
                  title: const Text('账号已退出'),
                  content: Text(message),
                  actions: [
                    CupertinoDialogAction(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('知道了'))
                  ]));
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: switch (state.status) {
        SessionBootstrapStatus.loading =>
          widget.controller.canShowCachedMessages &&
                  widget.cachedMessagesBuilder != null
              ? IgnorePointer(child: widget.cachedMessagesBuilder!(context))
              : const _SessionLoadingPage(),
        SessionBootstrapStatus.authenticated => _AuthenticatedLayer(
            offline: false,
            onRetry: widget.controller.bootstrap,
            child: widget.authenticatedBuilder(context),
          ),
        SessionBootstrapStatus.offlineAuthenticated => _AuthenticatedLayer(
            offline: true,
            onRetry: widget.controller.bootstrap,
            child: widget.authenticatedBuilder(context),
          ),
        SessionBootstrapStatus.unauthenticated =>
          widget.unauthenticatedBuilder(context),
        SessionBootstrapStatus.recoveryRequired => CupertinoPageScaffold(
            navigationBar: const CupertinoNavigationBar(middle: Text('恢复聊天身份')),
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(CupertinoIcons.lock_shield, size: 42),
                      const SizedBox(height: 16),
                      const Text('本机聊天身份无法验证', textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      const Text('旧聊天数据将保留', textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      const Text('建立新设备后，部分旧消息可能无法解密；其他设备可能因单设备登录规则退出。',
                          textAlign: TextAlign.center),
                      if (_recoveryError != null) ...[
                        const SizedBox(height: 12),
                        Text(_recoveryError!, textAlign: TextAlign.center),
                      ],
                      const SizedBox(height: 20),
                      if (_recoveryDeferred) ...[
                        const Text('旧数据已保留，您可以稍后继续恢复。'),
                        CupertinoButton(
                          onPressed: () =>
                              setState(() => _recoveryDeferred = false),
                          child: const Text('继续恢复'),
                        ),
                      ] else ...[
                        if (widget.onConfirmNewDeviceRecovery != null)
                          CupertinoButton.filled(
                            onPressed: _recoveryBusy
                                ? null
                                : _confirmNewDeviceRecovery,
                            child: const Text('保留旧库并建立新设备'),
                          ),
                        CupertinoButton(
                          onPressed: _recoveryBusy
                              ? null
                              : () => setState(() => _recoveryDeferred = true),
                          child: const Text('暂不恢复'),
                        ),
                      ],
                      CupertinoButton(
                        onPressed:
                            _recoveryBusy ? null : widget.controller.bootstrap,
                        child: const Text('重试原身份'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        SessionBootstrapStatus.fatalError => CupertinoPageScaffold(
            child: SafeArea(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(state.message ?? '无法恢复登录状态'),
                    const SizedBox(height: 12),
                    ModernActionButton(
                      icon: CupertinoIcons.refresh,
                      label: '重试',
                      onPressed: widget.controller.bootstrap,
                    ),
                  ],
                ),
              ),
            ),
          ),
      },
    );
  }
}

final class _AuthenticatedLayer extends StatelessWidget {
  const _AuthenticatedLayer({
    required this.offline,
    required this.onRetry,
    required this.child,
  });
  final bool offline;
  final VoidCallback onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            left: 16,
            right: 16,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: offline
                  ? NetworkStatusCapsule(
                      key: const ValueKey('offline-capsule'),
                      onRetry: onRetry,
                    )
                  : const SizedBox.shrink(key: ValueKey('online-capsule')),
            ),
          ),
        ],
      );
}

final class _SessionLoadingPage extends StatelessWidget {
  const _SessionLoadingPage();

  @override
  Widget build(BuildContext context) => const CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(middle: Text('消息')),
        child: SafeArea(
          child: SizedBox.expand(),
        ),
      );
}
