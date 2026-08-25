import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/chat_identity_cache.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';

void main() {
  test('hydrates the prior account avatar metadata before a network refresh',
      () async {
    final store = MemoryChatIdentityStore();
    await store.write(
      'matrix:@alice:example.test',
      ChatIdentitySnapshot(
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

    final cache = ChatIdentityCache.forTesting(
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
    final store = MemoryChatIdentityStore();
    final cache = ChatIdentityCache.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: store,
    );
    await store.write(
      'matrix:@alice:example.test',
      ChatIdentitySnapshot(
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
    final cache = ChatIdentityCache.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: MemoryChatIdentityStore(),
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
    final errors = <ChatIdentityCacheError>[];
    final cache = ChatIdentityCache.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: MemoryChatIdentityStore(),
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
}

ProfileData profile(String nickname) => ProfileData(
      username: 'alice',
      nickname: nickname,
      maskedEmail: '',
      fallbackSeed: 'alice-seed',
    );

ContactSummary contact({required String remark}) => ContactSummary(
      userId: 'bob-id',
      username: 'bob',
      matrixUserId: '@bob:example.test',
      nickname: 'Bob',
      remark: remark,
    );

final class MemoryChatIdentityStore implements ChatIdentityStore {
  final values = <String, ChatIdentitySnapshot>{};

  @override
  Future<ChatIdentitySnapshot?> read(String accountKey) async =>
      values[accountKey];

  @override
  Future<void> write(String accountKey, ChatIdentitySnapshot snapshot) async {
    values[accountKey] = snapshot;
  }
}
