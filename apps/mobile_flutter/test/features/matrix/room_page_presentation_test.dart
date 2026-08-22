import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';

void main() {
  test('group room title uses the custom name and joined member count', () {
    expect(groupRoomNavigationTitle('测试账号1', 3), '测试账号1(3)');
    expect(groupRoomNavigationTitle('', 3), '群聊(3)');
  });

  test('long group room title keeps the first eight and last three characters',
      () {
    expect(
      groupRoomNavigationTitle('123456789012345678901', 12),
      '12345678...901(12)',
    );
  });

  test('group room title reserves navigation space for its member count', () {
    expect(
      groupRoomNavigationTitle('12345678901234567890', 123),
      '12345678...890(123)',
    );
  });
}
