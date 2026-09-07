import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/push/native_apns_push_token_provider.dart';
import 'package:liuhetong_mobile/features/push/push_tap_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chatflow/apns');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  final taps = <PushNotificationPayload>[];
  late NativeApnsPushTokenProvider provider;

  Future<void> native(String method, Object? arguments) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall(method, arguments)),
        (_) => done.complete());
    await done.future;
  }

  setUp(() {
    calls.clear();
    taps.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'getToken' ? 'aabbccdd' : null;
    });
    provider = NativeApnsPushTokenProvider(channel: channel, onTap: taps.add);
  });

  tearDown(() async {
    await provider.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('starts once and gets the APNs token from the native bridge', () async {
    await provider.initialize();
    await provider.initialize();
    expect(await provider.token(), 'aabbccdd');
    expect(calls.where((method) => method == 'start'), hasLength(1));
  });

  test('token rotations are delivered and invalid values are ignored',
      () async {
    await provider.initialize();
    final values = <String?>[];
    final subscription = provider.tokenUpdates().listen(values.add);
    await native('tokenChanged', '0011AABB');
    await native('tokenChanged', 'not-an-apns-token');
    await native('tokenChanged', 'abc');
    await Future<void>.delayed(Duration.zero);
    expect(values, ['0011AABB']);
    await subscription.cancel();
  });

  test('notification tap forwards only the existing payload whitelist',
      () async {
    await provider.initialize();
    await native('notificationTap', {
      'room_id': '!room:example.org',
      'event_id': r'$event',
      'body': 'must not be forwarded',
      'content': {'secret': 'hidden'},
    });
    expect(taps, hasLength(1));
    expect(taps.single.roomId, '!room:example.org');
    expect(taps.single.eventId, r'$event');
  });

  test('missing bridge does not break login and initialization can retry',
      () async {
    messenger.setMockMethodCallHandler(
        channel, (_) async => throw MissingPluginException());
    await provider.initialize();
    expect(await provider.token(), isNull);
    messenger.setMockMethodCallHandler(
        channel, (call) async => call.method == 'getToken' ? 'aabb' : null);
    await provider.initialize();
    expect(await provider.token(), 'aabb');
  });

  test('dispose stops native listener and does not initialize again', () async {
    await provider.initialize();
    await provider.dispose();
    await provider.initialize();
    expect(await provider.token(), isNull);
    expect(calls.where((method) => method == 'stop'), hasLength(1));
    expect(calls.where((method) => method == 'start'), hasLength(1));
  });
}
