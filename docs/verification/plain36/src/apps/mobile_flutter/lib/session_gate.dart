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
  });

  final SessionBootstrapController controller;
  final WidgetBuilder unauthenticatedBuilder;
  final WidgetBuilder authenticatedBuilder;

  @override
  State<SessionGate> createState() => _SessionGateState();
}

final class _SessionGateState extends State<SessionGate> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant SessionGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: switch (state.status) {
        SessionBootstrapStatus.loading => const _SessionLoadingPage(),
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
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.bubble_left_bubble_right_fill,
                  size: 64,
                  color: Color(0xff07c160),
                ),
                SizedBox(height: 20),
                CupertinoActivityIndicator(),
                SizedBox(height: 12),
                Text('正在恢复登录状态…'),
              ],
            ),
          ),
        ),
      );
}
