import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/latest_message_anchor.dart';

void main() {
  testWidgets(
      'user gesture cancels pending send jump and receipt cannot rearm it',
      (tester) async {
    final scroll = ScrollController(initialScrollOffset: 150);
    final anchor = LatestMessageAnchor(scroll);
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: ListView.builder(
            controller: scroll,
            reverse: true,
            itemCount: 30,
            itemBuilder: (_, index) =>
                SizedBox(height: 70, child: Text('$index')))));
    anchor.update('new-send', outgoing: true, newSend: true);
    anchor.cancelPending();
    await tester.pump();
    expect(scroll.offset, 150);
    anchor.update('new-send', outgoing: true, newSend: true);
    await tester.pump();
    expect(scroll.offset, 150);
    anchor.update('navigation-send', outgoing: true, newSend: true);
    scroll.jumpTo(220);
    await tester.pump();
    expect(scroll.offset, 220);
    anchor.update('another-send', outgoing: true, newSend: true);
    await tester.pump();
    expect(scroll.offset, 0);
    anchor.dispose();
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  testWidgets('restored outgoing history must not steal reading position',
      (tester) async {
    final scroll = ScrollController(initialScrollOffset: 150);
    final anchor = LatestMessageAnchor(scroll);
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: ListView.builder(
            controller: scroll,
            reverse: true,
            itemCount: 30,
            itemBuilder: (_, index) =>
                SizedBox(height: 70, child: Text('$index')))));
    anchor.update('cached-own-image', outgoing: true);
    await tester.pump();
    expect(scroll.offset, 150,
        reason: 'own historical content is not a new send intent');
    anchor.dispose();
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  testWidgets(
      'new outgoing bubble follows first layout, receipt does not steal scroll',
      (tester) async {
    final scroll = ScrollController(initialScrollOffset: 150);
    final anchor = LatestMessageAnchor(scroll);
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: ListView.builder(
            controller: scroll,
            reverse: true,
            itemCount: 30,
            itemBuilder: (_, index) =>
                SizedBox(height: 70, child: Text('$index')))));
    anchor.update('tx-1', outgoing: true, newSend: true);
    await tester.pump();
    expect(scroll.offset, 0);
    scroll.jumpTo(200);
    anchor.update('tx-1', outgoing: true, newSend: true);
    await tester.pump();
    expect(scroll.offset, 200);
    anchor.update('peer', outgoing: false);
    await tester.pump();
    expect(scroll.offset, 200);
    anchor.dispose();
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });
}
