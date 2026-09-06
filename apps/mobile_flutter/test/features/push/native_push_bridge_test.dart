import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/push/native_push_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  Future<Object?> deliver(String method) async {
    final result = Completer<Object?>();
    messenger.handlePlatformMessage(
        'chatflow/push', codec.encodeMethodCall(MethodCall(method)), (data) {
      result.complete(data == null ? null : codec.decodeEnvelope(data));
    });
    return result.future;
  }

  tearDown(
      () => messenger.setMockMethodCallHandler(NativePushBridge.channel, null));

  test('ready handshake follows handler installation and replays pending wake',
      () async {
    var wakes = 0;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(NativePushBridge.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'pushListenerReady') {
        expect(await deliver('pushMessage'), true);
      }
      return true;
    });
    final bridge = NativePushBridge(
        onPushMessage: () async {
          wakes++;
        },
        onFriendRequest: () async {});
    await bridge.install();
    expect(wakes, 1);
    await bridge.uninstall();
    expect(calls, ['pushListenerReady', 'pushListenerStopped']);
  });

  test('disposing previous session does not detach replacement listener',
      () async {
    var wakes = 0;
    messenger.setMockMethodCallHandler(
        NativePushBridge.channel, (_) async => true);
    final old = NativePushBridge(
        onPushMessage: () async {}, onFriendRequest: () async {});
    final current = NativePushBridge(
        onPushMessage: () async {
          wakes++;
        },
        onFriendRequest: () async {});
    await old.install();
    await current.install();
    await old.uninstall();
    expect(await deliver('pushMessage'), true);
    expect(wakes, 1);
    expect(await deliver('unknown'), false);
    await current.uninstall();
  });
}
