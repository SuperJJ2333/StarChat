import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/chat_composer_bar.dart';
import 'package:liuhetong_mobile/ui/components/call_control_button.dart';
import 'package:liuhetong_mobile/ui/components/conversation_list_tile.dart';
import 'package:liuhetong_mobile/ui/foundation/changliao_icons.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';

void main() {
  testWidgets('conversation tile keeps the Figma leading body trailing slots',
      (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: ConversationListTile(
            title: '周然',
            subtitle: '晚上见',
            timeLabel: '09:41',
            avatar: const ColoredBox(color: CupertinoColors.activeGreen),
            unreadCount: 120,
            muted: false,
            onTap: () {},
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(ConversationListTile)).height,
      greaterThanOrEqualTo(72),
    );
    expect(
      tester.getSize(find.byKey(const Key('conversation-avatar-slot'))),
      const Size.square(48),
    );
    expect(find.text('周然'), findsOneWidget);
    expect(find.text('晚上见'), findsOneWidget);
    expect(find.text('09:41'), findsOneWidget);
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets(
      'conversation tile shows semantic mute state without unread count',
      (tester) async {
    await tester.pumpWidget(
      const CupertinoApp(
        home: ConversationListTile(
          title: '项目群',
          subtitle: '端到端加密消息',
          timeLabel: '昨天',
          avatar: SizedBox(),
          muted: true,
        ),
      ),
    );

    expect(find.byIcon(ChangliaoIcons.muted), findsOneWidget);
    expect(find.bySemanticsLabel('已静音'), findsOneWidget);
  });

  testWidgets('conversation rows keep unique sibling keys', (tester) async {
    await tester.pumpWidget(
      const CupertinoApp(
        home: Column(
          children: [
            ConversationListTile(
              title: '周然',
              subtitle: '第一条消息',
              timeLabel: '09:41',
              avatar: SizedBox(),
            ),
            ConversationListTile(
              title: '项目群',
              subtitle: '第二条消息',
              timeLabel: '09:42',
              avatar: SizedBox(),
            ),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('chat composer exposes attachment voice emoji input and send',
      (tester) async {
    var attachments = 0;
    var voices = 0;
    var emojis = 0;
    var sends = 0;
    final controller = TextEditingController(text: '你好');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposerBar(
              controller: controller,
              onAttachment: () => attachments++,
              onVoice: () => voices++,
              onEmoji: () => emojis++,
              onSend: () => sends++,
            ),
          ),
        ),
      ),
    );

    for (final key in const [
      'chat-composer-attachment',
      'chat-composer-voice',
      'chat-composer-emoji',
      'chat-composer-input',
      'chat-composer-send',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    expect(
      tester.getSize(find.byType(ChatComposerBar)).height,
      greaterThanOrEqualTo(56),
    );
    await tester.tap(find.byKey(const Key('chat-composer-attachment')));
    await tester.tap(find.byKey(const Key('chat-composer-voice')));
    await tester.tap(find.byKey(const Key('chat-composer-emoji')));
    await tester.tap(find.byKey(const Key('chat-composer-send')));
    expect(attachments, 1);
    expect(voices, 1);
    expect(emojis, 1);
    expect(sends, 1);
  });

  testWidgets('call control uses a 72px target and an accessible real icon',
      (tester) async {
    var presses = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: CallControlButton(
            icon: ChangliaoIcons.microphone,
            label: '麦克风',
            onPressed: () => presses++,
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(CallControlButton)),
      const Size.square(72),
    );
    expect(find.byIcon(ChangliaoIcons.microphone), findsOneWidget);
    expect(find.bySemanticsLabel('麦克风'), findsOneWidget);
    await tester.tap(find.byType(CallControlButton));
    expect(presses, 1);
  });

  testWidgets('encrypted image starts loading only after state is mounted',
      (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: EncryptedImageMessage(
          load: () async {
            loads++;
            return Uint8List.fromList(const <int>[
              137,
              80,
              78,
              71,
              13,
              10,
              26,
              10,
              0,
              0,
              0,
              13,
              73,
              72,
              68,
              82,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              1,
              8,
              6,
              0,
              0,
              0,
              31,
              21,
              196,
              137,
              0,
              0,
              0,
              13,
              73,
              68,
              65,
              84,
              8,
              215,
              99,
              248,
              207,
              192,
              240,
              31,
              0,
              5,
              0,
              1,
              255,
              137,
              153,
              109,
              22,
              0,
              0,
              0,
              0,
              73,
              69,
              78,
              68,
              174,
              66,
              96,
              130,
            ]);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
