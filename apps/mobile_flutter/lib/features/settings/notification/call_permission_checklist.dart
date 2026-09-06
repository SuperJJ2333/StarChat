import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../../../core/notification/call_permission_readiness.dart';
import '../../../ui/components/wechat_scaffold.dart';

/// Shared by notification settings and a denied call's recovery action.
final class CallPermissionSettingsPage extends StatelessWidget {
  const CallPermissionSettingsPage(
      {super.key, this.gateway = const SystemCallPermissionReadinessGateway()});
  final CallPermissionReadinessGateway gateway;
  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: const CupertinoNavigationBar(middle: Text('通话权限')),
        child: SafeArea(
            child: ListView(
                children: [CallPermissionChecklist(gateway: gateway)])),
      );
}

final class CallPermissionChecklist extends StatefulWidget {
  const CallPermissionChecklist(
      {super.key, this.gateway = const SystemCallPermissionReadinessGateway()});
  final CallPermissionReadinessGateway gateway;
  @override
  State<CallPermissionChecklist> createState() =>
      _CallPermissionChecklistState();
}

class _CallPermissionChecklistState extends State<CallPermissionChecklist>
    with WidgetsBindingObserver {
  CallPermissionReadiness? _state;
  bool _busy = false;
  String? _error;
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
    final state = await widget.gateway.read();
    if (mounted) setState(() => _state = state);
  }

  Future<void> _act(CallPermissionAction action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final opened = await widget.gateway.act(action);
      if (mounted && !opened) setState(() => _error = '无法打开，请在系统设置中找到畅聊并检查权限。');
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _row(String title, String detail, bool? allowed,
          CallPermissionAction action) =>
      CupertinoListTile(
        title: Text(title),
        subtitle: Text(detail),
        additionalInfo: Text(allowed == null
            ? '待检查'
            : allowed
                ? '已开启'
                : '未开启'),
        trailing: const CupertinoListTileChevron(),
        onTap: _busy ? null : () => _act(action),
      );

  Widget _manufacturerSetting(String title, String detail) => CupertinoListTile(
        title: Text(title),
        subtitle: Text(detail),
        additionalInfo: const Text('手动检查'),
        trailing: const CupertinoListTileChevron(),
        onTap: _busy ? null : () => _act(CallPermissionAction.appSettings),
      );
  @override
  Widget build(BuildContext context) {
    final s = _state;
    return CupertinoListSection.insetGrouped(
      header: const Text('通话权限检查'),
      footer: Text(_error ??
          '点按项目授权或进入系统设置。锁屏通知与横幅还受系统勿扰和厂商后台限制影响。小米等机型请在应用设置中检查自启动、后台弹出界面和锁屏显示；这些厂商开关无法统一检测。'),
      children: [
        _row(
            '麦克风', '语音和视频通话需要', s?.microphone, CallPermissionAction.microphone),
        _row('摄像头', '仅视频通话需要', s?.camera, CallPermissionAction.camera),
        _row('系统通知', '后台来电与返回通话入口', s?.notifications,
            CallPermissionAction.notifications),
        if (s?.android == true) ...[
          _row('来电横幅通知', '提示音与锁屏显示由系统设置决定', s?.callChannel,
              CallPermissionAction.callChannel),
          _row('通话常驻通知', '点通知返回当前通话', s?.ongoingChannel,
              CallPermissionAction.ongoingChannel),
          if (s!.fullScreenRequired)
            _row('锁屏全屏来电', 'Android 14 及以上系统授权', s.fullScreen,
                CallPermissionAction.fullScreen),
          _row('通话悬浮窗', '切换应用后点悬浮窗返回', s.overlay, CallPermissionAction.overlay),
          _manufacturerSetting('自启动', '允许接收后台推送并启动畅聊'),
          _manufacturerSetting('锁屏显示', '在权限管理或通知设置中允许锁屏提醒'),
          _manufacturerSetting('后台弹出界面', '在其他权限中允许后台显示来电页'),
        ],
      ],
    );
  }
}
