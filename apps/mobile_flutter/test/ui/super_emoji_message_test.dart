import 'dart:async';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:liuhetong_mobile/ui/chat/emoji_resource_glyph.dart';
import 'package:liuhetong_mobile/ui/chat/emoji_text.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_emoji_catalog.dart';
import 'package:liuhetong_mobile/ui/chat/super_emoji_message.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';

final class _PendingSupportPaths extends PathProviderPlatform {
  final pending = Completer<String?>();
  @override
  Future<String?> getApplicationSupportPath() => pending.future;
}

FluentEmoji _emoji(String name) =>
    FluentEmoji(char: '😀', name: name, asset: 'assets/emoji/$name.webp');

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester
      .pumpWidget(CupertinoApp(home: CupertinoPageScaffold(child: child)));
  await tester.pump();
}

void main() {
  // Run before any other animated glyph initializes the process-wide store.
  testWidgets(
      'single super emoji keeps 96px neutral startup and offline vector fallback',
      (tester) async {
    final previous = PathProviderPlatform.instance;
    final paths = _PendingSupportPaths();
    PathProviderPlatform.instance = paths;
    addTearDown(() => PathProviderPlatform.instance = previous);
    await _pump(
        tester,
        SuperEmojiMessage(
          emojis: [_emoji('smile')],
          direction: MessageDirection.incoming,
        ));
    final glyph = find.byType(EmojiResourceGlyph);
    expect(tester.widget<EmojiResourceGlyph>(glyph).size, 96);
    expect(tester.getSize(glyph), const Size(96, 96));
    expect(find.byType(SvgPicture), findsNothing);
    expect(find.byType(Image), findsNothing);

    paths.pending.completeError(StateError('support directory offline'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SvgPicture), findsOneWidget);
    final vector = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(vector.width, 96);
    expect(vector.height, 96);
    expect(tester.getSize(glyph), const Size(96, 96));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('four super emojis stay inside a narrow message row',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
        tester,
        SuperEmojiMessage(
          emojis: List.generate(4, (_) => _emoji('smile')),
          direction: MessageDirection.incoming,
          avatar: const SizedBox(width: 40, height: 40),
          senderName: 'Test sender',
        ));
    expect(tester.takeException(), isNull);
    expect(find.byType(EmojiVectorGlyph), findsNWidgets(4));
    final rects = find
        .byType(EmojiVectorGlyph)
        .evaluate()
        .map((element) => tester.getRect(find.byWidget(element.widget)))
        .toList();
    expect(rects.every((rect) => rect.left >= 0 && rect.right <= 360), isTrue);
  });

  testWidgets(
      'legacy multiple super emojis remain static and retain row metadata',
      (tester) async {
    await _pump(
      tester,
      SuperEmojiMessage(
        emojis: [_emoji('smile'), _emoji('joy')],
        direction: MessageDirection.incoming,
        avatar: const SizedBox(width: 40, height: 40),
        senderName: 'Legacy sender',
      ),
    );

    expect(find.byType(EmojiResourceGlyph), findsNothing);
    expect(find.byType(SvgPicture), findsNWidgets(2));
    expect(find.byKey(const Key('message-avatar-slot')), findsOneWidget);
    expect(find.text('Legacy sender'), findsOneWidget);
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

    await tester.longPress(find.byType(EmojiResourceGlyph));
    // 动画图像持续调度帧，不能 pumpAndSettle，用固定时长等待手势完成。
    await tester.pump(const Duration(milliseconds: 300));
    expect(longPressed, isTrue);
  });
}
