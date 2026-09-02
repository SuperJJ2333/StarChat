import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_emoji_catalog.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_vector_emoji_catalog.dart';
import 'package:liuhetong_mobile/ui/chat/chat_emoji_panel.dart';

void main() {
  testWidgets('vector emoji tab renders and emits its unicode character',
      (tester) async {
    String? selected;
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          height: 320,
          child: ChatEmojiPanel(
            onEmojiSelected: (char) => selected = char,
            customItems: const [],
            onCustomSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    // 三栏图标标签（无文字）：笑脸=表情、特效=超级表情、心形=我的表情。
    expect(find.byKey(const Key('emoji-tab-smiley')), findsOneWidget);
    expect(find.byKey(const Key('emoji-tab-super')), findsOneWidget);
    expect(find.byKey(const Key('emoji-tab-custom')), findsOneWidget);
    expect(find.text('全部'), findsNothing);

    await tester.tap(find.byKey(const Key('emoji-tab-smiley')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('vector-emoji-grid')), findsOneWidget);
    final first = vectorEmojis.first;
    await tester.tap(find.byKey(Key('vector-emoji-${first.name}')));
    await tester.pump();
    expect(selected, first.char);
  });

  testWidgets('fluent emoji grid renders bundled animated emojis',
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('最近'), findsNothing);
    // 默认落在“超级表情”栏：动态 Fluent 网格直接可见。
    expect(find.byKey(const Key('emoji-tab-super')), findsOneWidget);
    expect(find.byKey(const Key('emoji-tab-custom')), findsOneWidget);
    expect(find.byKey(const Key('fluent-emoji-grid')), findsOneWidget);
    // 目录中的每个表情都必须有打包资产，且网格渲染首屏条目。
    expect(fluentEmojis.length, greaterThanOrEqualTo(50));
    for (final emoji in fluentEmojis.take(8)) {
      expect(emoji.char, isNotEmpty);
      expect(emoji.asset, startsWith('assets/emoji/'));
    }
  });

  testWidgets('tapping a fluent emoji emits its unicode character',
      (tester) async {
    String? selected;
    final first = fluentEmojis.first;
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          height: 320,
          child: ChatEmojiPanel(
            onEmojiSelected: (char) => selected = char,
            customItems: const [],
            onCustomSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(Key('fluent-emoji-${first.name}')));
    await tester.pump();
    expect(selected, first.char);
  });

  testWidgets('animated custom emoji is rendered by Image.memory',
      (tester) async {
    final gif = Uint8List.fromList(const [
      71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, //
      255, 33, 249, 4, 1, 0, 0, 0, 0, 44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2,
      68, 1, 0, 59,
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

  testWidgets('switching tabs keeps the three-icon state in sync',
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
    await tester.pump();

    // 默认超级表情栏（动态网格可见）。
    expect(find.byKey(const Key('fluent-emoji-grid')), findsOneWidget);

    // 切到“表情”：矢量静态网格完整展示。
    await tester.tap(find.byKey(const Key('emoji-tab-smiley')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vector-emoji-grid')), findsOneWidget);
    expect(find.byKey(const Key('fluent-emoji-grid')), findsNothing);

    // 切到“我的表情”：空态引导可见。
    await tester.tap(find.byKey(const Key('emoji-tab-custom')));
    await tester.pumpAndSettle();
    expect(find.text('长按聊天中的图片或 GIF 添加表情'), findsOneWidget);

    // 回到“超级表情”：动态网格恢复完整展示。
    await tester.tap(find.byKey(const Key('emoji-tab-super')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fluent-emoji-grid')), findsOneWidget);
  });
}
