import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_video_message.dart';
import 'package:liuhetong_mobile/ui/notification/notification_readiness_banner.dart';

class _Player extends VideoPlayerController {
  _Player() : super.file(File('unused'));
  @override
  Future<void> initialize() async {
    value = value.copyWith(
        isInitialized: true,
        duration: const Duration(seconds: 60),
        size: const Size(640, 480));
  }

  @override
  Future<void> play() async {
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> seekTo(Duration position) async {
    value = value.copyWith(position: position);
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    value = value.copyWith(playbackSpeed: speed);
  }

}

void main() {
  testWidgets('拖动进度与选择倍速实际更新播放器', (tester) async {
    final player = _Player();
    await tester.pumpWidget(CupertinoApp(
        home: VideoViewerPage(
            loadFile: () async => File('unused'),
            controllerFactory: (_) => player)));
    await tester.pumpAndSettle();
    final slider = tester.widget<CupertinoSlider>(
        find.byKey(const Key('video-viewer-progress')));
    slider.onChanged!(30000);
    await tester.pump();
    expect(player.value.position, const Duration(seconds: 30));
    await tester.tap(find.byKey(const Key('video-viewer-speed')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5×'));
    await tester.pumpAndSettle();
    expect(player.value.playbackSpeed, 1.5);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('未授权持续提示并打开设置，授权后返回自动消失', (tester) async {
    const channel = MethodChannel('chatflow/notification');
    var denied = true;
    var opened = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'openNotificationSettings') {
        opened = true;
        return true;
      }
      return {
        'issues': denied ? ['通知未授权'] : [],
        'fullScreenDenied': false
      };
    });
    await tester
        .pumpWidget(const CupertinoApp(home: NotificationReadinessBanner()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notification-enable-settings')));
    await tester.pump();
    expect(opened, isTrue);
    denied = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notification-enable-settings')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  testWidgets('视频转发调用统一入口，不打开群名单弹窗', (tester) async {
    var forwarded = false;
    await tester.pumpWidget(CupertinoApp(
        home: VideoViewerPage(
      loadFile: () => Completer<File>().future,
      onForward: () async {
        forwarded = true;
      },
    )));
    await tester.tap(find.byKey(const Key('video-viewer-forward')));
    await tester.pump();
    expect(forwarded, isTrue);
    expect(find.byType(CupertinoActionSheet), findsNothing);
    expect(find.byKey(const Key('video-viewer-download')), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpWidget(const SizedBox());
  });
}
