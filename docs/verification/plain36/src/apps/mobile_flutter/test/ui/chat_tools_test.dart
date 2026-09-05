import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/chat_tools.dart';

void main() {
  setUp(() => ChatToolRegistry.clear());
  tearDown(() => ChatToolRegistry.clear());

  test('registry supports register / overwrite-by-id / unregister', () {
    var taps = 0;
    ChatToolRegistry.register(ChatTool(
      id: 'location-share',
      name: '位置共享',
      icon: CupertinoIcons.location,
      onTap: () {},
    ));
    ChatToolRegistry.register(ChatTool(
      id: 'poll',
      name: '投票',
      icon: CupertinoIcons.chart_bar,
      onTap: () {},
    ));
    expect(ChatToolRegistry.tools.map((t) => t.id).toList(),
        ['location-share', 'poll']);

    // 同 id 重复注册按覆盖处理（功能开关/配置刷新场景）。
    ChatToolRegistry.register(ChatTool(
      id: 'poll',
      name: '群投票',
      icon: CupertinoIcons.chart_bar_fill,
      onTap: () => taps++,
    ));
    expect(ChatToolRegistry.tools, hasLength(2));
    expect(ChatToolRegistry.tools.last.name, '群投票');

    ChatToolRegistry.unregister('location-share');
    expect(ChatToolRegistry.tools.map((t) => t.id), ['poll']);

    ChatToolRegistry.tools.last.onTap();
    expect(taps, 1);
  });

  testWidgets('tools panel lists registered tools and routes taps',
      (tester) async {
    var invoked = 0;
    ChatToolRegistry.register(ChatTool(
      id: 'file-transfer',
      name: '文件传输',
      icon: CupertinoIcons.doc,
      onTap: () => invoked++,
    ));
    await tester.pumpWidget(CupertinoApp(
      home: SizedBox(
        width: 393,
        child: ChatToolsPanel(
          onToolSelected: (tool) => tool.onTap(),
        ),
      ),
    ));

    expect(find.byKey(const Key('chat-tools-panel')), findsOneWidget);
    expect(find.text('文件传输'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-tool-file-transfer')));
    expect(invoked, 1, reason: '点击工具条目路由到注册的点击处理函数');
  });

  testWidgets('empty registry shows the guidance empty state',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: SizedBox(width: 393, child: const ChatToolsPanel()),
    ));

    expect(find.text('更多工具即将上线'), findsOneWidget);
  });
}
