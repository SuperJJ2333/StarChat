import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/notification_decision.dart';
import 'package:liuhetong_mobile/core/notification/system_notification_presenter.dart';

class _NotificationHost extends Fake
    implements FlutterLocalNotificationsPlugin {
  InitializationSettings? initialization;
  NotificationDetails? lastNotification;

  @override
  Future<bool?> initialize(
    InitializationSettings settings, {
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
        onDidReceiveBackgroundNotificationResponse,
  }) async {
    initialization = settings;
    return true;
  }

  @override
  Future<void> show(int id, String? title, String? body,
      NotificationDetails? notificationDetails,
      {String? payload}) async {
    lastNotification = notificationDetails;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #resolvePlatformSpecificImplementation) {
      return null;
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test('silent iOS notifications override the default audible alert', () async {
    final host = _NotificationHost();
    final presenter = FlutterLocalSystemNotificationPresenter(plugin: host);
    await presenter.showConversationMessage(
        notificationId: 1,
        title: 'Synthetic',
        body: 'Synthetic',
        channel: SystemNotificationChannel.silent,
        roomIdPayload: '!fixture:test');
    final defaults = host.initialization!.iOS!;
    final details = host.lastNotification!.iOS!;
    expect(details.presentSound ?? defaults.defaultPresentSound, isFalse);
    expect(details.presentAlert ?? defaults.defaultPresentAlert, isFalse);
    expect(details.presentBanner, isFalse);
    expect(details.interruptionLevel, InterruptionLevel.passive);
  });
}
