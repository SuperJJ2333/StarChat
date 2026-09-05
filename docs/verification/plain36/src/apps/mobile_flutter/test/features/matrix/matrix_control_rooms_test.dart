import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_control_rooms.dart';

void main() {
  test('private control rooms never appear as user conversations', () {
    expect(isMatrixControlRoomName('畅聊表情仓库'), isTrue);
    expect(isMatrixControlRoomName('畅聊提醒同步'), isTrue);
    expect(isMatrixControlRoomName('好友群聊'), isFalse);
    expect(
      isMatrixControlRoom(
        roomId: '!vault:test',
        displayName: '任意名称',
        vaultRoomId: '!vault:test',
        reminderRoomId: '!reminder:test',
      ),
      isTrue,
    );
    expect(
      isMatrixControlRoom(
        roomId: '!chat:test',
        displayName: '好友群聊',
        vaultRoomId: '!vault:test',
        reminderRoomId: '!reminder:test',
      ),
      isFalse,
    );
  });
}
