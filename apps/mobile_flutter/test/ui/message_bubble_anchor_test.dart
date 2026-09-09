import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';

void main() {
  for (final direction in MessageDirection.values) {
    testWidgets('$direction menu anchor excludes avatar name timestamp and quote', (tester) async {
      final anchor = GlobalKey();
      await tester.pumpWidget(CupertinoApp(home: Column(children: [
        const Text('12:00'),
        WeChatMessageBubble(direction: direction, bubbleKey: anchor,
          senderName: 'Name', avatar: const SizedBox.square(dimension: 40), content: const Text('Hi')),
        const Text('Quoted content'),
      ])));
      final bubble = tester.getRect(find.byKey(anchor));
      final row = tester.getRect(find.byType(WeChatMessageBubble));
      final avatar = tester.getRect(find.byKey(const Key('message-avatar-slot')));
      expect(bubble.width, lessThan(row.width / 2));
      expect(bubble.overlaps(avatar), isFalse);
      expect(bubble.overlaps(tester.getRect(find.text('12:00'))), isFalse);
      expect(bubble.overlaps(tester.getRect(find.text('Quoted content'))), isFalse);
      if (direction == MessageDirection.outgoing) { expect(bubble.right, closeTo(avatar.left - 8, .1)); }
      else { expect(bubble.left, closeTo(avatar.right + 8, .1)); }
    });
  }
}
