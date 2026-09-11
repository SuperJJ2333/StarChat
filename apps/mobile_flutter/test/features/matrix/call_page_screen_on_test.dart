import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';
import 'package:liuhetong_mobile/features/matrix/call_page.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_video_message.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

final class _AllowedPermissions implements CallPermissionGateway {
  @override
  Future<bool> request({required bool video}) async => true;
}

final class _CallBackend implements CallBackend {
  final _events = StreamController<CallBackendEvent>.broadcast();

  @override
  Stream<CallBackendEvent> get callEvents => _events.stream;
  @override
  bool get hasActiveSession => true;
  @override
  Future<void> accept() async {}
  @override
  Future<void> hangup() async {}
  @override
  Future<bool> isEncryptedDirectRoom(String roomId, String matrixUserId) async => true;
  @override
  Future<void> reject() async {}
  @override
  Future<void> setMuted(bool value) async {}
  @override
  Future<void> setSpeaker(bool value) async {}
  @override
  Future<void> start(String roomId, String matrixUserId, CallMediaType type) async {}
  @override
  Future<void> switchCamera() async {}

  Future<void> close() => _events.close();
}

final class _Player extends VideoPlayerController {
  _Player() : super.file(File('unused'));

  @override
  Future<void> initialize() async {
    value = value.copyWith(isInitialized: true, size: const Size(10, 10));
  }

  @override
  Future<void> play() async {
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }
}

final class _RecordingWakelock extends WakelockPlusPlatformInterface {
  final values = <bool>[];
  var _enabled = false;

  @override
  Future<void> toggle({required bool enable}) async {
    values.add(enable);
    _enabled = enable;
  }

  @override
  Future<bool> get enabled async => _enabled;
}

Future<void> _flushVideoWakelock(WidgetTester tester) async {
  var settled = false;
  VideoViewerPage.debugWakelockSettled().then((_) => settled = true);
  for (var frame = 0; frame < 8 && !settled; frame++) {
    await tester.pump();
  }
  expect(settled, isTrue);
}

void main() {
  late WakelockPlusPlatformInterface originalWakelock;
  late _RecordingWakelock wakelock;

  setUpAll(() {
    originalWakelock = wakelockPlusPlatformInstance;
    wakelock = _RecordingWakelock();
    wakelockPlusPlatformInstance = wakelock;
  });

  setUp(() async {
    wakelock.values.clear();
    await WakelockPlus.toggle(enable: false);
    wakelock.values.clear();
    TestWidgetsFlutterBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDownAll(() {
    wakelockPlusPlatformInstance = originalWakelock;
  });

  testWidgets('disposing a call keeps screen on while video is playing',
      (tester) async {
    final backend = _CallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    final player = _Player();
    late StateSetter setHostState;
    var showCall = true;
    var showVideo = true;
    await tester.pumpWidget(CupertinoApp(
      home: StatefulBuilder(builder: (_, setState) {
        setHostState = setState;
        return Stack(children: [
          if (showVideo)
            VideoViewerPage(
              loadFile: () async => File('unused'),
              controllerFactory: (_) => player,
            ),
          if (showCall)
            CallPage(
              controller: controller,
              displayName: '周然',
              fallbackSeed: 'alice',
            ),
        ]);
      }),
    ));
    await tester.pump();
    await tester.pump();
    await _flushVideoWakelock(tester);

    setHostState(() => showCall = false);
    await tester.pump();
    await _flushVideoWakelock(tester);

    expect(player.value.isPlaying, isTrue);
    expect(wakelock.values.last, isTrue);

    setHostState(() => showVideo = false);
    await tester.pump();
    await _flushVideoWakelock(tester);
    expect(wakelock.values.last, isFalse);
    controller.dispose();
    await backend.close();
  });

  testWidgets('disposing video keeps screen on while a call remains mounted',
      (tester) async {
    final backend = _CallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    final player = _Player();
    late StateSetter setHostState;
    var showCall = true;
    var showVideo = true;
    await tester.pumpWidget(CupertinoApp(
      home: StatefulBuilder(builder: (_, setState) {
        setHostState = setState;
        return Stack(children: [
          if (showVideo)
            VideoViewerPage(
              loadFile: () async => File('unused'),
              controllerFactory: (_) => player,
            ),
          if (showCall)
            CallPage(
              controller: controller,
              displayName: '周然',
              fallbackSeed: 'alice',
            ),
        ]);
      }),
    ));
    await tester.pump();
    await tester.pump();
    await _flushVideoWakelock(tester);

    setHostState(() => showVideo = false);
    await tester.pump();
    await _flushVideoWakelock(tester);
    expect(wakelock.values.last, isTrue);

    setHostState(() => showCall = false);
    await tester.pump();
    await _flushVideoWakelock(tester);
    expect(wakelock.values.last, isFalse);
    controller.dispose();
    await backend.close();
  });
}
