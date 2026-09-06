import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/notification_decision.dart';
import 'package:liuhetong_mobile/core/notification/system_notification_presenter.dart';

/// 根因：chatflow_messages 渠道为 IMPORTANCE_DEFAULT，无 Heads-up 顶部
/// 弹窗；且 Android 渠道创建后重要性/声音不可修改——老安装必须换用新
/// 渠道 ID。旧渠道保留（不删除、不覆盖用户选择），仅停止使用。
void main() {
  test('messages 渠道升级为 v2：IMPORTANCE_HIGH + 声音 + 渠道级震动', () {
    final spec = channelSpecFor(SystemNotificationChannel.messages);
    expect(spec.id, 'chatflow_messages_v2');
    expect(spec.importance, Importance.high, reason: '普通消息需要 Heads-up 顶部弹窗');
    expect(spec.soundResource, 'chatflow_message');
    expect(spec.vibrationEnabled, isTrue, reason: '渠道级震动（锁屏可感知）');
    expect(spec.legacy, isFalse);
  });

  test('静默渠道保持 LOW 且无声（勿扰/静音会话入通知中心不打扰）', () {
    final spec = channelSpecFor(SystemNotificationChannel.silent);
    expect(spec.id, 'chatflow_silent');
    expect(spec.importance, Importance.low);
    expect(spec.soundResource, isNull);
  });

  test('重要提醒与系统消息合并到消息渠道，另保留静默后台服务', () {
    for (final channel in [SystemNotificationChannel.mentions,
        SystemNotificationChannel.attention, SystemNotificationChannel.system]) {
      expect(channelSpecFor(channel).id, messagesChannelIdV2);
      expect(channelSpecFor(channel).importance, Importance.high);
    }
    expect(activeChannelSpecs.map((s) => s.id).toSet(),
        {messagesChannelIdV2, 'chatflow_silent', 'calls_ring'});
  });

  test('v2 渠道 ID 常量与设置页深链一致', () {
    expect(messagesChannelIdV2, 'chatflow_messages_v2');
  });

  group('系统通知点击统一分发（单一回调注册者）', () {
    test('friend-requests → 好友申请页；incoming-call → 仅回前台；roomId → 会话', () {
      final conversations = <String>[];
      var friendRequestOpens = 0;
      void dispatch(String payload) => routeSystemNotificationPayload(
            payload,
            openConversation: conversations.add,
            openFriendRequests: () => friendRequestOpens++,
          );

      dispatch('friend-requests');
      expect(friendRequestOpens, 1);
      expect(conversations, isEmpty);

      dispatch('incoming-call');
      expect(friendRequestOpens, 1, reason: '来电点击只回前台，不路由');
      expect(conversations, isEmpty);

      dispatch('ongoing-call');
      expect(conversations, isEmpty, reason: 'ongoing call is not a room ID');

      dispatch('!room-9:matrix.example');
      expect(conversations, ['!room-9:matrix.example']);

      dispatch('');
      expect(conversations, ['!room-9:matrix.example'], reason: '空 payload 忽略');
    });
  });
}
