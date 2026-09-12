import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('independent publications cannot persist older snapshot last', () async {
    final store = DelayedWriteProfileStore();
    final contacts = Completer<List<ContactSummary>>();
    final cache = ProfileRepository.forTesting(
        accountKey: 'ordered',
        store: store,
        loadProfile: () async => profile('Owner'),
        loadContacts: () => contacts.future);
    final request = cache.preload();
    await store.entered.future;
    contacts.complete([contact(remark: 'Newest')]);
    await Future<void>.delayed(Duration.zero);
    store.release.complete();
    await request;
    expect(store.saved?.contacts.single.remark, 'Newest');
    cache.dispose();
  });

  test('disposed repository ignores late remote publications', () async {
    final owner = Completer<ProfileData>();
    final friends = Completer<List<ContactSummary>>();
    final store = MemoryProfileStore();
    final cache = ProfileRepository.forTesting(
        accountKey: 'disposed',
        store: store,
        loadProfile: () => owner.future,
        loadContacts: () => friends.future);
    final request = cache.preload();
    await Future<void>.delayed(Duration.zero);
    cache.dispose();
    owner.complete(profile('Late'));
    friends.complete([contact(remark: 'Late')]);
    await request;
    expect(cache.profile, isNull);
    expect(cache.contacts, isEmpty);
    expect(store.values, isEmpty);
  });

  test('quiet contacts refresh cannot cancel pending owner publication',
      () async {
    final store = MemoryProfileStore();
    await store.write('owner',
        ProfileSnapshot(profile: profile('Cached'), contacts: const []));
    final pending = Completer<ProfileData>();
    final cache = ProfileRepository.forTesting(
        accountKey: 'owner',
        store: store,
        loadProfile: () => pending.future,
        loadContacts: () async => [contact(remark: 'New')]);
    final request = cache.refresh();
    await Future<void>.delayed(Duration.zero);
    await cache.refreshContactsQuietly(minInterval: Duration.zero);
    pending.complete(profile('Updated owner'));
    await request;
    expect(cache.profile?.nickname, 'Updated owner');
    cache.dispose();
  });

  test('publishes own profile while contacts are blocked and then fail',
      () async {
    final pending = Completer<List<ContactSummary>>();
    final published = Completer<void>();
    final store = MemoryProfileStore();
    final cache = ProfileRepository.forTesting(
      accountKey: 'independent',
      store: store,
      loadProfile: () async => profile('Fresh owner'),
      loadContacts: () => pending.future,
    );
    cache.addListener(() {
      if (cache.profile != null && !published.isCompleted) published.complete();
    });
    final request = expectLater(cache.preload(), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final observedName = cache.profile?.nickname;
    pending.completeError(StateError('contacts offline'));
    await request;
    expect(observedName, 'Fresh owner');
    expect(published.isCompleted, isTrue);
    expect((await store.read('independent'))?.profile.nickname, 'Fresh owner');
    expect(cache.profile?.nickname, 'Fresh owner');
    cache.dispose();
  });

  test('contacts publish while owner refresh is blocked', () async {
    final store = MemoryProfileStore();
    await store.write('independent',
        ProfileSnapshot(profile: profile('Cached'), contacts: const []));
    final pending = Completer<ProfileData>();
    final cache = ProfileRepository.forTesting(
        accountKey: 'independent',
        store: store,
        loadProfile: () => pending.future,
        loadContacts: () async => [contact(remark: 'Fresh')]);
    final request = cache.refresh();
    await Future<void>.delayed(Duration.zero);
    final observedContacts = cache.contacts;
    pending.complete(profile('Fresh owner'));
    await request;
    expect(observedContacts.single.remark, 'Fresh');
    cache.dispose();
  });

  test('disposed repository ignores late hydration and remote results',
      () async {
    final store = DelayedReadProfileStore();
    final cache =
        ProfileRepository.forTesting(accountKey: 'disposed', store: store);
    final request = cache.hydrate();
    cache.dispose();
    store.pending.complete(
        ProfileSnapshot(profile: profile('Late'), contacts: const []));
    await request;
    expect(cache.profile, isNull);
    expect(store.saved, isNull);
  });

  test('preload retries after a transient failure', () async {
    var attempts = 0;
    final cache = ProfileRepository.forTesting(
      accountKey: 'retry',
      store: MemoryProfileStore(),
      loadProfile: () async {
        if (attempts++ == 0) throw StateError('offline');
        return profile('Alice');
      },
      loadContacts: () async => [contact(remark: 'friend')],
    );
    await expectLater(cache.preload(), throwsStateError);
    await cache.preload();
    expect(cache.contacts, hasLength(1));
    expect(attempts, 2);
    await cache.preload();
    expect(attempts, 2);
  });

  for (final operation in ['quiet refresh', 'preload', 'refresh']) {
    test('in-flight $operation cannot restore a deleted friend', () async {
      final store = MemoryProfileStore();
      final friend = contact(remark: 'friend');
      await store.write('race',
          ProfileSnapshot(profile: profile('Alice'), contacts: [friend]));
      final pending = Completer<List<ContactSummary>>();
      final started = Completer<void>();
      var loads = 0;
      final cache = ProfileRepository.forTesting(
        accountKey: 'race',
        store: store,
        loadProfile: () async => profile('Alice'),
        loadContacts: () {
          if (loads++ > 0) return Future.value([friend]);
          started.complete();
          return pending.future;
        },
      );
      await cache.hydrate();
      final request = operation == 'quiet refresh'
          ? cache.refreshContactsQuietly(minInterval: Duration.zero)
          : operation == 'preload'
              ? cache.preload()
              : cache.refresh();
      await started.future;
      await cache.removeContact(friend.userId);
      pending.complete([friend]);
      await request;
      expect(cache.contacts, isEmpty);
      expect(cache.contactsByMatrixId, isEmpty);
      expect((await store.read('race'))!.contacts, isEmpty);
      // A newly requested authoritative refresh can see a later re-add.
      await cache.refreshContactsQuietly(minInterval: Duration.zero);
      expect(cache.contacts.single.userId, friend.userId);
    });
  }

  test('in-flight hydration cannot restore a deleted friend', () async {
    final store = DelayedReadProfileStore();
    final friend = contact(remark: 'friend');
    final cache =
        ProfileRepository.forTesting(accountKey: 'race', store: store);
    await cache.applyUpdatedContact(friend);
    final hydration = cache.hydrate();
    await cache.removeContact(friend.userId);
    store.pending.complete(
        ProfileSnapshot(profile: profile('Alice'), contacts: [friend]));
    await hydration;
    expect(cache.profile?.nickname, 'Alice');
    expect(cache.contacts, isEmpty);
    expect(cache.contactsByMatrixId, isEmpty);
    expect(store.saved?.contacts, isEmpty);
  });

  test('removes an accepted friend before the profile snapshot has loaded',
      () async {
    final cache = ProfileRepository.forTesting(
      accountKey: 'pending-profile',
      store: MemoryProfileStore(),
    );
    final friend = contact(remark: 'friend');
    await cache.applyUpdatedContact(friend);
    var changes = 0;
    cache.addListener(() => changes++);
    await cache.removeContact(friend.userId);
    expect(cache.contacts, isEmpty);
    expect(cache.contactsByMatrixId, isEmpty);
    expect(changes, 1);
    expect(cache.contactsRevision, 2);
  });

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

  test('late hydration keeps a saved profile and restores cached contacts',
      () async {
    final store = DelayedReadProfileStore();
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: store,
    );
    final hydration = cache.hydrate();
    await cache.applyUpdatedProfile(profile('Saved Alice'));
    store.pending.complete(ProfileSnapshot(
      profile: profile('Stale Alice'),
      contacts: [contact(remark: 'cached remark')],
      contactsRevision: 4,
    ));
    await hydration;

    expect(cache.profile?.nickname, 'Saved Alice');
    expect(cache.contacts.single.remark, 'cached remark');
    expect(store.saved?.profile.nickname, 'Saved Alice');
    expect(store.saved?.contacts.single.remark, 'cached remark');
  });

  test('updated profile persists without replacing contacts after recreation',
      () async {
    final store = MemoryProfileStore();
    await store.write(
      'matrix:@alice:example.test',
      ProfileSnapshot(
          profile: profile('Cached'), contacts: [contact(remark: 'keep')]),
    );
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: store,
    );
    await cache.hydrate();
    await cache.applyUpdatedProfile(profile('Saved Alice'));
    cache.dispose();

    final recreated = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: store,
    );
    await recreated.hydrate();
    expect(recreated.profile?.nickname, 'Saved Alice');
    expect(recreated.contacts.single.remark, 'keep');
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

  // 在线状态字段（last_seen_at）必须参与判等：否则静默刷新拉到了新值
  // 也被判为“未变化”，缓存与 UI 永远停留在旧数据（暂无在线记录）。
  test('quiet refresh applies a changed last_seen_at', () async {
    final store = MemoryProfileStore();
    await store.write(
        'seen',
        ProfileSnapshot(
            profile: profile('Cached'), contacts: [contact(remark: 'Same')]));
    final cache = ProfileRepository.forTesting(
        accountKey: 'seen',
        store: store,
        loadProfile: () async => profile('Cached'),
        loadContacts: () async => [
              contact(remark: 'Same', lastSeenAt: DateTime.utc(2026, 9, 12, 1)),
            ]);
    await cache.hydrate();
    expect(cache.contacts.single.lastSeenAt, isNull);
    await cache.refreshContactsQuietly(minInterval: Duration.zero);
    expect(cache.contacts.single.lastSeenAt, DateTime.utc(2026, 9, 12, 1));
    cache.dispose();
  });
}

ProfileData profile(String nickname) => ProfileData(
      username: 'alice',
      nickname: nickname,
      maskedEmail: '',
      fallbackSeed: 'alice-seed',
    );

ContactSummary contact(
        {required String remark, String? avatarUrl, DateTime? lastSeenAt}) =>
    ContactSummary(
      userId: 'bob-id',
      username: 'bob',
      matrixUserId: '@bob:example.test',
      nickname: 'Bob',
      remark: remark,
      avatarUrl: avatarUrl,
      lastSeenAt: lastSeenAt,
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

final class DelayedReadProfileStore implements ProfileStore {
  final pending = Completer<ProfileSnapshot?>();
  ProfileSnapshot? saved;
  @override
  Future<ProfileSnapshot?> read(String accountKey) => pending.future;
  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    saved = snapshot;
  }
}

final class DelayedWriteProfileStore implements ProfileStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  ProfileSnapshot? saved;
  @override
  Future<ProfileSnapshot?> read(String accountKey) async => null;
  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    saved = snapshot;
  }
}
