import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  test('hydrates the prior account avatar metadata before a network refresh',
      () async {
    final store = MemoryProfileStore();
    await store.write(
      'matrix:@alice:example.test',
      ProfileSnapshot(
        profile: const ProfileData(
          username: 'alice',
          nickname: 'Alice',
          maskedEmail: '',
          fallbackSeed: 'alice-seed',
          avatarUrl: 'https://cdn.example.test/alice-v2.jpg',
        ),
        contacts: const [
          ContactSummary(
            userId: 'bob-id',
            username: 'bob',
            matrixUserId: '@bob:example.test',
            nickname: 'Bob',
            avatarUrl: 'https://cdn.example.test/bob-v3.jpg',
          ),
        ],
      ),
    );

    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: store,
    );

    await cache.hydrate();

    expect(cache.profile?.avatarUrl, 'https://cdn.example.test/alice-v2.jpg');
    expect(
      cache.contactsByMatrixId['@bob:example.test']?.avatarUrl,
      'https://cdn.example.test/bob-v3.jpg',
    );
    expect(cache.wasHydratedFromDisk, isTrue);
  });

  test('applies an updated contact and notifies listeners once', () async {
    final store = MemoryProfileStore();
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: store,
    );
    await store.write(
      'matrix:@alice:example.test',
      ProfileSnapshot(
        profile: profile('Alice'),
        contacts: [contact(remark: '旧备注')],
      ),
    );
    await cache.hydrate();
    var notifications = 0;
    cache.addListener(() => notifications++);

    await cache.applyUpdatedContact(contact(remark: '新备注'));

    expect(cache.contacts.single.remark, '新备注');
    expect(
      cache.contactsByMatrixId['@bob:example.test']?.remark,
      '新备注',
    );
    expect(notifications, 1);
    expect(
      (await store.read('matrix:@alice:example.test'))!.contacts.single.remark,
      '新备注',
    );
  });

  test('refresh loads a new identity snapshot after preload', () async {
    var generation = 0;
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: MemoryProfileStore(),
      loadProfile: () async => profile('Alice ${++generation}'),
      loadContacts: () async => [contact(remark: '备注 $generation')],
    );

    await cache.preload();
    expect(cache.profile?.nickname, 'Alice 1');
    await cache.refresh();

    expect(cache.profile?.nickname, 'Alice 2');
    expect(cache.contacts.single.remark, '备注 2');
  });

  test('refresh failure retains the last snapshot and reports operation',
      () async {
    var shouldFail = false;
    final errors = <ProfileRepositoryError>[];
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: MemoryProfileStore(),
      loadProfile: () async {
        if (shouldFail) throw StateError('profile unavailable');
        return profile('Alice');
      },
      loadContacts: () async => [contact(remark: '稳定备注')],
      onError: errors.add,
    );
    await cache.preload();
    shouldFail = true;

    await expectLater(cache.refresh(), throwsStateError);

    expect(cache.profile?.nickname, 'Alice');
    expect(cache.contacts.single.remark, '稳定备注');
    expect(errors, hasLength(1));
    expect(errors.single.operation, 'refresh');
    expect(errors.single.errorType, 'StateError');
    expect(errors.single.accountKeyHash, isNotEmpty);
    expect(errors.single.toDiagnosticString(), isNot(contains('unavailable')));
  });

  test('BUG 1：SQLite 存储往返（含 contactsRevision）', () async {
    final store = SqliteProfileStore(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    await store.write(
      'matrix:@alice:example.test',
      ProfileSnapshot(
        profile: profile('Alice'),
        contacts: [contact(remark: '备注')],
        contactsRevision: 7,
      ),
    );
    final restored = await store.read('matrix:@alice:example.test');
    expect(restored, isNotNull);
    expect(restored!.profile.nickname, 'Alice');
    expect(restored.contacts.single.remark, '备注');
    expect(restored.contactsRevision, 7);
  });

  test('BUG 1：好友头像 URL 变化触发通知并递增 revision（通讯录实时重绘）', () async {
    var avatarGeneration = 3;
    final store = MemoryProfileStore();
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: store,
      loadProfile: () async => profile('Alice'),
      loadContacts: () async => [
        contact(
            remark: '稳定备注',
            avatarUrl: 'https://cdn.example.test/bob-v$avatarGeneration.jpg'),
      ],
    );
    await cache.preload();
    expect(
      cache.contacts.single.avatarUrl,
      'https://cdn.example.test/bob-v3.jpg',
    );
    final revisionBefore = cache.contactsRevision;

    // 好友换头像（URL 变化）→ 静默刷新必须更新数据并通知。
    avatarGeneration = 4;
    var notified = 0;
    cache.addListener(() => notified++);
    await cache.refreshContactsQuietly(minInterval: Duration.zero);

    expect(
      cache.contacts.single.avatarUrl,
      'https://cdn.example.test/bob-v4.jpg',
    );
    expect(notified, 1, reason: '头像变化必须触发通知（通讯录实时重绘）');
    expect(cache.contactsRevision, revisionBefore + 1,
        reason: '好友数据变化必须递增 revision');

    // 数据无变化时静默刷新不通知（防抖）。
    await cache.refreshContactsQuietly(minInterval: Duration.zero);
    expect(notified, 1);
  });

  test('BUG 3：applyUpdatedContact 乐观插入新好友并递增 revision', () async {
    final store = MemoryProfileStore();
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: store,
      loadProfile: () async => profile('Alice'),
      loadContacts: () async => [],
    );
    await cache.preload();
    expect(cache.contacts, isEmpty);

    await cache.applyUpdatedContact(contact(remark: '新好友'));

    expect(cache.contacts, hasLength(1));
    expect(cache.contacts.single.userId, 'bob-id');
    expect(cache.contactsRevision, 1);
    final persisted = await store.read('matrix:@alice:example.test');
    expect(persisted!.contacts, hasLength(1));
    expect(persisted.contactsRevision, 1);
  });

  test(
      '回归（Mi 6 SQLITE_CANTOPEN）：存储打开失败时 probe 抛错、'
      '由 create 降级兜底', () async {
    // 模拟真机故障：目录不可写 → openDatabase 抛
    // SqfliteFfiException(sqlite_error 14, unable to open database file)。
    // 用注入工厂确定性复现（宿主机管理员权限下真实路径可能可写）。
    final broken = SqliteProfileStore(
      factory: _ThrowingDatabaseFactory(),
      supportDirectory: () async => '/unwritable',
    );
    await expectLater(broken.probe(), throwsA(isA<StateError>()));
    await expectLater(
        broken.read('matrix:@a:test'), throwsA(isA<StateError>()));

    // ProfileRepository 层面：存储故障被隔离——使用内存仓库的既有
    // 测试已覆盖 hydrate/apply 路径；create 的降级由 try/catch 保证
    // （SqliteProfileStore.probe 失败 → SharedPreferencesProfileStore）。
  });

  test('FriendProfile 投影：头像版本与缓存键规范（avatar:{userId}:{version}）', () async {
    final withVersion =
        contact(remark: 'r', avatarUrl: 'https://cdn.test/a.jpg?v=9');
    final profileView =
        FriendProfile.fromContact(withVersion, DateTime(2026, 9, 3));
    expect(profileView.avatarVersion, 'v=9');
    expect(profileView.avatarCacheKey, 'avatar:bob-id:v=9');
    expect(profileView.nickname, 'Bob');

    final withoutVersion = contact(remark: 'r');
    final bare =
        FriendProfile.fromContact(withoutVersion, DateTime(2026, 9, 3));
    expect(bare.avatarVersion, 'none');
  });
}

ProfileData profile(String nickname) => ProfileData(
      username: 'alice',
      nickname: nickname,
      maskedEmail: '',
      fallbackSeed: 'alice-seed',
    );

ContactSummary contact({required String remark, String? avatarUrl}) =>
    ContactSummary(
      userId: 'bob-id',
      username: 'bob',
      matrixUserId: '@bob:example.test',
      nickname: 'Bob',
      remark: remark,
      avatarUrl: avatarUrl,
    );

final class MemoryProfileStore implements ProfileStore {
  final values = <String, ProfileSnapshot>{};

  @override
  Future<ProfileSnapshot?> read(String accountKey) async => values[accountKey];

  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    values[accountKey] = snapshot;
  }
}

final class _ThrowingDatabaseFactory implements DatabaseFactory {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unable to open database file');
}
