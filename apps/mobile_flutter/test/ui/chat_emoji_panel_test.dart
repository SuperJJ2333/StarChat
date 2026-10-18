import 'dart:typed_data';

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';
import 'package:liuhetong_mobile/features/emoji/static_emoji_recent_store.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_emoji_catalog.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_vector_emoji_catalog.dart';
import 'package:liuhetong_mobile/ui/chat/chat_emoji_panel.dart';

class _HeldPreferences extends InMemorySharedPreferencesStore {
  _HeldPreferences(super.data) : super.withData();

  final release = Completer<void>();
  bool readStarted = false;

  @override
  Future<Map<String, Object>> getAll() async {
    readStarted = true;
    await release.future;
    return super.getAll();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget accountPanel(String accountId,
          {Key? key, ValueChanged<String>? onSelected}) =>
      CupertinoApp(
          home: Center(
              child: SizedBox(
                  width: 393,
                  height: 360,
                  child: ChatEmojiPanel(
                      key: key,
                      accountId: accountId,
                      onEmojiSelected: onSelected ?? (_) {},
                      onDynamicEmojiSelected: (_) {},
                      customItems: const [],
                      onCustomSelected: (_) {}))));

  testWidgets('tab change during emoji fling releases maintenance interaction',
      (tester) async {
    await tester.pumpWidget(accountPanel(''));
    await tester.pumpAndSettle();
    await tester.fling(find.byKey(const Key('vector-emoji-grid')),
        const Offset(0, -250), 2800);
    await tester.pump(const Duration(milliseconds: 16));
    bool panelIsInteractive() => MaintenanceActivity.instance.activeReasons
        .any((reason) => reason.startsWith('emoji-panel-'));
    expect(panelIsInteractive(), isTrue,
        reason: 'the test must replace a genuinely scrolling grid');
    await tester.tap(find.byKey(const Key('emoji-tab-custom')));
    await tester.pump();
    final releasedOnTabChange = !panelIsInteractive();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(releasedOnTabChange, isTrue,
        reason: 'retired grid scroll activity must not block background work');
    expect(panelIsInteractive(), isFalse);
  });

  testWidgets('persisted recent 16 form two rows of eight newest first',
      (tester) async {
    final store = StaticEmojiRecentStore(accountId: 'alice');
    SharedPreferences.setMockInitialValues({
      store.storageKey:
          vectorEmojis.take(18).map((e) => e.char).toList().reversed.toList()
    });
    await tester.pumpWidget(accountPanel('alice'));
    await tester.pumpAndSettle();
    final recent = find.byKey(const Key('recent-static-emoji-grid'));
    expect(recent, findsOneWidget);
    final grid = tester.widget<SliverGrid>(recent);
    expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        8);
    expect(grid.delegate.estimatedChildCount, 16);
    final newest =
        find.byKey(Key('recent-static-emoji-${vectorEmojis[17].name}'));
    final eighth =
        find.byKey(Key('recent-static-emoji-${vectorEmojis[10].name}'));
    final ninth =
        find.byKey(Key('recent-static-emoji-${vectorEmojis[9].name}'));
    final oldest =
        find.byKey(Key('recent-static-emoji-${vectorEmojis[2].name}'));
    expect(tester.getCenter(newest).dy, tester.getCenter(eighth).dy);
    expect(tester.getCenter(ninth).dy, tester.getCenter(oldest).dy);
    expect(tester.getCenter(newest).dy, lessThan(tester.getCenter(ninth).dy));
    expect(tester.getCenter(newest).dx, lessThan(tester.getCenter(eighth).dx));
    expect(tester.getCenter(ninth).dx, tester.getCenter(newest).dx);
  });

  testWidgets(
      'recent click inserts once and new selection survives panel reopen',
      (tester) async {
    String? selected;
    var calls = 0;
    final store = StaticEmojiRecentStore(accountId: 'alice');
    SharedPreferences.setMockInitialValues({
      store.storageKey: [vectorEmojis[1].char]
    });
    await tester.pumpWidget(
        accountPanel('alice', key: const Key('first'), onSelected: (value) {
      selected = value;
      calls++;
    }));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(Key('recent-static-emoji-${vectorEmojis[1].name}')));
    await tester.pumpAndSettle();
    expect(selected, vectorEmojis[1].char);
    expect(calls, 1);
    await tester.tap(find.byKey(Key('vector-emoji-${vectorEmojis[0].name}')));
    await tester.pumpAndSettle();
    expect(selected, vectorEmojis[0].char);
    expect(calls, 2);
    await tester.pumpWidget(accountPanel('alice', key: const Key('reopened')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vector-emoji-grid')), findsOneWidget);
    expect(find.byKey(Key('recent-static-emoji-${vectorEmojis[0].name}')),
        findsOneWidget);
    expect(find.byKey(Key('recent-static-emoji-${vectorEmojis[1].name}')),
        findsOneWidget);
    expect(
        tester
            .widget<SliverGrid>(
                find.byKey(const Key('recent-static-emoji-grid')))
            .delegate
            .estimatedChildCount,
        2);
  });

  testWidgets('recent targets stay fixed for repeated taps until panel reopens',
      (tester) async {
    final store = StaticEmojiRecentStore(accountId: 'alice');
    final original = vectorEmojis.take(3).map((emoji) => emoji.char).toList();
    SharedPreferences.setMockInitialValues({store.storageKey: original});
    final selected = <String>[];
    await tester.pumpWidget(accountPanel('alice',
        key: const Key('stable-open'), onSelected: selected.add));
    await tester.pumpAndSettle();
    final targets = [
      for (final emoji in vectorEmojis.take(3))
        find.byKey(Key('recent-static-emoji-${emoji.name}'))
    ];
    final positions = targets.map(tester.getCenter).toList();
    await tester.tapAt(positions[1]);
    await tester.pumpAndSettle();
    expect(targets.map(tester.getCenter).toList(), positions);
    await tester.tapAt(positions[1]);
    await tester.pumpAndSettle();
    expect(selected, [vectorEmojis[1].char, vectorEmojis[1].char]);
    await tester.tap(find.byKey(Key('vector-emoji-${vectorEmojis[3].name}')));
    await tester.pumpAndSettle();
    expect(targets.map(tester.getCenter).toList(), positions);
    expect(find.byKey(Key('recent-static-emoji-${vectorEmojis[3].name}')),
        findsNothing);
    expect(await store.load(), [
      vectorEmojis[3].char,
      vectorEmojis[1].char,
      vectorEmojis[0].char,
      vectorEmojis[2].char
    ]);
    await tester.pumpWidget(accountPanel('alice', key: const Key('next-open')));
    await tester.pumpAndSettle();
    final newest =
        find.byKey(Key('recent-static-emoji-${vectorEmojis[3].name}'));
    expect(tester.getCenter(newest), positions.first);
  });

  testWidgets('late initial recents load cannot move targets after selection',
      (tester) async {
    final store = StaticEmojiRecentStore(accountId: 'alice');
    final platform = _HeldPreferences({
      'flutter.${store.storageKey}': [vectorEmojis[1].char]
    });
    SharedPreferencesStorePlatform.instance = platform;
    addTearDown(() async {
      if (!platform.release.isCompleted) platform.release.complete();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await store.load();
      SharedPreferences.setMockInitialValues({});
    });
    final selected = <String>[];
    await tester.pumpWidget(accountPanel('alice',
        key: const Key('held-open'), onSelected: selected.add));
    await tester.pump();
    expect(platform.readStarted, isTrue);
    expect(find.byKey(const Key('recent-static-emoji-grid')), findsNothing);
    final target = find.byKey(Key('vector-emoji-${vectorEmojis[0].name}'));
    final position = tester.getCenter(target);
    await tester.tap(target);
    platform.release.complete();
    await tester.pumpAndSettle();
    expect(selected, [vectorEmojis[0].char]);
    expect(tester.getCenter(target), position);
    expect(find.byKey(const Key('recent-static-emoji-grid')), findsNothing);
    expect(await store.load(), [vectorEmojis[0].char, vectorEmojis[1].char]);
    await tester
        .pumpWidget(accountPanel('alice', key: const Key('after-held')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('recent-static-emoji-${vectorEmojis[0].name}')),
        findsOneWidget);
  });

  testWidgets('account switch cannot display previous account recents',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      StaticEmojiRecentStore(accountId: 'alice').storageKey: [
        vectorEmojis[0].char
      ],
      StaticEmojiRecentStore(accountId: 'bob').storageKey: [
        vectorEmojis[1].char
      ],
    });
    await tester.pumpWidget(accountPanel('alice'));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('recent-static-emoji-${vectorEmojis[0].name}')),
        findsOneWidget);
    await tester.pumpWidget(accountPanel('bob'));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('recent-static-emoji-${vectorEmojis[0].name}')),
        findsNothing);
    expect(find.byKey(Key('recent-static-emoji-${vectorEmojis[1].name}')),
        findsOneWidget);
  });

  testWidgets('selection does not insert recent rows into the open panel',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: SizedBox(
            height: 320,
            child: ChatEmojiPanel(
                initialTab: ChatEmojiTab.smiley,
                onEmojiSelected: (_) {},
                onDynamicEmojiSelected: (_) {},
                customItems: const [],
                onCustomSelected: (_) {}))));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(Key('vector-emoji-${vectorEmojis.first.name}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recent-static-emoji-grid')), findsNothing);
    expect(find.byKey(Key('recent-static-emoji-${vectorEmojis.first.name}')),
        findsNothing);
  });

  testWidgets('every fresh panel opens static even after choosing dynamic',
      (tester) async {
    Widget panel(Key key) => CupertinoApp(
        home: SizedBox(
            height: 320,
            child: ChatEmojiPanel(
                key: key,
                onEmojiSelected: (_) {},
                onDynamicEmojiSelected: (_) {},
                customItems: const [],
                onCustomSelected: (_) {})));
    await tester.pumpWidget(panel(const Key('first-open')));
    await tester.pump();
    expect(find.byKey(const Key('vector-emoji-grid')), findsOneWidget);
    expect(find.byKey(const Key('fluent-emoji-grid')), findsNothing);
    await tester.tap(find.byKey(const Key('emoji-tab-super')));
    await tester.pump();
    expect(find.byKey(const Key('fluent-emoji-grid')), findsOneWidget);
    await tester.pumpWidget(panel(const Key('second-open')));
    await tester.pump();
    expect(find.byKey(const Key('vector-emoji-grid')), findsOneWidget);
    expect(find.byKey(const Key('fluent-emoji-grid')), findsNothing);
  });

  testWidgets('vector emoji tab renders and emits its unicode character',
      (tester) async {
    String? selected;
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          height: 320,
          child: ChatEmojiPanel(
            onDynamicEmojiSelected: (_) {},
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

  testWidgets('static-only composer hides dynamic tab and opens static grid',
      (tester) async {
    String? selected;
    await tester.pumpWidget(CupertinoApp(
        home: SizedBox(
            height: 320,
            child: ChatEmojiPanel(
              allowDynamicEmojis: false,
              onEmojiSelected: (char) => selected = char,
              onDynamicEmojiSelected: (_) => fail(
                  'static-only composer must never emit dynamic selection'),
              customItems: const [],
              onCustomSelected: (_) {},
            ))));
    await tester.pump();
    expect(find.byKey(const Key('emoji-tab-super')), findsNothing);
    expect(find.byKey(const Key('fluent-emoji-grid')), findsNothing);
    await tester
        .tap(find.byKey(Key('vector-emoji-${vectorEmojis.first.name}')));
    expect(selected, vectorEmojis.first.char);
  });

  testWidgets('fluent emoji grid renders bundled animated emojis',
      (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          height: 320,
          child: ChatEmojiPanel(
            initialTab: ChatEmojiTab.superEmoji,
            onDynamicEmojiSelected: (_) {},
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
    // 显式选择超级表情栏，保持动态网格行为。
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
            initialTab: ChatEmojiTab.superEmoji,
            onDynamicEmojiSelected: (char) => selected = char,
            onEmojiSelected: (_) =>
                fail('dynamic emoji must not insert into draft'),
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
            onDynamicEmojiSelected: (_) {},
            onEmojiSelected: (_) {},
            customItems: [
              CustomEmojiItem(id: 'gif-1', bytes: gif, isAnimated: true),
            ],
            onCustomSelected: (_) {},
          ),
        ),
      ),
    );

    await tester.pump();
    final image = tester.widget<Image>(find.byKey(const Key('custom-gif-1')));
    expect(image.image, isA<ResizeImage>());
    expect(image.gaplessPlayback, isTrue);
  });

  testWidgets('long press offers deletion and removes item only after success',
      (tester) async {
    var deleted = 0;
    await tester.pumpWidget(CupertinoApp(
        home: SizedBox(
            height: 320,
            child: ChatEmojiPanel(
                initialTab: ChatEmojiTab.custom,
                onDynamicEmojiSelected: (_) {},
                onEmojiSelected: (_) {},
                onCustomSelected: (_) {},
                onCustomRemoved: (_) async {
                  deleted++;
                },
                customItems: [
                  CustomEmojiItem(
                      id: 'delete-me',
                      isAnimated: false,
                      loadPreview: () async => Uint8List(0))
                ]))));
    await tester.pump();
    await tester.longPress(find.byKey(const Key('custom-button-delete-me')));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);
    expect(deleted, 0);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
    expect(find.byKey(const Key('custom-button-delete-me')), findsNothing);
  });

  testWidgets('switching tabs keeps the three-icon state in sync',
      (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          height: 320,
          child: ChatEmojiPanel(
            onDynamicEmojiSelected: (_) {},
            onEmojiSelected: (_) {},
            customItems: const [],
            onCustomSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    // 默认静态栏。
    expect(find.byKey(const Key('vector-emoji-grid')), findsOneWidget);

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
