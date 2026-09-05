import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/statistics/statistics_room_scope.dart';
import 'package:liuhetong_mobile/features/statistics/statistics_state_store.dart';
import 'package:liuhetong_mobile/features/statistics/statistics_tool.dart';
import 'package:liuhetong_mobile/ui/chat/chat_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => ChatToolRegistry.clear());

  group('统计助手注册', () {
    test('ensureStatisticsToolRegistered 幂等注册「统计助手」', () {
      ensureStatisticsToolRegistered();
      ensureStatisticsToolRegistered();

      expect(ChatToolRegistry.tools, hasLength(1));
      final tool = ChatToolRegistry.tools.single;
      expect(tool.id, 'statistics_assistant');
      expect(tool.name, '统计助手');
    });
  });

  group('StatisticsRoomScope 会话作用域栈', () {
    tearDown(() {
      // 清理测试遗留的栈
      for (final id in <String>['!a:test', '!b:test', '!c:test']) {
        StatisticsRoomScope.leave(id);
      }
    });

    test('enter/leave 维护当前会话，栈顶为最新', () {
      expect(StatisticsRoomScope.current, isNull);

      StatisticsRoomScope.enter('!a:test');
      StatisticsRoomScope.enter('!b:test');
      expect(StatisticsRoomScope.current, '!b:test');

      StatisticsRoomScope.leave('!b:test');
      expect(StatisticsRoomScope.current, '!a:test');

      StatisticsRoomScope.leave('!a:test');
      expect(StatisticsRoomScope.current, isNull);
    });

    test('重复进入同一会话只保留栈顶一份', () {
      StatisticsRoomScope.enter('!a:test');
      StatisticsRoomScope.enter('!b:test');
      StatisticsRoomScope.enter('!a:test'); // a 再次进入 → 移到栈顶
      expect(StatisticsRoomScope.current, '!a:test');

      StatisticsRoomScope.leave('!a:test');
      expect(StatisticsRoomScope.current, '!b:test');
    });
  });

  group('StatisticsStateStore 会话缓存隔离', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('不同会话互不干扰，删除会话后清理', () async {
      await StatisticsStateStore.write('!a:test', '{"v":2}');
      await StatisticsStateStore.write('!b:test', '{"v":2,"other":1}');

      expect(await StatisticsStateStore.read('!a:test'), '{"v":2}');
      expect(await StatisticsStateStore.read('!b:test'), '{"v":2,"other":1}');

      // 删除会话 A → A 的缓存被清理，B 不受影响
      await StatisticsStateStore.clear('!a:test');
      expect(await StatisticsStateStore.read('!a:test'), isNull);
      expect(await StatisticsStateStore.read('!b:test'), '{"v":2,"other":1}');
    });
  });

  testWidgets('工具面板渲染「统计助手」并可点击路由', (tester) async {
    ensureStatisticsToolRegistered();
    await tester.pumpWidget(CupertinoApp(
      home: SizedBox(
        width: 393,
        child: ChatToolsPanel(
          onToolSelected: (tool) => tool.onTap(),
        ),
      ),
    ));

    expect(find.byKey(const Key('chat-tool-statistics_assistant')), findsOneWidget);
    expect(find.text('统计助手'), findsOneWidget);

    // onTap 在无会话作用域时安全返回（不抛错）
    await tester.tap(find.byKey(const Key('chat-tool-statistics_assistant')));
    await tester.pump();
  });
}
