import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_call_bubble.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_attachment_tile.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';
import 'package:liuhetong_mobile/ui/components/wechat_contact_tile.dart';
import 'package:liuhetong_mobile/ui/components/network_status_capsule.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';

Widget host(Brightness brightness, Widget child) => CupertinoApp(
      theme: CupertinoThemeData(brightness: brightness),
      home: CupertinoPageScaffold(child: Center(child: child)),
    );

void main() {
  testWidgets('outgoing attachment has readable text on its own dark card',
      (tester) async {
    await tester.pumpWidget(host(
        Brightness.dark,
        const WeChatMessageBubble(
            direction: MessageDirection.outgoing,
            content: WeChatAttachmentTile(
                name: '文件.pdf', progress: 1, showProgress: false))));
    final rich = tester.widget<RichText>(find.descendant(
        of: find.text('文件.pdf'), matching: find.byType(RichText)));
    expect(rich.text.style!.color, WeChatColors.darkTextPrimary);
  });
  testWidgets('network capsule uses a dark translucent surface',
      (tester) async {
    await tester.pumpWidget(
        host(Brightness.dark, NetworkStatusCapsule(onRetry: () {})));
    final box = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(NetworkStatusCapsule),
        matching: find.byType(DecoratedBox)));
    expect((box.decoration as BoxDecoration).color, const Color(0xD9232323));
  });
  testWidgets('contact label changes on live light dark light switch',
      (tester) async {
    const tile = WeChatContactTile(nickname: '联系人', fallbackSeed: 'contact');
    for (final brightness in [
      Brightness.light,
      Brightness.dark,
      Brightness.light
    ]) {
      await tester.pumpWidget(host(brightness, tile));
      expect(
          tester.widget<Text>(find.text('联系人')).style!.color,
          brightness == Brightness.dark
              ? WeChatColors.darkTextPrimary
              : WeChatColors.lightTextPrimary);
    }
  });

  testWidgets(
      'incoming call has readable dark surface and outgoing keeps green contrast',
      (tester) async {
    for (final direction in MessageDirection.values) {
      await tester.pumpWidget(host(
          Brightness.dark,
          WeChatMessageBubble(
            direction: direction,
            content: const WeChatCallBubble(
                video: false, connected: false, duration: Duration.zero),
          )));
      final outgoing = direction == MessageDirection.outgoing;
      final rich = tester.widget<RichText>(find.descendant(
          of: find.byKey(const Key('call-summary-label')),
          matching: find.byType(RichText)));
      expect(rich.text.style!.color,
          outgoing ? CupertinoColors.black : WeChatColors.darkTextPrimary);
      final boxes = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
      expect(
          boxes.any((box) =>
              box.decoration is BoxDecoration &&
              (box.decoration as BoxDecoration).color ==
                  (outgoing
                      ? WeChatColors.bubbleOutgoing
                      : WeChatColors.darkElevated)),
          isTrue);
    }
  });

  testWidgets('moment card resolves background in dark mode', (tester) async {
    final item = MomentItem.fromJson({
      'id': 'm1',
      'author': {'user_id': 'u1', 'nickname': 'Alice'},
      'text': '朋友圈正文',
      'image_urls': <String>[],
      'created_at': '2026-09-07T00:00:00Z',
      'like_count': 0,
    });
    await tester
        .pumpWidget(host(Brightness.dark, WeChatMomentTile(item: item)));
    final container = tester.widget<Container>(find
        .descendant(
            of: find.byType(WeChatMomentTile), matching: find.byType(Container))
        .first);
    expect(container.color, WeChatColors.darkElevated);
  });
}
