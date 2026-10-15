import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_permissions.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('flutter.baseflow.com/permissions/methods');
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  for (final video in [false, true]) {
    test('${video ? 'video' : 'audio'} requests only its required devices',
        () async {
      final requested = <int>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'requestPermissions') {
          requested.addAll((call.arguments as List).cast<int>());
          return {for (final permission in requested) permission: 1};
        }
        return null;
      });
      expect(await const SystemCallPermissionGateway().request(video: video),
          true);
      expect(requested,
          [Permission.microphone.value, if (video) Permission.camera.value]);
    });
  }
  test('missing native microphone result cannot authorize an audio call',
      () async {
    messenger.setMockMethodCallHandler(channel, (_) async => <int, int>{});
    expect(
        await const SystemCallPermissionGateway().request(video: false), false);
  });
  test('camera denial prevents a video call and API errors fail closed',
      () async {
    messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
              Permission.microphone.value: 1,
              Permission.camera.value: 0,
            });
    expect(
        await const SystemCallPermissionGateway().request(video: true), false);
    messenger.setMockMethodCallHandler(
        channel, (_) async => throw PlatformException(code: 'unavailable'));
    expect(
        await const SystemCallPermissionGateway().request(video: false), false);
  });
}
