import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/system_notification_presenter.dart';
import 'package:liuhetong_mobile/core/notification/notification_event.dart';
import 'package:liuhetong_mobile/core/notification/notification_decision.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'iOS normal notification does not repeat presentation for unsupported avatar bytes',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    IOSFlutterLocalNotificationsPlugin.registerWith();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var avatarLoads = 0;
    final presenter =
        FlutterLocalSystemNotificationPresenter(avatarLoader: (_) async {
      avatarLoads++;
      return Uint8List.fromList([1, 2, 3]);
    });
    await presenter.showConversationWithAvatar(
        notificationId: 7,
        event: NotificationEvent(
            eventId: 'new',
            conversationId: 'room',
            senderId: 'peer',
            timestamp: DateTime(2026),
            avatarUrl: 'https://example.test/avatar'),
        title: 'Peer',
        body: 'New',
        channel: SystemNotificationChannel.messages,
        canPresentAvatar: () => true);
    await Future<void>.delayed(Duration.zero);
    expect(avatarLoads, 0);
    expect(calls.where((call) => call.method == 'show'), hasLength(1));
  });
}
