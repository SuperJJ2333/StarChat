import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/chat_composer_bar.dart';
import 'package:liuhetong_mobile/features/matrix/voice_recording_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_composer_state.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_hold_to_talk.dart';

DateTime fakeNow = DateTime(2026, 8, 30, 12);
VoiceRecordingController voiceRecordingController = VoiceRecordingController();
int sent = 0;
int cancelled = 0;


final class _VoiceToggleHarness extends StatefulWidget {
  const _VoiceToggleHarness();

  @override
  State<_VoiceToggleHarness> createState() => _VoiceToggleHarnessState();
}

final class _VoiceToggleHarnessState extends State<_VoiceToggleHarness> {
  static int toggles = 0;
  ComposerPanel panel = ComposerPanel.none;

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 393,
            child: ChatComposerBar(
              controller: TextEditingController(),
              panel: panel,
              onMore: () {},
              onVoice: () {
                debugPrint('MIC TAPPED before=$_VoiceToggleHarnessState.toggles');
                setState(() {
                  _VoiceToggleHarnessState.toggles++;
                  panel = ComposerPanel.voice;
                });
                debugPrint('MIC TAPPED after=$_VoiceToggleHarnessState.toggles panel=$panel');
              },
              onEmoji: () {},
              onSend: () {},
              voiceField: WeChatHoldToTalk(
                controller: voiceRecordingController,
                onStart: () async {},
                onStop: (_) async {},
                onCancel: (_) async {},
              ),
            ),
          ),
        ),
      );
}

void main() {
  setUp(() {
    voiceRecordingController.dispose();
    voiceRecordingController = VoiceRecordingController(nowFactory: () => fakeNow);
    sent = 0;
    cancelled = 0;
    fakeNow = DateTime(2026, 8, 30, 12);
  });

  test('send is visible whenever the composer has text including emoji', () {
    expect(
      const ChatComposerState(
        focused: false,
        hasText: true,
        panel: ComposerPanel.none,
      ).showsSend,
      isTrue,
    );
    expect(
      const ChatComposerState(
        focused: true,
        hasText: true,
        panel: ComposerPanel.none,
      ).showsSend,
      isTrue,
    );
  });

  testWidgets('composer keeps voice input emoji trailing DOM order',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 393,
              child: ChatComposerBar(
                controller: controller,
                focusNode: focusNode,
                onMore: () {},
                onVoice: () {},
                onEmoji: () {},
                onSend: () {},
              ),
            ),
          ),
        ),
      ),
    );

    final voice = find.byKey(const Key('composer-voice'));
    final input = find.byKey(const Key('composer-input'));
    final emoji = find.byKey(const Key('composer-emoji'));
    final more = find.byKey(const Key('composer-more'));
    expect(find.byKey(const Key('chat-composer')), findsOneWidget);
    expect(find.byKey(const Key('composer-send')), findsNothing);
    expect(tester.getTopLeft(voice).dx, lessThan(tester.getTopLeft(input).dx));
    expect(tester.getTopLeft(input).dx, lessThan(tester.getTopLeft(emoji).dx));
    expect(tester.getTopLeft(emoji).dx, lessThan(tester.getTopLeft(more).dx));
    for (final finder in [voice, emoji, more]) {
      final size = tester.getSize(finder);
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
    expect(tester.getSize(input).height, greaterThanOrEqualTo(40));
  });

  testWidgets('focused text replaces more with send', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          child: ChatComposerBar(
            controller: controller,
            focusNode: focusNode,
            onMore: () {},
            onVoice: () {},
            onEmoji: () {},
            onSend: () {},
          ),
        ),
      ),
    );
    focusNode.requestFocus();
    controller.text = '明天见';
    await tester.pump();

    expect(find.byKey(const Key('composer-more')), findsNothing);
    expect(find.byKey(const Key('composer-send')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('composer-send'))),
      const Size.square(44),
    );
    final surface = tester.widget<DecoratedBox>(
      find.byKey(const Key('composer-send-surface')),
    );
    expect(
      (surface.decoration as BoxDecoration).color,
      const Color(0xFF06AD56),
    );
  });

  testWidgets('emoji without focus replaces more with pressed send',
      (tester) async {
    final controller = TextEditingController(text: '😀');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          child: ChatComposerBar(
            controller: controller,
            onMore: () {},
            onVoice: () {},
            onEmoji: () {},
            onSend: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('composer-more')), findsNothing);
    expect(find.byKey(const Key('composer-send')), findsOneWidget);
    expect(find.byKey(const Key('composer-send-surface')), findsOneWidget);
  });

  test('voice panel hides send and keyboard-only toggling is exposed', () {
    expect(
      const ChatComposerState(
        focused: false,
        hasText: true,
        panel: ComposerPanel.voice,
      ).showsSend,
      isFalse,
      reason: '语音模式下输入框被“按住说话”替代，不显示发送键',
    );
  });

  testWidgets('tapping the mic button switches to the hold-to-talk field',
      (tester) async {
    // 复现用户路径：默认面板点击麦克风 → 出现“按住说话”，输入框消失。
    await tester.pumpWidget(const CupertinoApp(
      home: _VoiceToggleHarness(),
    ));

    expect(find.text('按住说话'), findsNothing);
    await tester.tap(find.byKey(const Key('composer-voice')));
    await tester.pump();

    expect(_VoiceToggleHarnessState.toggles, 1);
    expect(find.text('按住说话'), findsOneWidget);
    expect(find.byKey(const Key('composer-input')), findsNothing);
  });

  testWidgets('voice panel replaces the input with the hold-to-talk field',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 393,
              child: ChatComposerBar(
                controller: controller,
                panel: ComposerPanel.voice,
                onMore: () {},
                onVoice: () {},
                onEmoji: () {},
                onSend: () {},
                voiceField: WeChatHoldToTalk(
                  controller: voiceRecordingController,
                  onStart: () async {},
                  onStop: (_) async {},
                  onCancel: (_) async {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('composer-input')), findsNothing);
    expect(find.byKey(const Key('composer-keyboard')), findsOneWidget,
        reason: '语音模式提供返回键盘的切换键');
    expect(find.byKey(const Key('composer-voice')), findsNothing);
    expect(find.text('按住说话'), findsOneWidget);
  });

  testWidgets('hold drag arms targets and release on cancel discards',
      (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: WeChatHoldToTalk(
              controller: voiceRecordingController,
              onStart: () async {},
              onStop: (_) async => sent++,
              onCancel: (_) async => cancelled++,
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('按住说话')),
    );
    await tester.pump(const Duration(milliseconds: 900));
    expect(voiceRecordingController.state, VoiceRecordingState.recording);

    // 小幅上滑落在底部“松手发送”带内（不再误触取消）。
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    expect(voiceRecordingController.state, VoiceRecordingState.sendArmed);

    // 继续滑到左下圆形“取消”目标区。
    final page = tester.view.physicalSize / tester.view.devicePixelRatio;
    await gesture.moveTo(Offset(60, page.height - 140));
    await tester.pump();
    expect(voiceRecordingController.state, VoiceRecordingState.cancelArmed);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(cancelled, 1);
    expect(sent, 0);
    expect(voiceRecordingController.state, VoiceRecordingState.idle);
  });

  testWidgets('tapping the input field reports the input tap callback',
      (tester) async {
    var inputTaps = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 393,
              child: ChatComposerBar(
                controller: TextEditingController(),
                panel: ComposerPanel.emoji,
                onMore: () {},
                onVoice: () {},
                onEmoji: () {},
                onSend: () {},
                onInputTap: () => inputTaps++,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('composer-input')));
    await tester.pump();

    expect(inputTaps, 1,
        reason: 'emoji 展开态下点击输入框：收起面板并弹出键盘（回调由页面执行）');
  });

  testWidgets('release without drag sends the voice', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: WeChatHoldToTalk(
              controller: voiceRecordingController,
              onStart: () async {},
              onStop: (_) async => sent++,
              onCancel: (_) async => cancelled++,
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('按住说话')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    fakeNow = fakeNow.add(const Duration(seconds: 2));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(sent, 1);
    expect(cancelled, 0);
  });
}
