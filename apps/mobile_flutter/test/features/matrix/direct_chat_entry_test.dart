import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_entry.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';

const _self = ProfileData(
    username: 'self', nickname: 'self', maskedEmail: '', fallbackSeed: 'self');

ContactSummary _friend({
  String userId = 'bob',
  String username = 'bob',
  String matrixUserId = '@bob:test',
  String? nickname = 'Bob',
  String? remark,
}) =>
    ContactSummary(
      userId: userId,
      username: username,
      matrixUserId: matrixUserId,
      nickname: nickname,
      remark: remark,
    );

final class _Store implements ProfileStore {
  final values = <String, ProfileSnapshot>{};
  @override
  Future<ProfileSnapshot?> read(String accountKey) async => values[accountKey];
  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    values[accountKey] = snapshot;
  }
}

/// 构造一个已 hydrate 的仓库：[stored] 是持久化快照，[responses] 按顺序作为
/// 每次好友目录请求的返回（`preload` 记一次，静默刷新记第二次）。
Future<ProfileRepository> _repository(
  List<ContactSummary> stored, {
  required List<List<ContactSummary>> responses,
  void Function(int loads)? onLoad,
}) async {
  final store = _Store();
  await store.write('self',
      ProfileSnapshot(profile: _self, contacts: List.of(stored)));
  var loads = 0;
  final repository = ProfileRepository.forTesting(
    accountKey: 'self',
    store: store,
    loadProfile: () async => _self,
    loadContacts: () {
      final index = loads < responses.length ? loads : responses.length - 1;
      loads++;
      onLoad?.call(loads);
      return Future.value(responses[index]);
    },
  );
  await repository.preload();
  return repository;
}

void main() {
  test('目录中没有该好友时先静默刷新一次，再返回权威联系人', () async {
    var loads = 0;
    final repository = await _repository(
      const [],
      responses: [
        const [],
        [_friend(remark: '老王的备注')],
      ],
      onLoad: (value) => loads = value,
    );
    addTearDown(repository.dispose);
    expect(loads, 1, reason: 'preload 只读一次目录，且此时还没有该好友');

    final resolved = await resolveFriendContact(
        repository,
        const ContactDetails(
            userId: 'bob', username: 'bob', matrixUserId: '@bob:test'));

    expect(loads, 2, reason: '好友目录缺失时刷新一次');
    expect(resolved.userId, 'bob');
    expect(resolved.matrixUserId, '@bob:test');
    expect(resolved.remark, '老王的备注');
  });

  test('好友已缓存时不额外请求，直接返回权威联系人', () async {
    var loads = 0;
    final repository = await _repository(
      [_friend(remark: '备注')],
      responses: [
        [_friend(remark: '备注')],
      ],
      onLoad: (value) => loads = value,
    );
    addTearDown(repository.dispose);

    final resolved = await resolveFriendContact(
        repository,
        const ContactDetails(
            userId: 'bob', username: 'bob', matrixUserId: '@bob:test'));

    expect(loads, 1, reason: '命中缓存不得再发好友请求');
    expect(resolved.remark, '备注');
  });

  test('入口 Matrix ID 已过期时以业务 userId 取到的当前映射为准', () async {
    var loads = 0;
    final repository = await _repository(
      [_friend(matrixUserId: '@bob:new')],
      responses: [
        [_friend(matrixUserId: '@bob:new')],
      ],
      onLoad: (value) => loads = value,
    );
    addTearDown(repository.dispose);

    // 旧快照：Matrix 绑定更新前的数据（用户改绑/迁移设备）。
    final resolved = await resolveFriendContact(
        repository,
        const ContactDetails(
            userId: 'bob',
            username: 'bob',
            matrixUserId: '@bob:old',
            nickname: '旧快照'));

    expect(resolved.matrixUserId, '@bob:new');
    expect(loads, 1, reason: '业务 userId 已命中，无需刷新，也不得按旧 Matrix ID 判死');
  });

  test('业务 userId 形态不同但 Matrix ID 仍是当前好友时用目录条目', () async {
    final repository = await _repository(
      [_friend()],
      responses: [
        [_friend()],
      ],
    );
    addTearDown(repository.dispose);

    final resolved = await resolveFriendContact(
        repository,
        const ContactDetails(
            userId: 'other-business-id',
            username: 'other',
            matrixUserId: '@bob:test'));

    expect(resolved.userId, 'bob', reason: '目录里的身份为准');
    expect(resolved.matrixUserId, '@bob:test');
  });

  test('目录好友缺少 Matrix 绑定时用入口快照补齐并保留本机备注', () async {
    final repository = await _repository(
      [_friend(matrixUserId: '', remark: '我的备注', nickname: 'Bob')],
      responses: [
        [_friend(matrixUserId: '', remark: '我的备注', nickname: 'Bob')],
      ],
    );
    addTearDown(repository.dispose);

    final resolved = await resolveFriendContact(
        repository,
        const ContactDetails(
            userId: 'bob', username: 'bob', matrixUserId: '@bob:test'));

    expect(resolved.matrixUserId, '@bob:test');
    expect(resolved.remark, '我的备注', reason: '备注是查看者私有数据，不能被入口快照覆盖');
    expect(repository.contactsByMatrixId.containsKey('@bob:test'), isTrue,
        reason: '补齐后的映射进入双索引，后续打开无需再回填');
  });

  test('已不是好友（userId 与 Matrix ID 都不在目录）抛出可分类的身份错误', () async {
    final repository = await _repository(
      const [],
      responses: [const []],
    );
    addTearDown(repository.dispose);

    await expectLater(
      resolveFriendContact(
          repository,
          const ContactDetails(
              userId: 'bob', username: 'bob', matrixUserId: '@bob:test')),
      throwsA(isA<StateError>().having((error) => error.message, 'message',
          'The contact is no longer a current friend')),
    );
  });

  test('仅有 Matrix ID 的入口按矩阵索引校验当前好友', () async {
    var loads = 0;
    final repository = await _repository(
      [_friend()],
      responses: [
        [_friend()],
      ],
      onLoad: (value) => loads = value,
    );
    addTearDown(repository.dispose);

    await ensureCurrentFriendIdentity(repository, '@bob:test');
    expect(loads, 1);
    await expectLater(
      ensureCurrentFriendIdentity(repository, '@mallory:test'),
      throwsA(isA<StateError>()),
    );
    expect(loads, 2, reason: '未知 Matrix ID 会刷新一次目录后仍判失败');
  });

  test('同一好友的打开闸门去重，身份未知与不同好友互不影响', () {
    final gate = DirectMessageOpenGate();
    expect(gate.claim('bob'), isTrue);
    expect(gate.claim('bob'), isFalse, reason: '连续快速点击只放行一次');
    expect(gate.claim('alice'), isTrue, reason: '不同好友各自独立');
    expect(gate.claim(''), isTrue, reason: '身份未知不参与去重，由解析给出失败提示');
    expect(gate.isOpen('bob'), isTrue);

    gate.release('bob');
    expect(gate.isOpen('bob'), isFalse);
    expect(gate.claim('bob'), isTrue, reason: '房间关闭/流程结束后可再次打开');
    gate.release('bob');
    gate.release('alice');
    expect(gate.isOpen('alice'), isFalse);
  });

  test('打开键优先业务 userId，缺失时退回 Matrix ID', () {
    expect(
        directMessageOpenKey(const ContactDetails(
            userId: 'bob', username: 'bob', matrixUserId: '@bob:test')),
        'bob');
    expect(
        directMessageOpenKey(const ContactDetails(
            userId: '', username: 'bob', matrixUserId: '@bob:test')),
        '@bob:test');
  });
}
