import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';

void main() {
  test('group room title is generic regardless of the custom name', () {
    expect(groupRoomNavigationTitle('测试账号1', 3), '群聊(3)');
    expect(groupRoomNavigationTitle('', 3), '群聊(3)');
  });

  test('long custom names never leak into the chat navigation title', () {
    expect(
      groupRoomNavigationTitle('123456789012345678901', 12),
      '群聊(12)',
    );
  });
}
