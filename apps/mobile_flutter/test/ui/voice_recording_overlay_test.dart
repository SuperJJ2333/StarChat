import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/voice_recording_controller.dart';
import 'package:liuhetong_mobile/ui/chat/voice_recording_overlay.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    VoiceRecordingController controller,
    Duration elapsed,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: Stack(
            children: [
              const Center(child: Text('消息列表')),
              Positioned.fill(
                child: VoiceRecordingOverlay(
                  controller: controller,
                  elapsed: elapsed,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('recording overlay fills the page width with reference layout',
      (tester) async {
    final controller = VoiceRecordingController()..start();
    await pump(tester, controller, const Duration(seconds: 3));

    // 全屏宽度：毛玻璃层铺满页面，不再出现左侧局部割裂。
    final overlaySize = tester.getSize(find.byType(VoiceRecordingOverlay));
    expect(
      overlaySize.width,
      moreOrLessEquals(
        tester.view.physicalSize.width / tester.view.devicePixelRatio,
        epsilon: 0.5,
      ),
      reason: '毛玻璃层铺满全屏宽度',
    );
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('滑到这里'), findsOneWidget,
        reason: '对齐参考图右下“转文字”圆形目标区');
    expect(find.text('转文字'), findsOneWidget);
    expect(find.text('松手发送'), findsOneWidget,
        reason: '底部提供“松手发送”目标区');
    expect(find.text('3″ / 60″'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(VoiceRecordingOverlay),
        matching: find.byType(IgnorePointer),
      ),
      findsOneWidget,
    );
  });

  testWidgets('bottom targets are circular zones', (tester) async {
    final controller = VoiceRecordingController()..start();
    await pump(tester, controller, const Duration(seconds: 1));

    for (final key in const [Key('voice-target-cancel'), Key('voice-target-text')]) {
      final container = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle, reason: '$key 必须是圆形目标区');
      expect(decoration.borderRadius, isNull);
      final size = tester.getSize(find.byKey(key));
      expect(size.width, size.height, reason: '$key 必须是正方形圆');
    }
  });

  testWidgets('armed states highlight the matching target zone',
      (tester) async {
    final controller = VoiceRecordingController()..start();
    controller.updateDrag(
      delta: const Offset(0, -80),
      global: const Offset(100, 400),
      page: const Size(390, 844),
    );
    await pump(tester, controller, const Duration(seconds: 5));

    expect(find.text('松开手指，取消发送'), findsOneWidget);
    final cancelZone = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(const Key('voice-target-cancel')),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect((cancelZone.decoration as BoxDecoration).color, isNotNull,
        reason: '取消区武装态高亮');
  });

  testWidgets('send zone arms highlight and prompt', (tester) async {
    final controller = VoiceRecordingController()..start();
    controller.updateDrag(
      delta: const Offset(0, -40),
      global: const Offset(195, 644),
      page: const Size(390, 844),
    );
    await pump(tester, controller, const Duration(seconds: 2));

    expect(controller.state, VoiceRecordingState.sendArmed);
    expect(find.text('松开手指，发送语音'), findsOneWidget);
    final sendZone = tester.widget<AnimatedContainer>(
      find.ancestor(
        of: find.text('松手发送'),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect((sendZone.decoration as BoxDecoration).color, isNotNull,
        reason: '松手发送区武装态高亮');
  });

  testWidgets('60 seconds display is clamped', (tester) async {
    final controller = VoiceRecordingController()..start();
    await pump(tester, controller, const Duration(seconds: 75));
    expect(find.text('60″ / 60″'), findsOneWidget);
  });
}
