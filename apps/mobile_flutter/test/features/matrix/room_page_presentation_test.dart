import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_presentation.dart';

void main() {
  test('group room title shows the custom name with member count', () {
    // 群主/管理员改过群名 → “群聊名称（人数）”。
    expect(groupRoomNavigationTitle('测试账号1', 3), '测试账号1（3）');
    // 未自定义群名 → 默认“群聊（人数）”。
    expect(groupRoomNavigationTitle('', 3), '群聊（3）');
    expect(groupRoomNavigationTitle(null, 5), '群聊（5）');
  });

  test('long custom names keep the full title and ellipsize at the widget', () {
    // 标题函数返回完整文本；一行内省略由 WeChatNavTitle 的
    // maxLines+ellipsis 处理。
    expect(
      groupRoomNavigationTitle('123456789012345678901', 12),
      '123456789012345678901（12）',
    );
  });

  test('direct room navigation title resolves the latest contact identity', () {
    const contact = ContactDetails(
      userId: 'alice-id',
      username: 'alice-login',
      matrixUserId: '@alice:test',
      nickname: 'Alice',
      remark: '项目小艾',
    );
    expect(
      directRoomNavigationTitle(
        peerMatrixUserId: '@alice:test',
        contactsByMatrixId: const {'@alice:test': contact},
        fallbackRoomName: 'Group with Alice',
      ),
      '项目小艾',
    );
    expect(
      directRoomNavigationTitle(
        peerMatrixUserId: '@missing:test',
        contactsByMatrixId: const {},
        fallbackRoomName: '安全回退',
      ),
      '安全回退',
    );
  });
}
