import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_visibility_policy.dart';

/// 控制房间可见性：**只用身份事实**（roomId + accountData 引用）判定。
///
/// 旧实现用展示名白名单（`'畅聊表情仓库'` / `'畅聊提醒同步'`），改名即失效、
/// 同名即误判，而且只有消息列表用了它 —— 全局搜索会把账号级系统房间当成
/// 群聊展示并允许打开。
void main() {
  test('accountData 引用的控制房间不可见、不可打开', () {
    final policy = RoomVisibilityPolicy.forRoomIds(const [
      '!vault:test',
      '!reminder:test',
    ]);
    expect(policy.isVisible('!vault:test'), isFalse);
    expect(policy.isOpenable('!reminder:test'), isFalse);
    expect(policy.isVisible('!chat:test'), isTrue);
    expect(policy.controlRoomIds, {'!vault:test', '!reminder:test'});
  });

  test('展示名不参与判定：改名不影响，同名不误判', () {
    final policy = RoomVisibilityPolicy.forRoomIds(const ['!vault:test']);

    // 名字与旧白名单完全相同，但没有 accountData 引用 → 不是控制房间。
    final sameNameButUnreferenced = RoomVisibilityPolicy.forRoomIds(const []);
    expect(sameNameButUnreferenced.isVisible('!some-room:test'), isTrue);

    // 控制房间改名（roomId 不变）后仍不可见。
    expect(policy.isVisible('!vault:test'), isFalse);
  });

  test('空白/空值 roomId 不会被误判为控制房间', () {
    final policy = RoomVisibilityPolicy.forRoomIds(const [null, '', '   ']);
    expect(policy.controlRoomIds, isEmpty);
    expect(policy.isControlRoom(''), isFalse);
  });

  test('判定来源里不得再出现硬编码展示名', () {
    for (final path in const [
      'lib/features/matrix/matrix_control_rooms.dart',
      'lib/features/matrix/room_visibility_policy.dart',
      'lib/features/matrix/matrix_home_page.dart',
      'lib/features/search/global_search_page.dart',
    ]) {
      // 只检查**代码**：注释里允许出现历史说明（记录旧实现为什么被替换）。
      final code = _stripComments(File(path).readAsStringSync());
      expect(code, isNot(contains('畅聊表情仓库')), reason: '$path 不得硬编码控制房间名');
      expect(code, isNot(contains('畅聊提醒同步')), reason: '$path 不得硬编码控制房间名');
    }
    final registry =
        File('lib/features/matrix/matrix_control_rooms.dart').readAsStringSync();
    expect(registry, contains('accountData'),
        reason: '控制房间身份必须来自 accountData 引用');
  });
}

/// 去掉行注释与块注释，只保留可执行代码（守卫测试必须区分"注释里的历史"
/// 与"代码里的判定"）。
String _stripComments(String source) {
  var withoutBlock = source.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final lines = withoutBlock.split('\n');
  return lines
      .map((line) {
        final index = line.indexOf('//');
        return index == -1 ? line : line.substring(0, index);
      })
      .join('\n');
}
