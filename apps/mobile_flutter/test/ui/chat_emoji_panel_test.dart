import 'dart:typed_data';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/chat_emoji_panel.dart';

void main() {
  testWidgets('emoji panel exposes recent all and private custom tabs',
      (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          height: 320,
          child: ChatEmojiPanel(
            onEmojiSelected: (_) {},
            customItems: const [],
            onCustomSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('最近'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('我的表情'), findsOneWidget);
    expect(find.byType(EmojiPicker), findsOneWidget);
  });

  testWidgets('animated custom emoji is rendered by Image.memory',
      (tester) async {
    final gif = Uint8List.fromList(const [
      71,
      73,
      70,
      56,
      57,
      97,
      1,
      0,
      1,
      0,
      128,
      0,
      0,
      0,
      0,
      0,
      255,
      255,
      255,
      33,
      249,
      4,
      1,
      0,
      0,
      0,
      0,
      44,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      2,
      2,
      68,
      1,
      0,
      59,
    ]);
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          height: 320,
          child: ChatEmojiPanel(
            initialTab: ChatEmojiTab.custom,
            onEmojiSelected: (_) {},
            customItems: [
              CustomEmojiItem(id: 'gif-1', bytes: gif, isAnimated: true),
            ],
            onCustomSelected: (_) {},
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byKey(const Key('custom-gif-1')));
    expect(image.image, isA<MemoryImage>());
    expect(image.gaplessPlayback, isTrue);
  });
}
