import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/latest_message_anchor.dart';

void main() {
  testWidgets('new outgoing bubble follows first layout, receipt does not steal scroll', (tester) async {
    final scroll = ScrollController(initialScrollOffset: 150);
    final anchor = LatestMessageAnchor(scroll);
    await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr,
      child: ListView.builder(controller: scroll, reverse: true,
        itemCount: 30, itemBuilder: (_, index) => SizedBox(height: 70, child: Text('$index')))));
    anchor.update('tx-1', outgoing: true);
    await tester.pump();
    expect(scroll.offset, 0);
    scroll.jumpTo(200);
    anchor.update('tx-1', outgoing: true);
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
