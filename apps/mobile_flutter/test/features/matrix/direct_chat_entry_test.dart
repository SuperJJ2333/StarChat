import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_entry.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';

const _self = ProfileData(
    username: 'self', nickname: 'self', maskedEmail: '', fallbackSeed: 'self');

const _bob = ContactDetails(
    userId: 'bob', username: 'bob', matrixUserId: '@bob:test', nickname: 'Bob');

const _alice = ContactDetails(
    userId: 'alice',
    username: 'alice',
    matrixUserId: '@alice:test',
    nickname: 'Alice');

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

  test('同一好友的闸门 single-flight：复用同一个 Future 与目标，解析完成即释放', () async {
    final gate = DirectMessageOpenGate();
    final held = Completer<ContactDetails>();
    var resolutions = 0;

    Future<DirectMessageTarget?> resolve() => gate.run('bob', () async {
          resolutions++;
          final contact = await held.future;
          return DirectMessageTarget(roomId: '!a:test', contact: contact);
        });

    final first = resolve();
    final second = resolve();
    expect(identical(first, second), isTrue,
        reason: '第二次点击必须复用同一个 flight（返回同一个 Future），而不是被静默丢弃');
    expect(gate.isOpen('bob'), isTrue, reason: '身份解析在途时闸门持有');

    held.complete(_bob);
    final first2 = await first;
    final second2 = await second;
    expect(resolutions, 1, reason: '并发两次只解析一次身份');
    expect(identical(first2, second2), isTrue,
        reason: '两个调用拿到同一个 DirectMessageTarget');
    expect(first2!.roomId, '!a:test');
    expect(gate.isOpen('bob'), isFalse, reason: 'canonical roomId 解析完成即释放');
  });

  test('房间页面仍打开时闸门已释放：同一好友可再次进入解析', () async {
    final gate = DirectMessageOpenGate();
    var resolutions = 0;

    Future<DirectMessageTarget?> resolve() => gate.run('bob', () async {
          resolutions++;
          return DirectMessageTarget(roomId: '!a:test', contact: _bob);
        });

    await resolve();
    expect(gate.isOpen('bob'), isFalse,
        reason: '闸门锁定范围只到 canonical roomId，绝不等 RoomPage 关闭');

    // 模拟「Room A 已打开 → 再次进入好友资料 → 再点发消息」。
    final second = await resolve();
    expect(resolutions, 2, reason: '第二次请求必须真的重新进入解析');
    expect(second!.roomId, '!a:test');
  });

  test('解析失败同样释放闸门，弹窗「重试」可以重新进入', () async {
    final gate = DirectMessageOpenGate();
    var attempts = 0;

    Future<DirectMessageTarget?> resolve() => gate.run('bob', () async {
          attempts++;
          if (attempts == 1) throw StateError('direct chat open failed');
          return DirectMessageTarget(roomId: '!a:test', contact: _bob);
        });

    await expectLater(resolve(), throwsStateError);
    expect(gate.isOpen('bob'), isFalse, reason: '失败必须先释放闸门');

    final target = await resolve();
    expect(target!.roomId, '!a:test', reason: '重试可重新进入');
    expect(attempts, 2);
  });

  test('不同好友各自独立，空键不参与去重', () async {
    final gate = DirectMessageOpenGate();
    final heldBob = Completer<DirectMessageTarget>();
    final bob = gate.run('bob', () => heldBob.future);
    expect(gate.isOpen('bob'), isTrue);

    final alice = await gate.run(
        'alice', () async => DirectMessageTarget(roomId: '!b:test', contact: _alice));
    expect(alice!.roomId, '!b:test', reason: '不同好友不受同一好友的 flight 影响');
    expect(gate.isOpen('alice'), isFalse);

    var emptyKeyRuns = 0;
    final emptyKey = await gate.run('', () async {
      emptyKeyRuns++;
      return DirectMessageTarget(roomId: '!c:test', contact: _bob);
    });
    expect(emptyKeyRuns, 1, reason: '身份未知不参与去重，由解析给出失败提示');
    expect(emptyKey!.roomId, '!c:test');

    heldBob.complete(DirectMessageTarget(roomId: '!a:test', contact: _bob));
    expect((await bob)!.roomId, '!a:test');
    expect(gate.isOpen('bob'), isFalse);
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
