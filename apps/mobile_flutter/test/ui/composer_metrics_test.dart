import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_composer.dart';

const _metricsEnabled = bool.fromEnvironment('CHATFLOW_PERFORMANCE_METRICS');

Widget _composer(TextEditingController controller, FocusNode focusNode) {
  return CupertinoApp(
    home: CupertinoPageScaffold(
      child: WeChatComposer(
        key: const ValueKey('metrics-composer'),
        controller: controller,
        focusNode: focusNode,
        onMore: () {},
        onVoice: () {},
        onEmoji: () {},
        onSend: () {},
      ),
    ),
  );
}

void _expectComposerSamples(int expectedCount) {
  final operations =
      PerformanceMetrics.instance.snapshot()['operations'] as Map;
  if (_metricsEnabled) {
    final composer =
        operations[PerformanceOperation.composerToFrame.name] as Map?;
    expect(composer?['count'] ?? 0, expectedCount);
  } else {
    expect(operations, isEmpty,
        reason: 'disabled metrics must not retain real composer input samples');
  }
}

void main() {
  setUp(PerformanceMetrics.instance.reset);
  tearDown(PerformanceMetrics.instance.reset);

  testWidgets('two user edits in one frame record one callback-to-frame sample',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    try {
      await tester.pumpWidget(_composer(controller, focusNode));
      await tester.tap(find.byKey(const Key('composer-input')));
      await tester.pump();
      PerformanceMetrics.instance.reset();

      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'a',
        selection: TextSelection.collapsed(offset: 1),
      ));
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'ab',
        selection: TextSelection.collapsed(offset: 2),
      ));
      await tester.pump();

      // This measures Flutter callback-to-frame scheduling, not IME-to-display.
      _expectComposerSamples(1);
    } finally {
      await tester.pumpWidget(const SizedBox());
      focusNode.dispose();
      controller.dispose();
    }
  });

  testWidgets(
      'programmatic controller and focus changes do not count as typing',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    try {
      await tester.pumpWidget(_composer(controller, focusNode));
      PerformanceMetrics.instance.reset();

      controller.text = 'programmatic';
      focusNode.requestFocus();
      await tester.pump();
      focusNode.unfocus();
      await tester.pump();

      _expectComposerSamples(0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      focusNode.dispose();
      controller.dispose();
    }
  });

  testWidgets('unmounted composer discards a pending input frame sample',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    try {
      await tester.pumpWidget(_composer(controller, focusNode));
      await tester.tap(find.byKey(const Key('composer-input')));
      await tester.pump();
      PerformanceMetrics.instance.reset();

      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'pending',
        selection: TextSelection.collapsed(offset: 7),
      ));
      await tester.pumpWidget(const SizedBox());

      _expectComposerSamples(0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      focusNode.dispose();
      controller.dispose();
    }
  });

  testWidgets('controller replacement discards an old pending input sample',
      (tester) async {
    final first = TextEditingController();
    final second = TextEditingController();
    final focusNode = FocusNode();
    try {
      await tester.pumpWidget(_composer(first, focusNode));
      await tester.tap(find.byKey(const Key('composer-input')));
      await tester.pump();
      PerformanceMetrics.instance.reset();

      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'old',
        selection: TextSelection.collapsed(offset: 3),
      ));
      await tester.pumpWidget(_composer(second, focusNode));
      _expectComposerSamples(0);

      await tester.tap(find.byKey(const Key('composer-input')));
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'new',
        selection: TextSelection.collapsed(offset: 3),
      ));
      await tester.pump();
      _expectComposerSamples(1);
    } finally {
      await tester.pumpWidget(const SizedBox());
      focusNode.dispose();
      first.dispose();
      second.dispose();
    }
  });
}
