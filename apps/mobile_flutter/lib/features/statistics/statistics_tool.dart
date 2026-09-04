import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;

import '../matrix/call_ui_manager.dart' show callNavigatorKey;
import '../../ui/chat/chat_tools.dart';
import 'statistics_assistant_page.dart';
import 'statistics_room_scope.dart';

/// 根导航键已统一为 callNavigatorKey（规格 §二：全局唯一根 Navigator，
/// 来电页/统计助手共用）；旧名保留兼容引用。
final GlobalKey<NavigatorState> statisticsNavigatorKey = callNavigatorKey;

/// 幂等注册「统计助手」聊天工具（同 id 覆盖，不侵入 registry 其他逻辑）。
void ensureStatisticsToolRegistered() => ChatToolRegistry.register(
      const ChatTool(
        id: 'statistics_assistant',
        name: '统计助手',
        icon: Icons.bar_chart,
        onTap: _openStatisticsAssistant,
      ),
    );

/// 无上下文导航：从会话作用域栈取当前会话，打开统计助手全屏页。
void _openStatisticsAssistant() {
  final roomId = StatisticsRoomScope.current;
  if (roomId == null) return; // 工具面板只在会话页内出现，理论不会走到
  statisticsNavigatorKey.currentState?.push(
    CupertinoPageRoute<void>(
      builder: (_) => StatisticsAssistantPage(roomId: roomId),
    ),
  );
}
