import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/voice_recording_controller.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_hold_to_talk.dart';

void main() {
  test('slide above cancellation threshold arms cancellation', () {
    final controller = VoiceRecordingController();
    controller.start();
    controller.updateDrag(-61);
    expect(controller.state, VoiceRecordingState.cancelArmed);
    controller.release(const Duration(seconds: 2));
    expect(controller.state, VoiceRecordingState.idle);
  });

  test('valid recording enters preview before sending', () {
    final controller = VoiceRecordingController();
    controller.start();
    controller.release(const Duration(seconds: 3));
    expect(controller.state, VoiceRecordingState.preview);
  });

  testWidgets('recordings shorter than one second stop and delete the recorder',
      (tester) async {
    final controller = VoiceRecordingController();
    var starts = 0;
    var cancels = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: WeChatHoldToTalk(
          controller: controller,
          onStart: () async => starts++,
          onStop: (_) async {},
          onCancel: () async => cancels++,
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('按住说话')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(starts, 1);
    expect(cancels, 1);
    expect(controller.state, VoiceRecordingState.idle);
  });

  testWidgets('microphone start failures restore the idle recorder state',
      (tester) async {
    final controller = VoiceRecordingController();
    await tester.pumpWidget(
      CupertinoApp(
        home: WeChatHoldToTalk(
          controller: controller,
          onStart: () async => throw Exception('permission denied'),
          onStop: (_) async {},
          onCancel: () async {},
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('按住说话')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.state, VoiceRecordingState.idle);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
