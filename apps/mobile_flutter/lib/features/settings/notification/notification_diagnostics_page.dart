import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/notification/notification_diagnostics.dart';
import '../../../ui/components/wechat_scaffold.dart';

/// 通知诊断页：查看/复制结构化诊断日志（sync 到达、策略抑制、系统
/// 调用成败、权限与渠道状态、前台服务与推送）。所有条目已脱敏。
final class NotificationDiagnosticsPage extends StatefulWidget {
  const NotificationDiagnosticsPage({super.key});

  @override
  State<NotificationDiagnosticsPage> createState() =>
      _NotificationDiagnosticsPageState();
}

final class _NotificationDiagnosticsPageState
    extends State<NotificationDiagnosticsPage> {
  @override
  void initState() {
    super.initState();
    unawaited(NotificationDiagnostics.shared.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    }));
  }

  Future<void> _copy() async {
    await Clipboard.setData(
        ClipboardData(text: NotificationDiagnostics.shared.export()));
    if (!mounted) return;
    showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        message: const Text('诊断日志已复制（不含消息内容与密钥）'),
        actions: [
          CupertinoActionSheetAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }

  Future<void> _clear() async {
    await NotificationDiagnostics.shared.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final entries = NotificationDiagnostics.shared.snapshot();
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('通知诊断'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(44, 32),
              onPressed: entries.isEmpty ? null : _copy,
              child: const Text('复制'),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(44, 32),
              onPressed: entries.isEmpty ? null : _clear,
              child: const Text('清空'),
            ),
          ],
        ),
      ),
      child: SafeArea(
        child: entries.isEmpty
            ? const Center(
                child: Text(
                  '暂无诊断记录',
                  style: TextStyle(
                      fontSize: 14, color: CupertinoColors.systemGrey),
                ),
              )
            : ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[entries.length - 1 - index];
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                    child: Text(
                      entry.toString(),
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// Android 渠道深链入口可见性（渠道重要性/声音只能由用户在系统设置中
/// 修改；非 Android 无此概念）。
bool get showAndroidChannelSettingsActions =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
