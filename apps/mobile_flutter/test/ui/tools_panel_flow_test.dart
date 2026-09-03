import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/statistics/statistics_tool.dart';
import 'package:liuhetong_mobile/ui/chat/chat_composer_state.dart';
import 'package:liuhetong_mobile/ui/chat/chat_more_panel.dart';
import 'package:liuhetong_mobile/ui/chat/chat_tools.dart';

/// 复刻 room_page 中「更多面板 → 工具面板」的真实接线
/// （onTools: () => _togglePanel(ComposerPanel.tools)），用真实组件
/// ChatMorePanel / ChatToolsPanel / ChatToolRegistry 端到端验证：
/// 「+」更多 → 「工具」→ 工具面板 → 点「统计助手」触发 onTap。
class _ComposerHost extends StatefulWidget {
  const _ComposerHost({required this.onToolInvoked});
  final ValueChanged<String> onToolInvoked;
  @override
  State<_ComposerHost> createState() => _ComposerHostState();
}

class _ComposerHostState extends State<_ComposerHost> {
  ComposerPanel composerPanel = ComposerPanel.none;

  void _togglePanel(ComposerPanel panel) {
    setState(() {
      composerPanel = composerPanel == panel ? ComposerPanel.none : panel;
    });
  }

  void _dismissExtensions() => setState(() => composerPanel = ComposerPanel.none);

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      home: Column(
        children: [
          // 模拟输入区左上角的「+」：打开更多面板
          CupertinoButton(
            key: const Key('composer-plus'),
            onPressed: () => _togglePanel(ComposerPanel.more),
            child: const Text('+'),
          ),
          if (composerPanel == ComposerPanel.more)
            ChatMorePanel(
              onSelected: (_) {},
              onTools: () => _togglePanel(ComposerPanel.tools),
            ),
          if (composerPanel == ComposerPanel.tools)
            ChatToolsPanel(
              onToolSelected: (tool) {
                _dismissExtensions();
                widget.onToolInvoked(tool.id);
                tool.onTap();
              },
            ),
        ],
      ),
    );
  }
}

void main() {
  setUp(() => ChatToolRegistry.clear());

  testWidgets('更多面板 → 工具 → 工具面板 → 统计助手 全链路可用', (tester) async {
    ensureStatisticsToolRegistered(); // 模拟 RoomPage.initState 的注册
    final invoked = <String>[];
    await tester.pumpWidget(_ComposerHost(onToolInvoked: invoked.add));

    // 1) 点击「+」打开更多面板
    await tester.tap(find.byKey(const Key('composer-plus')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-more-panel')), findsOneWidget);
    // 末位「工具」入口存在且可点（onTools 已接线 → onPressed 非空）
    final toolsBtn = tester.widget<CupertinoButton>(
      find.byKey(const Key('chat-more-tools')),
    );
    expect(toolsBtn.onPressed, isNotNull, reason: '「工具」入口不应被禁用');

    // 2) 点击「工具」→ 切到工具面板，展示已注册的「统计助手」
    await tester.tap(find.byKey(const Key('chat-more-tools')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-tools-panel')), findsOneWidget);
    expect(find.text('统计助手'), findsOneWidget);

    // 3) 点击「统计助手」→ 路由到 onTap
    await tester.tap(find.byKey(const Key('chat-tool-statistics_assistant')));
    await tester.pumpAndSettle();
    expect(invoked, ['statistics_assistant'],
        reason: '点击工具应触发其 onTap');
  });
}
