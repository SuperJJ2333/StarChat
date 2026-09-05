import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_emoji_catalog.dart';
import 'package:liuhetong_mobile/ui/chat/super_emoji_message.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';

FluentEmoji _emoji(String name) =>
    FluentEmoji(char: '😀', name: name, asset: 'assets/emoji/$name.webp');

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(CupertinoApp(home: CupertinoPageScaffold(child: child)));
  await tester.pump();
}

void main() {
  testWidgets('single super emoji renders 96px with high quality filter',
      (tester) async {
    await _pump(
      tester,
      SuperEmojiMessage(
        emojis: [_emoji('smile')],
        direction: MessageDirection.incoming,
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.width, 96);
    expect(image.height, 96);
    expect(image.filterQuality, FilterQuality.high);
    expect(image.gaplessPlayback, isTrue);
  });

  testWidgets('multiple super emojis render at 64px', (tester) async {
    await _pump(
      tester,
      SuperEmojiMessage(
        emojis: [_emoji('smile'), _emoji('joy')],
        direction: MessageDirection.incoming,
      ),
    );

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, hasLength(2));
    for (final image in images) {
      expect(image.width, 64);
      expect(image.height, 64);
    }
  });

  testWidgets('incoming super emoji shows avatar slot and sender name',
      (tester) async {
    await _pump(
      tester,
      SuperEmojiMessage(
        emojis: [_emoji('smile')],
        direction: MessageDirection.incoming,
        senderName: '小明',
        avatar: const ColoredBox(color: Color(0xFF888888)),
      ),
    );

    expect(find.byKey(const Key('message-avatar-slot')), findsOneWidget);
    expect(find.text('小明'), findsOneWidget);
  });

  testWidgets('outgoing super emoji shows own avatar without sender name',
      (tester) async {
    await _pump(
      tester,
      SuperEmojiMessage(
        emojis: [_emoji('smile')],
        direction: MessageDirection.outgoing,
        avatar: const ColoredBox(color: Color(0xFF888888)),
      ),
    );

    expect(find.byKey(const Key('message-avatar-slot')), findsOneWidget);
    expect(find.byKey(const Key('message-sender-name')), findsNothing);
  });

  testWidgets('super emoji content is rendered without a bubble decoration',
      (tester) async {
    await _pump(
      tester,
      SuperEmojiMessage(
        emojis: [_emoji('smile')],
        direction: MessageDirection.incoming,
      ),
    );

    // 无气泡：表情行外不应出现 DecoratedBox 气泡背景。
    final bubble = tester.widget<WeChatMessageBubble>(
      find.byType(WeChatMessageBubble),
    );
    expect(bubble.decorateContent, isFalse);
  });

  testWidgets('long press on the emoji row is forwarded', (tester) async {
    var longPressed = false;
    await _pump(
      tester,
      SuperEmojiMessage(
        emojis: [_emoji('smile')],
        direction: MessageDirection.incoming,
        onLongPress: () => longPressed = true,
      ),
    );

    await tester.longPress(find.byType(Image));
    // 动画图像持续调度帧，不能 pumpAndSettle，用固定时长等待手势完成。
    await tester.pump(const Duration(milliseconds: 300));
    expect(longPressed, isTrue);
  });
}
