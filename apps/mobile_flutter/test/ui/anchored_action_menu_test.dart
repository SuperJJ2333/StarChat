import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/anchored_action_menu.dart';
import 'package:liuhetong_mobile/ui/chat/conversation_action_sheet.dart';

void main() {
  testWidgets(
      'anchored menu fits safe viewport at large font and selects exactly once',
      (tester) async {
    tester.view.resetPhysicalSize();
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var calls = 0;
    await tester.pumpWidget(CupertinoApp(
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
                disableAnimations: true),
            child: Builder(
                builder: (context) => CupertinoPageScaffold(
                    child: Center(
                        child: CupertinoButton(
                            child: const Text('打开'),
                            onPressed: () async {
                              final value = await showAnchoredActionMenu<int>(
                                  context,
                                  anchor: const Rect.fromLTWH(310, 605, 1, 1),
                                  items: [
                                    for (var i = 0; i < 4; i++)
                                      AnchoredMenuItem(
                                          value: i,
                                          icon: CupertinoIcons.pin,
                                          label: '不显示该聊天')
                                  ]);
                              if (value != null) calls++;
                            })))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const Key('anchored-action-menu')));
    expect(rect.left, greaterThanOrEqualTo(8));
    expect(rect.right, lessThanOrEqualTo(312));
    expect(rect.bottom, lessThanOrEqualTo(632));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('不显示该聊天').first);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byKey(const Key('anchored-action-menu')), findsNothing);
  });
  testWidgets(
      'conversation menu preserves actions and dismisses outside without mutation',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoPageScaffold(
                child: Center(
                    child: CupertinoButton(
                        child: const Text('打开'),
                        onPressed: () => showConversationActionSheet(context,
                            pinned: true, onAction: (_) => calls++)))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    for (final label in ['取消置顶', '标记未读', '不显示该聊天', '删除该聊天']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(CupertinoActionSheet), findsNothing);
    await tester.tapAt(const Offset(10, 500));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byKey(const Key('anchored-action-menu')), findsNothing);
  });
}
