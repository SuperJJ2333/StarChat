import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/permissions/blocked_contacts.dart';

/// BUG-11 回归（真机反馈）：拉黑/取消拉黑必须**立即**维护业务 ID 与
/// Matrix ID 双投影——否则通知抑制、未读抑制、忽略列表同步都要等到
/// 下次 /blocks 水合才生效（表现为"拉黑后对方依旧能发消息"）。
void main() {
  test('markBlocked 携带 matrixUserId：双投影即时生效', () {
    final blocked = BlockedContacts();
    blocked.markBlocked('u-bob', matrixUserId: '@bob:example.test');

    expect(blocked.isBlocked('u-bob'), isTrue);
    expect(blocked.isMatrixIdBlocked('@bob:example.test'), isTrue);
    expect(blocked.matrixUserIds, {'@bob:example.test'});
  });

  test('markUnblocked 携带 matrixUserId：双投影即时解除', () {
    final blocked = BlockedContacts();
    blocked.markBlocked('u-bob', matrixUserId: '@bob:example.test');

    blocked.markUnblocked('u-bob', matrixUserId: '@bob:example.test');

    expect(blocked.isBlocked('u-bob'), isFalse);
    expect(blocked.isMatrixIdBlocked('@bob:example.test'), isFalse,
        reason: '取消拉黑后通话邀请/消息提醒必须能恢复');
    expect(blocked.matrixUserIds, isEmpty);
  });

  test('replaceAll(fromServer) 按 业务ID→MatrixID 映射水合并裁剪', () {
    final blocked = BlockedContacts();
    blocked.replaceAll(['u-bob', 'u-carol'],
        fromServer: true, matrixIdByUser: {
          'u-bob': '@bob:example.test',
          'u-carol': '@carol:example.test',
        });

    expect(blocked.matrixUserIds,
        {'@bob:example.test', '@carol:example.test'});

    // 取消了 carol 的拉黑：映射同步裁剪，不残留。
    blocked.replaceAll(['u-bob'],
        fromServer: true, matrixIdByUser: {'u-bob': '@bob:example.test'});
    expect(blocked.isMatrixIdBlocked('@carol:example.test'), isFalse);
  });

  test('未提供 matrixUserId 的调用方不影响已有映射（兼容旧调用点）', () {
    final blocked = BlockedContacts();
    blocked.markBlocked('u-bob', matrixUserId: '@bob:example.test');

    blocked.replaceAll(['u-bob'], fromServer: true);

    expect(blocked.isMatrixIdBlocked('@bob:example.test'), isTrue,
        reason: '/blocks 未带映射的旧调用不得清掉运行时登记的映射');
  });
}
