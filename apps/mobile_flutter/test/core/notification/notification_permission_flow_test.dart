import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/system_notification_presenter.dart';
import 'package:liuhetong_mobile/features/push/firebase_push_wiring.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const notifications =
      MethodChannel('dexterous.com/flutter/local_notifications');
  const apns = MethodChannel('chatflow/apns');
  late List<MethodCall> calls;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    IOSFlutterLocalNotificationsPlugin.registerWith();
    calls = [];
    messenger.setMockMethodCallHandler(notifications, (call) async {
      calls.add(call);
      if (call.method == 'checkPermissions') {
        return {
          'isEnabled': false,
          'isAlertEnabled': false,
          'isSoundEnabled': false,
          'isBadgeEnabled': false
        };
      }
      return true;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(notifications, null);
    messenger.setMockMethodCallHandler(apns, null);
  });

  test('notification initialization never asks Darwin for permission',
      () async {
    await FlutterLocalSystemNotificationPresenter().initialize();
    final arguments =
        calls.singleWhere((c) => c.method == 'initialize').arguments as Map;
    expect(arguments['requestAlertPermission'], false);
    expect(arguments['requestSoundPermission'], false);
    expect(arguments['requestBadgePermission'], false);
  });

  test('background push presentation never requests Darwin authorization',
      () async {
    await onBackgroundPushMessage(
        const RemoteMessage(data: {'room_id': '!synthetic:test'}));
    final arguments =
        calls.singleWhere((c) => c.method == 'initialize').arguments as Map;
    expect(arguments['requestAlertPermission'], false);
    expect(arguments['requestSoundPermission'], false);
    expect(arguments['requestBadgePermission'], false);
  });

  test('native notDetermined remains requestable instead of becoming denied',
      () async {
    messenger.setMockMethodCallHandler(
        apns,
        (_) async => {
              'authorizationStatus': 'notDetermined',
              'alertEnabled': false,
              'soundEnabled': false,
              'badgeEnabled': false,
            });
    expect(
        await FlutterLocalSystemNotificationPresenter().authorizationStatus(),
        NotificationAuthorizationStatus.undetermined);
  });

  for (final native in ['authorized', 'provisional', 'ephemeral', 'denied']) {
    test('preserves native $native and independent alert sound badge options',
        () async {
      messenger.setMockMethodCallHandler(
          apns,
          (_) async => {
                'authorizationStatus': native,
                'alertEnabled': false,
                'soundEnabled': true,
                'badgeEnabled': false,
              });
      final permission =
          await FlutterLocalSystemNotificationPresenter().permissionState();
      expect(
          permission.status,
          switch (native) {
            'authorized' => NotificationAuthorizationStatus.granted,
            'provisional' => NotificationAuthorizationStatus.provisional,
            'ephemeral' => NotificationAuthorizationStatus.ephemeral,
            _ => NotificationAuthorizationStatus.denied,
          });
      expect(permission.alertEnabled, false);
      expect(permission.soundEnabled, true);
      expect(permission.badgeEnabled, false);
    });
  }
  test('native API failure stays unavailable rather than requestable or denied',
      () async {
    messenger.setMockMethodCallHandler(
        apns, (_) async => throw PlatformException(code: 'unavailable'));
    expect(
        await FlutterLocalSystemNotificationPresenter().authorizationStatus(),
        NotificationAuthorizationStatus.unavailable);
  });
}
