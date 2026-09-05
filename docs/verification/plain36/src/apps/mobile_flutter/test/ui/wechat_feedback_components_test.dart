import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_composer.dart';
import 'package:liuhetong_mobile/ui/components/wechat_contact_index.dart';
import 'package:liuhetong_mobile/ui/components/wechat_contact_tile.dart';
import 'package:liuhetong_mobile/ui/components/wechat_dialog.dart';
import 'package:liuhetong_mobile/ui/components/wechat_empty_state.dart';
import 'package:liuhetong_mobile/ui/components/wechat_toast.dart';

void main() {
  testWidgets('feedback primitives expose their documented content and actions',
      (tester) async {
    var actionCount = 0;
    await tester.pumpWidget(CupertinoApp(
      home: Column(children: [
        WeChatDialog(
          title: '确认删除',
          content: const Text('此操作不可撤销'),
          actions: [
            WeChatDialogAction(label: '确认', onPressed: () => actionCount++)
          ],
        ),
        const WeChatToast(message: '保存成功'),
        WeChatEmptyState(
            title: '暂无消息', actionLabel: '重试', onAction: () => actionCount++),
      ]),
    ));
    expect(find.text('确认删除'), findsOneWidget);
    expect(find.text('保存成功'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(actionCount, 1);
  });

  testWidgets(
      'composer, contact tile and index implement public interaction contracts',
      (tester) async {
    final controller = TextEditingController(text: '你好');
    var sent = 0;
    var selected = '';
    await tester.pumpWidget(CupertinoApp(
      home: Column(children: [
        WeChatComposer(
          controller: controller,
          onMore: () {},
          onVoice: () {},
          onEmoji: () {},
          onSend: () => sent++,
        ),
        const WeChatContactTile(nickname: 'Alice', fallbackSeed: 'alice'),
        WeChatContactIndex(
            labels: const ['A', 'B'], onSelected: (value) => selected = value),
      ]),
    ));
    expect(tester.getSize(find.byType(WeChatContactTile)).height, 56);
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.tap(find.text('B'));
    await tester.pump();
    expect(sent, 1);
    expect(selected, 'B');
    expect(find.text('B', skipOffstage: false), findsAtLeastNWidgets(2));
    await tester.pump(const Duration(milliseconds: 500));
  });
}
