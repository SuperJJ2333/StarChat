import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

/// 聊天工具项：“更多”面板 → 工具 面板的可扩展条目。
///
/// 后续新增聊天工具（文件传输、位置共享、投票、日程等）只需调用
/// [ChatToolRegistry.register] 注册一个 [ChatTool]（唯一标识 + 名称 +
/// 图标 + 点击处理函数），工具面板会自动展示并路由点击，无需改面板代码。
final class ChatTool {
  const ChatTool({
    required this.id,
    required this.name,
    required this.icon,
    required this.onTap,
  });

  /// 唯一标识（注册去重/注销的依据），如 `location-share`。
  final String id;

  /// 展示名称。
  final String name;

  /// 图标。
  final IconData icon;

  /// 点击处理函数。
  final VoidCallback onTap;
}

/// 工具注册表：进程内单例，支持动态注册/注销/清空（便于测试与灰度开关）。
final class ChatToolRegistry {
  ChatToolRegistry._();

  static final List<ChatTool> _tools = <ChatTool>[];

  static List<ChatTool> get tools => List.unmodifiable(_tools);

  /// 注册工具；同 id 重复注册按覆盖处理（便于功能开关刷新配置）。
  static void register(ChatTool tool) {
    unregister(tool.id);
    _tools.add(tool);
  }

  static void unregister(String id) {
    _tools.removeWhere((tool) => tool.id == id);
  }

  static void clear() => _tools.clear();
}

/// 工具面板：展示注册表中的聊天工具；空态给出引导文案。
/// 面板本身不含业务，扩展新工具零改动（注册即生效）。
final class ChatToolsPanel extends StatelessWidget {
  const ChatToolsPanel({super.key, this.onToolSelected});

  /// 点击某个工具后回调（默认先关闭面板再执行工具 onTap，由外层决定）。
  final ValueChanged<ChatTool>? onToolSelected;

  @override
  Widget build(BuildContext context) {
    final tools = ChatToolRegistry.tools;
    return SizedBox(
      key: const Key('chat-tools-panel'),
      height: 232,
      child: tools.isEmpty
          ? const Center(
              child: Text(
                '更多工具即将上线',
                style: TextStyle(fontSize: 13, color: WeChatColors.textSecondary),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.symmetric(
                horizontal: WeChatSpacing.lg,
                vertical: WeChatSpacing.md,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: WeChatSpacing.md,
                crossAxisSpacing: WeChatSpacing.md,
                mainAxisExtent: 82,
              ),
              itemCount: tools.length,
              itemBuilder: (context, index) {
                final tool = tools[index];
                return Semantics(
                  button: true,
                  label: tool.name,
                  child: CupertinoButton(
                    key: Key('chat-tool-${tool.id}'),
                    minimumSize: const Size.square(
                      WeChatDimensions.minimumTouchTarget,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: () => onToolSelected?.call(tool),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: CupertinoTheme.of(context)
                                .scaffoldBackgroundColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(tool.icon, size: 25),
                        ),
                        const SizedBox(height: 6),
                        Text(tool.name,
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
