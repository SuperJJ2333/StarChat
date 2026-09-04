import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/notification/notification_diagnostics.dart';
import '../../../core/privacy_consent.dart';
import '../../../features/push/getui_push_token_provider.dart';
import '../../../features/push/push_status_registry.dart';
import '../../../ui/components/wechat_scaffold.dart';

/// 通知诊断页：顶部推送链路状态摘要（隐私同意/SDK/CID 存在性/网关/
/// pusher 注册/权限——全部脱敏，CID 只显示存在性），下方为结构化
/// 诊断日志（sync 到达、策略抑制、系统调用成败、前台服务与推送）。
final class NotificationDiagnosticsPage extends StatefulWidget {
  const NotificationDiagnosticsPage({
    super.key,
    this.registry,
    this.consentStore = const SharedPreferencesPrivacyConsentStore(),
  });

  /// null → 运行时取 [PushStatusRegistry.shared]（非 const 默认值）。
  final PushStatusRegistry? registry;
  final PrivacyConsentStore consentStore;

  @override
  State<NotificationDiagnosticsPage> createState() =>
      _NotificationDiagnosticsPageState();
}

/// 单个 pusher 通道的脱敏状态快照。
class _ChannelStatus {
  _ChannelStatus({
    required this.appId,
    required this.gatewayHost,
    required this.registered,
    required this.lastSuccessLabel,
    required this.lastFailureLabel,
    this.sdkInitialized,
    this.cidPresent,
  });

  final String appId;
  final String gatewayHost;
  final bool registered;
  final String lastSuccessLabel;
  final String lastFailureLabel;

  /// 仅个推通道非 null（其他通道无 SDK/CID 概念）。
  final bool? sdkInitialized;
  final bool? cidPresent;
}

final class _NotificationDiagnosticsPageState
    extends State<NotificationDiagnosticsPage> {
  bool? _consentAccepted;
  String _notificationPermission = '…';
  String _batteryOptimization = '…';
  List<_ChannelStatus>? _channels;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshStatus());
    unawaited(NotificationDiagnostics.shared.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    }));
  }

  Future<void> _refreshStatus() async {
    final consent = await widget.consentStore.accepted();
    final notification =
        await _permissionLabel(Permission.notification, granted: '已授权');
    final battery = await _permissionLabel(
      Permission.ignoreBatteryOptimizations,
      granted: '未受限',
      denied: '受限（后台可能被杀）',
    );
    final channels = <_ChannelStatus>[];
    for (final service in (widget.registry ?? PushStatusRegistry.shared).services) {
      bool? sdkInitialized;
      bool? cidPresent;
      final provider = service.tokenProvider;
      if (provider is GetuiPushTokenProvider) {
        sdkInitialized = provider.isInitialized;
        cidPresent = await provider.hasCid();
      }
      channels.add(_ChannelStatus(
        appId: service.appId,
        gatewayHost: service.gatewayUrl?.host ?? '未配置',
        registered: service.isRegistered,
        lastSuccessLabel: _timeLabel(service.lastSuccessAt),
        lastFailureLabel: service.lastFailureAt == null
            ? '-'
            : '${_timeLabel(service.lastFailureAt)}'
                '${service.lastFailureKind.isEmpty ? '' : '（${service.lastFailureKind}）'}',
        sdkInitialized: sdkInitialized,
        cidPresent: cidPresent,
      ));
    }
    if (!mounted) return;
    setState(() {
      _consentAccepted = consent;
      _notificationPermission = notification;
      _batteryOptimization = battery;
      _channels = channels;
    });
  }

  /// 权限状态文案（平台差异/查询失败/查询挂起统一降级，绝不让诊断页抛错）。
  Future<String> _permissionLabel(
    Permission permission, {
    required String granted,
    String denied = '未授权',
  }) async {
    try {
      final status = await permission.status
          .timeout(const Duration(seconds: 2));
      return switch (status) {
        PermissionStatus.granted ||
        PermissionStatus.limited ||
        PermissionStatus.provisional =>
          granted,
        PermissionStatus.permanentlyDenied => '$denied（需系统设置开启）',
        _ => denied,
      };
    } on TimeoutException {
      return '未知';
    } catch (_) {
      return '未知';
    }
  }

  String _timeLabel(DateTime? at) =>
      at == null ? '-' : at.toLocal().toString().substring(0, 19);

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusSummary(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '诊断日志',
                style: TextStyle(
                    fontSize: 13, color: CupertinoColors.systemGrey),
              ),
            ),
            Expanded(child: _buildLogList(entries)),
          ],
        ),
      ),
    );
  }

  /// 推送链路状态摘要（脱敏：CID 只显示存在性）。
  Widget _buildStatusSummary() {
    final channels = _channels;
    return Container(
      color: CupertinoColors.systemGroupedBackground,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('推送状态',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _row('隐私同意', switch (_consentAccepted) {
            true => '已同意',
            false => '未同意',
            null => '…',
          }),
          _row('通知权限', _notificationPermission),
          _row('电池优化', _batteryOptimization),
          for (final channel in channels ?? const <_ChannelStatus>[]) ...[
            const SizedBox(height: 8),
            Text('通道 ${channel.appId}',
                style: const TextStyle(
                    fontSize: 13, color: CupertinoColors.systemGrey)),
            if (channel.sdkInitialized != null)
              _row('SDK 初始化', channel.sdkInitialized! ? '已初始化' : '未初始化'),
            if (channel.cidPresent != null)
              _row('CID', channel.cidPresent! ? '已获取' : '未获取'),
            _row('网关', channel.gatewayHost),
            _row('注册状态', channel.registered ? '已注册' : '未注册'),
            _row('最近成功', channel.lastSuccessLabel),
            _row('最近失败', channel.lastFailureLabel),
          ],
          if (channels != null && channels.isEmpty)
            const Text('（推送通道未装配：未登录或网关未配置）',
                style: TextStyle(
                    fontSize: 12, color: CupertinoColors.systemGrey)),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 88,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 13, color: CupertinoColors.systemGrey)),
            ),
            Expanded(
              child: Text(
                value,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      );

  Widget _buildLogList(List entries) => entries.isEmpty
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
        );
}

/// Android 渠道深链入口可见性（渠道重要性/声音只能由用户在系统设置中
/// 修改；非 Android 无此概念）。
bool get showAndroidChannelSettingsActions =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
