import 'package:flutter/services.dart';

import 'notification_diagnostics.dart';

/// Android 通知渠道原生能力（`chatflow/notification` 通道）：
/// - 直达具体渠道设置页（用户手动降级渠道重要性/声音后只能在此恢复）；
/// - 查询渠道真实状态（用户修改过的 importance/sound/vibration）。
final class NotificationChannelGateway {
  const NotificationChannelGateway({this.diagnostics});

  final NotificationDiagnostics? diagnostics;

  static const _channel = MethodChannel('chatflow/notification');

  Future<bool> openChannelSettings(String channelId) async {
    final diag = diagnostics ?? NotificationDiagnostics.shared;
    try {
      final opened = await _channel
          .invokeMethod<bool>('openChannelSettings', {'channelId': channelId});
      diag.record(NotificationDiagStage.channel,
          'open settings for $channelId: ${opened == true ? 'ok' : 'unavailable'}');
      return opened == true;
    } catch (error) {
      // 非 Android 平台通道不存在；静默降级。
      diag.record(NotificationDiagStage.channel,
          'open settings for $channelId failed: ${error.runtimeType}');
      return false;
    }
  }

  /// 渠道真实状态；null 表示不可用（非 Android/渠道不存在返回 exists=false
  /// 的 map，仅平台异常返回 null）。
  Future<Map<String, Object?>?> channelState(String channelId) async {
    final diag = diagnostics ?? NotificationDiagnostics.shared;
    try {
      final state = await _channel
          .invokeMethod<Map>('getChannelState', {'channelId': channelId});
      if (state == null) return null;
      final mapped = <String, Object?>{};
      state.forEach((key, value) {
        if (key != null) mapped[key.toString()] = value;
      });
      diag.record(NotificationDiagStage.channel, 'state $channelId: $mapped');
      return mapped;
    } catch (error) {
      diag.record(NotificationDiagStage.channel,
          'state query for $channelId failed: ${error.runtimeType}');
      return null;
    }
  }
}
