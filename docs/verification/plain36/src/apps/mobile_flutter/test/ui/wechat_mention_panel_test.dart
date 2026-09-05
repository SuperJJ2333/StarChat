import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_mention_panel.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

void main() {
  test('mention options sort A-Z by remark first, nickname otherwise', () {
    final sorted = sortMentionOptions(const [
      MentionOption(id: 'a', primaryName: '小明', nickname: '小明'),
      MentionOption(id: 'b', primaryName: 'Alice', nickname: 'Alice'),
      MentionOption(id: 'c', primaryName: 'bob', nickname: 'bob'),
      MentionOption(id: 'd', primaryName: '张三', nickname: '张三'),
    ]);

    expect(sorted.map((option) => option.id).toList(), ['b', 'c', 'a', 'd']);
    expect(mentionSectionLetter(sorted[0]), 'A');
    expect(mentionSectionLetter(sorted[3]), '#');
  });

  test('mention search matches remark and nickname', () {
    final filtered = filterMentionOptions(
      const [
        MentionOption(
            id: 'a',
            primaryName: '项目小艾',
            nickname: '艾米',
            hasRemark: true),
        MentionOption(id: 'b', primaryName: '小明', nickname: '小明'),
      ],
      '艾米',
    );
    expect(filtered.single.id, 'a');

    expect(
      filterMentionOptions(
        const [
          MentionOption(
              id: 'a', primaryName: '项目小艾', nickname: '艾米', hasRemark: true),
        ],
        '项目小艾',
      ).single.id,
      'a',
    );

    expect(filterMentionOptions(const [
      MentionOption(id: 'a', primaryName: '小明', nickname: '小明'),
    ], '不存在'), isEmpty);
  });

  testWidgets('panel shows two lines only for remarked members', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: WeChatMentionPanel(
        options: const [
          MentionOption(
              id: '@alice:x',
              primaryName: '项目小艾',
              nickname: '艾米',
              hasRemark: true),
          MentionOption(id: '@bob:x', primaryName: '小明', nickname: '小明'),
        ],
        canMentionAll: false,
        onSelect: (_) {},
      ),
    ));

    expect(find.text('项目小艾'), findsOneWidget);
    expect(find.text('昵称：艾米'), findsOneWidget);
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('昵称：小明'), findsNothing);
  });

  testWidgets('所有人 is pinned first only for admins', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: WeChatMentionPanel(
        options: const [
          MentionOption(id: '@bob:x', primaryName: '小明', nickname: '小明'),
        ],
        canMentionAll: true,
        onSelect: (_) {},
      ),
    ));

    final allTile = find.byKey(const Key('mention-option-all'));
    expect(allTile, findsOneWidget);
    expect(find.text('所有人'), findsOneWidget);
    final memberTile = find.byKey(const Key('mention-option-@bob:x'));
    expect(
      tester.getTopLeft(allTile).dy < tester.getTopLeft(memberTile).dy,
      isTrue,
    );
  });

  testWidgets('selecting an option reports it to the callback',
      (tester) async {
    MentionOption? selected;
    await tester.pumpWidget(CupertinoApp(
      home: WeChatMentionPanel(
        options: const [
          MentionOption(
              id: '@alice:x',
              primaryName: '项目小艾',
              nickname: '艾米',
              hasRemark: true),
        ],
        canMentionAll: true,
        onSelect: (option) => selected = option,
      ),
    ));

    await tester.tap(find.byKey(const Key('mention-option-@alice:x')));
    expect(selected!.id, '@alice:x');
  });

  testWidgets('search box narrows the member list', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: WeChatMentionPanel(
        options: const [
          MentionOption(id: '@alice:x', primaryName: '艾米', nickname: '艾米'),
          MentionOption(id: '@bob:x', primaryName: '小明', nickname: '小明'),
        ],
        canMentionAll: false,
        onSelect: (_) {},
      ),
    ));

    await tester.enterText(find.byKey(const Key('mention-search')), '小明');
    await tester.pump();
    expect(find.byKey(const Key('mention-option-@bob:x')), findsOneWidget);
    expect(find.byKey(const Key('mention-option-@alice:x')), findsNothing);
  });

  testWidgets('secondary nickname line uses the small gray style',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: WeChatMentionPanel(
        options: const [
          MentionOption(
              id: '@alice:x',
              primaryName: '项目小艾',
              nickname: '艾米',
              hasRemark: true),
        ],
        canMentionAll: false,
        onSelect: (_) {},
      ),
    ));

    final nickname = tester.widget<Text>(find.text('昵称：艾米'));
    expect(nickname.style!.fontSize, 12);
    expect(nickname.style!.color, WeChatColors.textSecondary);
  });
}
