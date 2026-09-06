import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/foreground_service_arbiter.dart';
import 'package:liuhetong_mobile/features/matrix/call_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final video in [false, true]) {
    test(
        'incoming notification uses requested ${video ? "video" : "voice"} title',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      const channel =
          MethodChannel('dexterous.com/flutter/local_notifications');
      MethodCall? shown;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'show') shown = call;
        return null;
      });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await CallNotifications().showIncoming(callerName: '来电', video: video);
      expect((shown!.arguments as Map)['title'], video ? '畅聊视频来电' : '语音通话');
    });
  }

  for (final ongoing in [true, false]) {
    test(
        'ending during notification initialization cannot resurrect ${ongoing ? "ongoing" : "incoming"} notification',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      const channel =
          MethodChannel('dexterous.com/flutter/local_notifications');
      final initializing = Completer<void>();
      final releaseInitialization = Completer<void>();
      final shown = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'show') shown.add(call);
        if (!initializing.isCompleted &&
            call.method == 'createNotificationChannel') {
          initializing.complete();
          await releaseInitialization.future;
        }
        return null;
      });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final backend = _RecordingBackend();
      final arbiter = ForegroundServiceArbiter(backend: backend);
      final notifications = CallNotifications(arbiter: arbiter);
      final showing = ongoing
          ? notifications.showOngoing(title: '点击返回通话')
          : notifications.showIncoming(callerName: '来电', video: false);
      await initializing.future;
      if (ongoing) {
        await notifications.hideOngoing();
      } else {
        await notifications.hideIncoming();
      }
      releaseInitialization.complete();
      await showing;
      expect(backend.started, isEmpty);
      expect(shown, isEmpty);
      expect(arbiter.isActive(ForegroundServiceOwner.ongoingCall), isFalse);
    });
  }

  test('voice ongoing service does not require camera permission', () {
    final request = CallNotifications.ongoingCallRequest(title: '通话中');
    expect(request.foregroundServiceTypes, {
      AndroidServiceForegroundType.foregroundServiceTypeMicrophone,
    });
  });

  test(
      'minimized incoming notification offers return without full-screen reopening',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    MethodCall? shown;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'show') shown = call;
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    await CallNotifications().showIncoming(
        callerName: '加密来电', video: false, fullScreenIntent: false);
    expect((shown!.arguments as Map)['payload'], 'incoming-call');
    expect(
        ((shown!.arguments as Map)['platformSpecifics']
            as Map)['fullScreenIntent'],
        isFalse);
  });

  test('video ongoing notification carries a return payload and camera type',
      () {
    final request =
        CallNotifications.ongoingCallRequest(title: '视频通话', video: true);
    expect(request.payload, 'ongoing-call');
    expect(request.foregroundServiceTypes, {
      AndroidServiceForegroundType.foregroundServiceTypeMicrophone,
      AndroidServiceForegroundType.foregroundServiceTypeCamera,
    });
  });

  test(
      'platform ongoing notification preserves return payload and cannot auto-cancel',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    await FlutterForegroundServiceBackend().start(
      CallNotifications.ongoingCallRequest(title: '语音通话'),
    );
    expect(captured?.method, 'startForegroundService');
    final arguments = (captured!.arguments as Map)['notificationData'] as Map;
    expect(arguments['payload'], 'ongoing-call');
    expect((arguments['platformSpecifics'] as Map)['autoCancel'], isFalse);
  });
}

final class _RecordingBackend implements ForegroundServiceBackend {
  final started = <ForegroundServiceRequest>[];
  @override
  Future<void> start(ForegroundServiceRequest request) async =>
      started.add(request);
  @override
  Future<void> stop() async {}
}
