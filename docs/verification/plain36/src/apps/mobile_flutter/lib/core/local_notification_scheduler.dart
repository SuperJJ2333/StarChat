import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../features/matrix/message_reminder_service.dart';

const changliaoReminderNotificationBody = '你设置的消息提醒已到时间';

int notificationIdFor(String reminderId) {
  final bytes = sha256.convert(utf8.encode(reminderId)).bytes;
  return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
      0x7fffffff;
}

final class FlutterLocalNotificationScheduler
    implements LocalNotificationScheduler {
  FlutterLocalNotificationScheduler({FlutterLocalNotificationsPlugin? plugin})
      : plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin plugin;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    // 不调用 plugin.initialize：点击回调只能有一个注册者（最后注册者
    // 胜出），统一由 FlutterLocalSystemNotificationPresenter 注册分发；
    // zonedSchedule 与渠道（详情隐式创建）不依赖 initialize。
    // 通知权限统一由 NotificationCoordinator 在登录后上下文式申请
    // （PRD §33）；此处只处理定时提醒必需的精确闹钟权限。
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestExactAlarmsPermission();
    _initialized = true;
  }

  NotificationDetails get _details => const NotificationDetails(
        android: AndroidNotificationDetails(
          'changliao_message_reminders',
          '消息提醒',
          channelDescription: '按你选择的时间提醒查看畅聊消息',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      );

  @override
  Future<void> schedule(MessageReminder reminder) async {
    await initialize();
    await plugin.zonedSchedule(
      notificationIdFor(reminder.id),
      '畅聊消息提醒',
      changliaoReminderNotificationBody,
      tz.TZDateTime.from(reminder.dueAt, tz.local),
      _details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: reminder.id,
    );
  }

  @override
  Future<void> cancel(String id) async {
    await initialize();
    await plugin.cancel(notificationIdFor(id));
  }

  @override
  Future<void> showOverdue(String id) async {
    await initialize();
    await plugin.show(
      notificationIdFor(id),
      '畅聊消息提醒',
      changliaoReminderNotificationBody,
      _details,
      payload: id,
    );
  }
}
