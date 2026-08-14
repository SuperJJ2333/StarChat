import 'package:flutter/cupertino.dart';

import 'core/session_bootstrap_controller.dart';

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
        SessionBootstrapStatus.authenticated =>
          widget.authenticatedBuilder(context),
        SessionBootstrapStatus.offlineAuthenticated => Column(
          children: [
            SafeArea(
              bottom: false,
              child: Container(
                width: double.infinity,
                color: CupertinoColors.systemYellow.withValues(alpha: .18),
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: const Text(
                  '网络不可用，正在重连',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
            Expanded(child: widget.authenticatedBuilder(context)),
          ],
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
                  CupertinoButton(
                    onPressed: widget.controller.bootstrap,
                    child: const Text('重试'),
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
