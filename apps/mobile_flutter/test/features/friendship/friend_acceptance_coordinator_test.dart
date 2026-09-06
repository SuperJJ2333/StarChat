import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/friendship/friend_acceptance_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';

/// BUG 3：accept 编排——乐观插入 + 私聊建立系统消息回调。
void main() {
  test('onAccepted 乐观插入好友并建立私聊（携带正确参数）', () async {
    final store = MemoryProfileStore();
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@me:test',
      store: store,
    );
    final established = <String>[];
    final coordinator = FriendAcceptanceCoordinator(
      identityCache: cache,
      establishDirectChat:
          (matrixUserId, friendUserId, friendDisplayName) async {
        established.addAll([matrixUserId, friendUserId, friendDisplayName]);
      },
    );

    await coordinator.onAccepted({
      'user_id': 'bob-id',
      'username': 'bob',
      'nickname': 'Bob',
      'avatar_url': 'https://cdn.test/bob.jpg',
      'matrix_user_id': '@bob:test',
      'remark': '同事',
      'tags': ['工作'],
    });

    // 好友立即出现在本地仓库（无需网络整表刷新）。
    expect(cache.contacts, hasLength(1));
    final contact = cache.contacts.single;
    expect(contact.userId, 'bob-id');
    expect(contact.nickname, 'Bob');
    expect(contact.remark, isNull);
    expect(contact.tags, isEmpty);
    expect(cache.contactsRevision, 1, reason: 'revision 必须递增');

    // 私聊建立回调收到规范参数。
    expect(established, ['@bob:test', 'bob-id', 'Bob']);
  });

  test('接受旧API申请不覆盖当前账号自己的联系人偏好', () async {
    final cache = ProfileRepository.forTesting(
        accountKey: 'matrix:@me:test', store: MemoryProfileStore());
    await cache.applyUpdatedContact(const ContactSummary(
        userId: 'bob-id',
        username: 'bob',
        matrixUserId: '@bob:test',
        remark: '我的备注',
        tags: ['我的标签'],
        momentsPermission: 'HIDE_BOTH',
        starred: true));
    await FriendAcceptanceCoordinator(
            identityCache: cache, establishDirectChat: null)
        .onAccepted({
      'user_id': 'bob-id',
      'username': 'bob',
      'matrix_user_id': '@bob:test',
      'remark': '对方私密备注',
      'tags': ['对方私密标签'],
    });
    final contact = cache.contacts.single;
    expect(contact.remark, '我的备注');
    expect(contact.tags, ['我的标签']);
    expect(contact.momentsPermission, 'HIDE_BOTH');
    expect(contact.starred, isTrue);
  });

  test('私聊建立失败不影响已插入的好友（不回滚）', () async {
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@me:test',
      store: MemoryProfileStore(),
    );
    final coordinator = FriendAcceptanceCoordinator(
      identityCache: cache,
      establishDirectChat: (matrixUserId, friendUserId, displayName) async {
        throw StateError('room creation failed');
      },
    );

    await coordinator.onAccepted({
      'user_id': 'bob-id',
      'username': 'bob',
      'nickname': 'Bob',
      'matrix_user_id': '@bob:test',
    });

    expect(cache.contacts, hasLength(1), reason: '建房失败不回滚好友显示');
  });

  test('系统招呼文案规范（不伪装为对方名义消息）', () {
    expect(
      friendAcceptedGreeting('张三'),
      '你已添加了 张三，现在可以开始聊天了。',
    );
  });
}

final class MemoryProfileStore implements ProfileStore {
  final values = <String, ProfileSnapshot>{};

  @override
  Future<ProfileSnapshot?> read(String accountKey) async => values[accountKey];

  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    values[accountKey] = snapshot;
  }
}
