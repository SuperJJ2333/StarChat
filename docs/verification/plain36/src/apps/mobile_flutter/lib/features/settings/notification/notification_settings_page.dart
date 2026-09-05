import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/notification/notification_channel_gateway.dart';
import '../../../core/notification/notification_coordinator.dart';
import '../../../core/notification/notification_diagnostics.dart';
import '../../../core/notification/notification_preferences.dart';
import '../../../core/notification/system_notification_presenter.dart';
import '../../../ui/components/wechat_scaffold.dart';
import '../../../ui/foundation/wechat_tokens.dart';
import 'notification_diagnostics_page.dart';

/// 通知与声音设置页（PRD §43/§67）。
final class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key, this.coordinator});

  /// 组合根的协调器；为空（通知系统未就绪）时仅落本地偏好。
  final NotificationCoordinator? coordinator;

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

final class _NotificationSettingsPageState
    extends State<NotificationSettingsPage> with WidgetsBindingObserver {
  NotificationPreferenceValues _values = const NotificationPreferenceValues();
  NotificationAuthorizationStatus _permission =
      NotificationAuthorizationStatus.undetermined;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页返回时重新检查权限（用户可能刚在系统中开启通知）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final store = const SharedPreferencesNotificationPreferenceStore();
    final values = await store.load();
    NotificationAuthorizationStatus permission =
        NotificationAuthorizationStatus.undetermined;
    try {
      permission =
          await widget.coordinator!.systemNotifications.authorizationStatus();
      NotificationDiagnostics.shared.record(
          NotificationDiagStage.permission, 'status: ${permission.name}');
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _values = values;
      _permission = permission;
    });
  }

  Future<void> _update(NotificationPreferenceValues next) async {
    setState(() => _values = next);
    final coordinator = widget.coordinator;
    if (coordinator != null) {
      await coordinator.updatePreferences(next);
    } else {
      await const SharedPreferencesNotificationPreferenceStore().save(next);
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: const CupertinoNavigationBar(middle: Text('通知与声音')),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
            children: [
              if (_permission == NotificationAuthorizationStatus.denied)
                _permissionWarning(context),
              _section(context, '新消息', [
                _switchTile(
                    '消息通知',
                    _values.messageNotificationEnabled,
                    (v) => _update(
                        _values.copyWith(messageNotificationEnabled: v))),
                _pickerTile(
                  '显示消息详情',
                  _privacyLabel(_values.previewPrivacy),
                  () => _pickPrivacy(),
                ),
                _switchTile('声音', _values.soundEnabled,
                    (v) => _update(_values.copyWith(soundEnabled: v))),
                _switchTile('震动', _values.vibrationEnabled,
                    (v) => _update(_values.copyWith(vibrationEnabled: v))),
                _switchTile('桌面角标', _values.badgeEnabled,
                    (v) => _update(_values.copyWith(badgeEnabled: v))),
              ]),
              _section(context, '重要提醒', [
                _switchTile('特别关注提醒', _values.attentionEnabled,
                    (v) => _update(_values.copyWith(attentionEnabled: v))),
                _switchTile('@我提醒', _values.mentionEnabled,
                    (v) => _update(_values.copyWith(mentionEnabled: v))),
              ]),
              _section(context, '通话', [
                _switchTile(
                    '语音/视频通话通知',
                    _values.callNotificationEnabled,
                    (v) =>
                        _update(_values.copyWith(callNotificationEnabled: v))),
              ]),
              _section(context, '勿扰模式（PRD §30）', [
                _switchTile('勿扰模式', _values.dndEnabled,
                    (v) => _update(_values.copyWith(dndEnabled: v))),
                if (_values.dndEnabled) ...[
                  _pickerTile(
                    '开始时间',
                    _timeLabel(_values.dndStartMinutes),
                    () => _pickDndTime(isStart: true),
                  ),
                  _pickerTile(
                    '结束时间',
                    _timeLabel(_values.dndEndMinutes),
                    () => _pickDndTime(isStart: false),
                  ),
                  _switchTile('勿扰期间允许特别关注', _values.dndAllowAttention,
                      (v) => _update(_values.copyWith(dndAllowAttention: v))),
                ],
              ]),
              _section(context, '其他', [
                _switchTile(
                    '静音会话计入桌面角标',
                    _values.mutedConversationsInBadge,
                    (v) => _update(
                        _values.copyWith(mutedConversationsInBadge: v))),
                if (showAndroidChannelSettingsActions)
                  _pickerTile(
                      '消息通知渠道设置', '提示音与弹窗', _openMessagesChannelSettings),
                _pickerTile('通知诊断', '排查通知问题', _openDiagnostics),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  '会话级 默认/静音/特别关注 在各聊天信息页设置。'
                  '系统勿扰与通知权限始终以操作系统设置为准。',
                  style: TextStyle(
                    fontSize: 12,
                    color: CupertinoDynamicColor.withBrightness(
                      color: WeChatColors.textTertiary,
                      darkColor: WeChatColors.textTertiary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  // PRD §56：权限被拒时的降级提示。
  Widget _permissionWarning(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: WeChatColors.errorSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: WeChatColors.errorBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '系统通知已关闭',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text('你可能无法及时收到新消息。', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: _openSystemSettings,
              child: const Text(
                '前往系统设置',
                style: TextStyle(fontSize: 14, color: WeChatColors.socialLink),
              ),
            ),
          ],
        ),
      );

  Future<void> _openSystemSettings() async {
    // Android：原生直达本应用通知设置（Android 13+ 二次拒绝后系统弹窗
    // 不再出现，必须引导去系统设置）；iOS：app-settings: 深链。
    try {
      const channel = MethodChannel('chatflow/notification');
      final opened =
          await channel.invokeMethod<bool>('openNotificationSettings');
      if (opened == true) return;
    } catch (_) {
      // 原生通道不可用（如 iOS）：走下方深链。
    }
    try {
      await launchUrl(Uri.parse('app-settings:'));
    } catch (_) {}
  }

  /// 直达 v2 消息渠道设置页：渠道重要性/声音/震动创建后应用不可修改，
  /// 用户静音或降级渠道后只能在此恢复（Heads-up 顶部弹窗随之恢复）。
  Future<void> _openMessagesChannelSettings() async {
    final opened = await const NotificationChannelGateway()
        .openChannelSettings(messagesChannelIdV2);
    if (opened || !mounted) return;
    await _openSystemSettings();
  }

  Future<void> _openDiagnostics() async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => const NotificationDiagnosticsPage(),
      ),
    );
  }

  String _privacyLabel(NotificationPrivacyLevel level) => switch (level) {
        NotificationPrivacyLevel.showAll => '显示姓名和内容',
        NotificationPrivacyLevel.nameOnly => '只显示姓名',
        NotificationPrivacyLevel.hideAll => '隐藏全部详情',
      };

  Future<void> _pickPrivacy() async {
    final choice = await showCupertinoModalPopup<int>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('锁屏与通知显示'),
        actions: [
          for (final (index, level) in NotificationPrivacyLevel.values.indexed)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, index),
              child: Text(_privacyLabel(level)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
    );
    if (choice == null) return;
    await _update(_values.copyWith(
      previewPrivacy: NotificationPrivacyLevel.values[choice],
    ));
  }

  Future<void> _pickDndTime({required bool isStart}) async {
    final initial = isStart ? _values.dndStartMinutes : _values.dndEndMinutes;
    final minute = await showCupertinoModalPopup<int>(
      context: context,
      builder: (context) => _MinuteOfDayPicker(initialMinutes: initial),
    );
    if (minute == null) return;
    await _update(_values.copyWith(
      dndStartMinutes: isStart ? minute : _values.dndStartMinutes,
      dndEndMinutes: isStart ? _values.dndEndMinutes : minute,
    ));
  }

  String _timeLabel(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';

  Widget _section(BuildContext context, String title, List<Widget> children) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              color: dark
                  ? CupertinoColors.systemGrey5
                  : CupertinoColors.systemGrey,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: WeChatColors.elevatedSurface(context),
            border: Border(
              top: BorderSide(
                  color:
                      dark ? WeChatColors.darkDivider : WeChatColors.divider),
              bottom: BorderSide(
                  color:
                      dark ? WeChatColors.darkDivider : WeChatColors.divider),
            ),
          ),
          child: Column(children: children),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _switchTile(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
      WeChatSettingsRow(
        label: label,
        trailing: CupertinoSwitch(value: value, onChanged: onChanged),
      );

  Widget _pickerTile(
          String label, String detail, Future<void> Function() onTap) =>
      WeChatSettingsRow(
        label: label,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              detail,
              style: const TextStyle(
                  fontSize: 15, color: WeChatColors.textSecondary),
            ),
            const SizedBox(width: 4),
            const CupertinoListTileChevron(),
          ],
        ),
        onTap: () => unawaited(onTap()),
      );
}

/// 通用设置行：与设置页视觉一致。
final class WeChatSettingsRow extends StatelessWidget {
  const WeChatSettingsRow({
    super.key,
    required this.label,
    this.trailing,
    this.onTap,
  });

  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        CupertinoListTile(
          title: Text(label),
          trailing: trailing,
          onTap: onTap,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
        Container(
          height: 1,
          margin: const EdgeInsets.only(left: 16),
          color: dark ? WeChatColors.darkDivider : WeChatColors.divider,
        ),
      ],
    );
  }
}

/// 一天内的时分选择器（00:00 - 23:59）。
final class _MinuteOfDayPicker extends StatefulWidget {
  const _MinuteOfDayPicker({required this.initialMinutes});

  final int initialMinutes;

  @override
  State<_MinuteOfDayPicker> createState() => _MinuteOfDayPickerState();
}

final class _MinuteOfDayPickerState extends State<_MinuteOfDayPicker> {
  late int selected = widget.initialMinutes.clamp(0, 24 * 60 - 1);

  @override
  Widget build(BuildContext context) => Container(
        height: 280,
        color: WeChatColors.elevatedSurface(context),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  CupertinoButton(
                    onPressed: () => Navigator.pop(context, selected),
                    child: const Text('确定'),
                  ),
                ],
              ),
              Expanded(
                child: CupertinoPicker(
                  scrollController: FixedExtentScrollController(
                    initialItem: selected,
                  ),
                  itemExtent: 44,
                  onSelectedItemChanged: (index) => selected = index,
                  children: [
                    for (var minute = 0; minute < 24 * 60; minute++)
                      Center(
                        child: Text(
                          '${(minute ~/ 60).toString().padLeft(2, '0')}:'
                          '${(minute % 60).toString().padLeft(2, '0')}',
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}
