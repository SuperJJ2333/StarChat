import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/local_notification_scheduler.dart';

void main() {
  test('notification ids are stable and reminder copy is generic', () {
    expect(notificationIdFor('reminder-1'), notificationIdFor('reminder-1'));
    expect(notificationIdFor('reminder-1'), isNot(notificationIdFor('other')));
    expect(changliaoReminderNotificationBody, '你设置的消息提醒已到时间');
  });
}
