import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/voice_recording_controller.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_hold_to_talk.dart';

void main() {
  // 目标区几何：与覆盖层绘制共用常量（390x844 逻辑分辨率）。
  // 目标行位于距底 [targetRowBottomInset, +targetRowHeight]，
  // 命中带放宽后为距底 [110, 330]；左右圆心 dx≈60/330。
  const page = Size(390, 844);
  final leftCircle = Offset(60, page.height - 200);
  final rightCircle = Offset(330, page.height - 200);
  final sendZone = Offset(195, page.height - 200);

  test('slide above cancellation threshold arms cancellation', () {
    final controller = VoiceRecordingController();
    controller.start();
    controller.updateDrag(
      delta: const Offset(0, -61),
      global: const Offset(100, 400),
      page: page,
    );
    expect(controller.state, VoiceRecordingState.cancelArmed);
    controller.release(const Duration(seconds: 2));
    expect(controller.state, VoiceRecordingState.idle);
  });

  test('sliding into the left circle target arms cancel', () {
    final controller = VoiceRecordingController();
    controller.start();
    controller.updateDrag(
      delta: const Offset(-40, 40),
      global: leftCircle,
      page: page,
    );
    expect(controller.state, VoiceRecordingState.cancelArmed);
  });

  test('sliding into the right circle target arms text even while moving up',
      () {
    final controller = VoiceRecordingController();
    controller.start();
    // 回归：滑向右圆必有大幅上滑位移，带内命中必须优先于
    // “上滑取消”快捷手势，否则转文字永远无法触发。
    controller.updateDrag(
      delta: const Offset(120, -160),
      global: rightCircle,
      page: page,
    );
    expect(controller.state, VoiceRecordingState.textArmed);
    controller.release(const Duration(seconds: 2));
    expect(controller.state, VoiceRecordingState.idle,
        reason: '转文字武装态松手由上层取回识别结果，控制器回 idle');
  });

  test('sliding into the middle bottom zone arms send', () {
    final controller = VoiceRecordingController();
    controller.start();
    controller.updateDrag(
      delta: const Offset(0, -40),
      global: sendZone,
      page: page,
    );
    expect(controller.state, VoiceRecordingState.sendArmed);
  });

  test('releasing in the send zone enters preview and sends', () {
    final controller = VoiceRecordingController();
    controller.start();
    controller.updateDrag(
      delta: const Offset(0, -40),
      global: sendZone,
      page: page,
    );
    controller.release(const Duration(seconds: 3));
    expect(controller.state, VoiceRecordingState.preview);
  });

  test('leaving the target band disarms back to recording', () {
    final controller = VoiceRecordingController();
    controller.start();
    controller.updateDrag(
      delta: const Offset(0, -40),
      global: sendZone,
      page: page,
    );
    // 手指下滑离开命中带（未到上滑取消阈值）→ 回到普通录音态。
    controller.updateDrag(
      delta: const Offset(0, 60),
      global: Offset(sendZone.dx, page.height - 40),
      page: page,
    );
    expect(controller.state, VoiceRecordingState.recording);
  });

  test('release duration is clamped to the 60 second maximum', () {
    final controller = VoiceRecordingController();
    controller.start();
    controller.release(const Duration(minutes: 2));
    expect(controller.state, VoiceRecordingState.preview);
    expect(controller.duration, const Duration(seconds: 60));
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
          onCancel: (_) async => cancels++,
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
          onCancel: (_) async {},
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
