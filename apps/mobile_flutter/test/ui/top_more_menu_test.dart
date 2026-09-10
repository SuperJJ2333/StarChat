import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/top_more_menu.dart';

void main() {
  testWidgets('top more has four full-width vertical actions and dividers',
      (tester) async {
    var selected = '';
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                onPressed: () => showTopMoreMenu(context,
                    onCreateGroup: () => selected = 'group',
                    onAddFriend: () => selected = 'friend',
                    onScan: () => selected = 'scan',
                    onAppearance: () => selected = 'appearance'),
                child: const Text('more')))));
    await tester.tap(find.text('more'));
    await tester.pumpAndSettle();
    const labels = ['发起群聊', '添加朋友', '扫一扫', '外观'];
    final rects =
        labels.map((label) => tester.getRect(find.text(label))).toList();
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].top, greaterThan(rects[i - 1].bottom));
    }
    expect(find.byKey(const Key('top-more-divider-0')), findsOneWidget);
    expect(find.byKey(const Key('top-more-divider-1')), findsOneWidget);
    expect(find.byKey(const Key('top-more-divider-2')), findsOneWidget);
    final row = tester.getRect(find.byKey(const Key('top-more-scan')));
    expect(row.width, lessThanOrEqualTo(180));
    final icon = tester.getRect(find.descendant(
        of: find.byKey(const Key('top-more-scan')),
        matching: find.byType(Icon)));
    final label = tester.getRect(find.text('扫一扫'));
    expect((icon.left + label.right) / 2, closeTo(row.center.dx, .5));
    expect(row.height, 52);
    await tester.tapAt(Offset(row.right - 8, row.center.dy));
    await tester.pumpAndSettle();
    expect(selected, 'scan');
    expect(find.text('发起群聊'), findsNothing);
  });

  testWidgets('top menu stays usable at large text and narrow viewport',
      (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var selected = false;
    await tester.pumpWidget(CupertinoApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: Builder(
            builder: (context) => CupertinoButton(
                onPressed: () => showTopMoreMenu(context,
                    onCreateGroup: () {},
                    onAddFriend: () {},
                    onScan: () {},
                    onAppearance: () => selected = true),
                child: const Text('more')))));
    await tester.tap(find.text('more'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
  });
}
