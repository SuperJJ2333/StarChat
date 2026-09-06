import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/user_display_name_resolver.dart';
import 'package:liuhetong_mobile/core/notification/system_notification_presenter.dart';
import 'package:liuhetong_mobile/core/notification/notification_decision.dart';
import 'package:liuhetong_mobile/features/matrix/video_transcode.dart';

void main() {
  test('冷缓存显示用户名，不暴露完整 Matrix 地址', () {
    final resolver =
        ContactBackedUserDisplayNameResolver(contactFor: (_) => null);
    expect(
        resolver.resolveSync('@a1014826460:matrix.localhost'), 'a1014826460');
  });
  test('各消息类型合并，静默通知独立无声', () {
    expect(channelSpecFor(SystemNotificationChannel.mentions).id,
        channelSpecFor(SystemNotificationChannel.messages).id);
    expect(channelSpecFor(SystemNotificationChannel.attention).id,
        channelSpecFor(SystemNotificationChannel.messages).id);
    expect(channelSpecFor(SystemNotificationChannel.system).id,
        channelSpecFor(SystemNotificationChannel.messages).id);
    expect(activeChannelSpecs.length, lessThanOrEqualTo(3));
    expect(
        channelSpecFor(SystemNotificationChannel.silent).soundResource, isNull);
  });
  test('中等大小视频也降档压缩，减少传输体积', () {
    expect(
        shouldRetryVideoAtLowerQuality(
            originalBytes: 5 * 1024 * 1024, compressedBytes: 4 * 1024 * 1024),
        isTrue);
  });
}
