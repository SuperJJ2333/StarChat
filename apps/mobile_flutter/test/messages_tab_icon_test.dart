import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/messages_tab_icon.dart';

void main() {
  testWidgets(
      'inactive Messages longpress haptics and animates for 300ms while clear pending',
      (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final pending = Completer<void>();
    var clears = 0;
    await tester.pumpWidget(CupertinoApp(
        home: Center(
            child: MessagesTabIcon(
      unreadCount: 5,
      active: false,
      onClearUnread: () {
        clears++;
        return pending.future;
      },
    ))));
    await tester.longPress(find.byType(MessagesTabIcon));
    await tester.pump(const Duration(milliseconds: 75));
    expect(clears, 1);
    expect(
        calls.any((call) =>
            call.method == 'HapticFeedback.vibrate' &&
            call.arguments == 'HapticFeedbackType.mediumImpact'),
        isTrue);
    expect(
        tester
            .widget<ScaleTransition>(find.byType(ScaleTransition))
            .scale
            .value,
        lessThan(1));
    await tester.pump(const Duration(milliseconds: 225));
    expect(
        tester
            .widget<ScaleTransition>(find.byType(ScaleTransition))
            .scale
            .value,
        1);
    pending.complete();
    await tester.pump();
  });
  testWidgets('reduce motion skips scaling and clear errors are handled',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Center(
                child: MessagesTabIcon(
              unreadCount: 1,
              active: true,
              onClearUnread: () async {
                throw StateError('clear failed');
              },
            )))));
    await tester.longPress(find.byType(MessagesTabIcon));
    await tester.pump(const Duration(milliseconds: 75));
    expect(
        tester
            .widget<ScaleTransition>(find.byType(ScaleTransition))
            .scale
            .value,
        1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('tab bar clears Messages while other page remains selected',
      (tester) async {
    var clears = 0;
    final tabs = CupertinoTabController(initialIndex: 1);
    addTearDown(tabs.dispose);
    await tester.pumpWidget(CupertinoApp(
        home: CupertinoTabScaffold(
      controller: tabs,
      tabBar: CupertinoTabBar(items: [
        BottomNavigationBarItem(
            icon: MessagesTabIcon(
                unreadCount: 4,
                active: false,
                onClearUnread: () async {
                  clears++;
                }),
            label: '消息'),
        const BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.person), label: '我'),
      ]),
      tabBuilder: (_, index) =>
          Center(child: Text(index == 0 ? 'Messages page' : 'Profile page')),
    )));
    expect(find.text('Profile page'), findsOneWidget);
    expect(find.text('Messages page'), findsNothing);
    await tester.longPress(find.byType(MessagesTabIcon));
    await tester.pumpAndSettle();
    expect(clears, 1);
    expect(tabs.index, 1);
    expect(find.text('Profile page'), findsOneWidget);
  });
}
