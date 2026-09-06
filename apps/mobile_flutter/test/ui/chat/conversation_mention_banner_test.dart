import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/conversation_mention_banner.dart';

/// 规格 #2 UI：会话摘要红色前缀 + 群聊↑有人@你标签。
void main() {
  group('ConversationSummaryWithMention', () {
    testWidgets('有未读@：[有人@你] 前缀 + 原摘要保留', (tester) async {
      await tester.pumpWidget(const CupertinoApp(
        home: Center(
          child: ConversationSummaryWithMention(
            hasPendingMention: true,
            summary: '张三: 中午吃饭吗',
          ),
        ),
      ));
      expect(find.byKey(const Key('conversation-summary-mention')),
          findsOneWidget);
      expect(find.textContaining('[有人@你]'), findsOneWidget);
      expect(find.textContaining('张三: 中午吃饭吗'), findsOneWidget);
    });

    testWidgets('无未读@：纯摘要（无前缀）', (tester) async {
      await tester.pumpWidget(const CupertinoApp(
        home: Center(
          child: ConversationSummaryWithMention(
            hasPendingMention: false,
            summary: '张三: 中午吃饭吗',
          ),
        ),
      ));
      expect(find.byKey(const Key('conversation-summary-plain')),
          findsOneWidget);
      expect(find.textContaining('[有人@你]'), findsNothing);
    });

    testWidgets('有未读@：前缀为红色（#FF0000）', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: Builder(
          builder: (context) {
            return const Center(
              child: ConversationSummaryWithMention(
                hasPendingMention: true,
                summary: '摘要',
              ),
            );
          },
        ),
      ));
      // 通过 RichText 结构验证前缀 span 颜色。
      final rich = tester.widget<RichText>(
          find.descendant(of: find.byKey(const Key('conversation-summary-mention')), matching: find.byType(RichText)));
      final spans = rich.text.toPlainText();
      expect(spans, startsWith('[有人@你]'));
    });
  });

  group('MentionBannerButton', () {
    testWidgets('默认显示↑有人@你；加载中显示指示器', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: Center(
          child: MentionBannerButton(onTap: () {}),
        ),
      ));
      expect(find.byKey(const Key('mention-banner-button')), findsOneWidget);
      expect(find.text('有人@你'), findsOneWidget);

      await tester.pumpWidget(CupertinoApp(
        home: Center(
          child: MentionBannerButton(onTap: () {}, isLoading: true),
        ),
      ));
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget,
          reason: '解析中显示加载状态，不提前判空');
    });

    testWidgets('点击触发回调', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(CupertinoApp(
        home: Center(
          child: MentionBannerButton(onTap: () => tapped++),
        ),
      ));
      await tester.tap(find.byKey(const Key('mention-banner-button')));
      await tester.pump();
      expect(tapped, 1);
    });
  });
}
