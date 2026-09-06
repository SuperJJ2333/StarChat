import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

/// 登录后及系统设置返回时复核；用户拒绝后仍保留可操作入口。
final class NotificationReadinessBanner extends StatefulWidget {
  const NotificationReadinessBanner({super.key});
  @override
  State<NotificationReadinessBanner> createState() =>
      _NotificationReadinessBannerState();
}

final class _NotificationReadinessBannerState
    extends State<NotificationReadinessBanner> with WidgetsBindingObserver {
  static const _channel = MethodChannel('chatflow/notification');
  List<String> _issues = const [];
  bool _fullScreenDenied = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final state = await _channel
          .invokeMapMethod<String, dynamic>('getNotificationReadiness');
      if (!mounted || state == null) return;
      setState(() {
        _issues = List<String>.from(state['issues'] ?? const []);
        _fullScreenDenied = state['fullScreenDenied'] == true;
      });
    } catch (_) {/* 非 Android 无此平台能力。 */}
  }

  Future<void> _open() async {
    try {
      await _channel.invokeMethod<bool>(_fullScreenDenied
          ? 'openFullScreenSettings'
          : 'openNotificationSettings');
    } catch (_) {/* 原生侧提供系统设置回退。 */}
  }

  @override
  Widget build(BuildContext context) => _issues.isEmpty
      ? const SizedBox.shrink()
      : Container(
          color: CupertinoColors.systemYellow.resolveFrom(context),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Expanded(
                child: Text('${_issues.join('、')}，可能漏接消息或来电',
                    style: const TextStyle(
                        fontSize: 12, color: CupertinoColors.black))),
            CupertinoButton(
                key: const Key('notification-enable-settings'),
                padding: const EdgeInsets.all(8),
                onPressed: _open,
                child: const Text('去开启', style: TextStyle(fontSize: 13))),
          ]),
        );
}
