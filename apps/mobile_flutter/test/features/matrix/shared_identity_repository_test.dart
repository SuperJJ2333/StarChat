import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';

const owner = ProfileData(
    username: 'owner',
    nickname: 'Owner',
    maskedEmail: '',
    fallbackSeed: 'owner');
ContactSummary friend(
        {String id = 'bob',
        String? remark = ' Private ',
        bool includeAvatar = true,
        String? avatar = 'https://cdn.test/bob?v=2'}) =>
    ContactSummary.fromJson({
      'user_id': id,
      'username': id,
      'matrix_user_id': '@$id:test',
      'nickname': ' Bob ',
      'remark': remark,
      if (includeAvatar) 'avatar_url': avatar,
    });

class Store implements ProfileStore {
  final values = <String, ProfileSnapshot>{};
  @override
  Future<ProfileSnapshot?> read(String key) async => values[key];
  @override
  Future<void> write(String key, ProfileSnapshot value) async {
    values[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'cold quiet refresh coalesces with initial preload without cancelling it',
      () async {
    final store = Store();
    final initialContacts = Completer<List<ContactSummary>>();
    final initialProfile = Completer<ProfileData>();
    final started = Completer<void>();
    var contactReads = 0;
    var profileReads = 0;
    final repo = ProfileRepository.forTesting(
      accountKey: 'cold',
      store: store,
      loadProfile: () {
        profileReads++;
        return initialProfile.future;
      },
      loadContacts: () {
        if (contactReads++ == 0) {
          started.complete();
          return initialContacts.future;
        }
        return Future.value([friend(remark: 'Unexpected duplicate')]);
      },
    );
    final preload = repo.preload();
    await started.future;
    final quiet = repo.refreshContactsQuietly(minInterval: Duration.zero);
    await Future<void>.delayed(Duration.zero);
    initialProfile.complete(owner);
    initialContacts.complete([friend()]);
    await Future.wait([preload, quiet]);
    expect(repo.profile, owner);
    expect(repo.resolveIdentity(userId: 'bob').displayName, 'Private');
    expect(store.values['cold']!.profile, owner);
    expect(contactReads, 1);
    expect(profileReads, 1);
    await repo.preload();
    expect(repo.profile, owner);
  });
  test('cold quiet failure stays silent and leaves preload retryable',
      () async {
    var attempts = 0;
    final repo = ProfileRepository.forTesting(
      accountKey: 'cold-retry',
      store: Store(),
      loadProfile: () async {
        if (attempts++ == 0) throw StateError('offline');
        return owner;
      },
      loadContacts: () async => [friend()],
    );
    await repo.refreshContactsQuietly(minInterval: Duration.zero);
    expect(attempts, 1);
    expect(repo.profile, isNull);
    await repo.preload();
    expect(attempts, 2);
    expect(repo.profile, owner);
  });
  Future<void> refresh(ProfileRepository repo, String kind) => switch (kind) {
        'preload' => repo.preload(),
        'quiet' => repo.refreshContactsQuietly(minInterval: Duration.zero),
        _ => repo.refresh(),
      };
  for (final olderKind in ['preload', 'refresh', 'quiet']) {
    for (final newerKind in ['refresh', 'quiet']) {
      test('$olderKind cannot overwrite a later $newerKind response', () async {
        final store = Store()
          ..values['a'] = ProfileSnapshot(profile: owner, contacts: [friend()]);
        final pending =
            List.generate(2, (_) => Completer<List<ContactSummary>>());
        final started = List.generate(2, (_) => Completer<void>());
        var calls = 0;
        final repo = ProfileRepository.forTesting(
            accountKey: 'a',
            store: store,
            loadProfile: () async => owner,
            loadContacts: () {
              final index = calls++;
              started[index].complete();
              return pending[index].future;
            });
        await repo.hydrate();
        final older = refresh(repo, olderKind);
        await started[0].future;
        final newer = refresh(repo, newerKind);
        await started[1].future;
        pending[1].complete(
            [friend(remark: 'Latest', avatar: 'https://cdn.test/new')]);
        await newer;
        final revision = repo.contactsRevision;
        pending[0].complete([friend(remark: 'Stale', avatar: null)]);
        await older;
        expect(repo.resolveIdentity(userId: 'bob').displayName, 'Latest');
        expect(repo.resolveIdentity(userId: 'bob').avatarUrl,
            'https://cdn.test/new');
        expect(repo.contactsRevision, revision);
        expect(store.values['a']!.contacts.single.avatarUrl,
            'https://cdn.test/new');
      });
    }
  }
  for (final newerKind in ['refresh', 'quiet']) {
    test('failed latest $newerKind retains cache and rejects older response',
        () async {
      final store = Store()
        ..values['a'] = ProfileSnapshot(profile: owner, contacts: [friend()]);
      final pending =
          List.generate(2, (_) => Completer<List<ContactSummary>>());
      final started = List.generate(2, (_) => Completer<void>());
      var calls = 0;
      final repo = ProfileRepository.forTesting(
          accountKey: 'a',
          store: store,
          loadProfile: () async => owner,
          loadContacts: () {
            final index = calls++;
            started[index].complete();
            return pending[index].future;
          });
      await repo.hydrate();
      final older = repo.refresh();
      await started[0].future;
      final newer = refresh(repo, newerKind);
      await started[1].future;
      final expectation = expectLater(
          newer, newerKind == 'quiet' ? completes : throwsStateError);
      pending[1].completeError(StateError('offline'));
      await expectation;
      pending[0].complete([friend(remark: 'Stale', avatar: null)]);
      await older;
      expect(repo.resolveIdentity(userId: 'bob').displayName, 'Private');
      expect(store.values['a']!.contacts.single.avatarUrl,
          'https://cdn.test/bob?v=2');
    });
  }
  test('multiple updates before owner loads preserve other contacts', () async {
    final repo = ProfileRepository.forTesting(accountKey: 'a', store: Store());
    await repo.applyUpdatedContact(friend());
    await repo.applyUpdatedContact(friend(id: 'carol'));
    expect(repo.contacts.map((c) => c.userId), ['bob', 'carol']);
  });
  test('partial contact refresh retains avatar but explicit null clears it',
      () async {
    final store = Store()
      ..values['a'] = ProfileSnapshot(profile: owner, contacts: [friend()]);
    var next = friend(includeAvatar: false);
    final repo = ProfileRepository.forTesting(
        accountKey: 'a',
        store: store,
        loadProfile: () async => owner,
        loadContacts: () async => [next]);
    await repo.hydrate();
    await repo.refresh();
    expect(repo.contacts.single.avatarUrl, 'https://cdn.test/bob?v=2');
    next = friend(avatar: null);
    await repo.refresh();
    expect(repo.contacts.single.avatarUrl, isNull);
  });
  test('business and Matrix IDs resolve the same private identity and notify',
      () async {
    final repo =
        ProfileRepository.forTesting(accountKey: 'viewer-a', store: Store());
    await repo.applyUpdatedContact(friend());
    final business = repo.resolveIdentity(userId: 'bob');
    final matrix = repo.resolveIdentity(matrixUserId: '@bob:test');
    expect(business.displayName, 'Private');
    expect(matrix.displayName, business.displayName);
    expect(matrix.cacheKey, business.cacheKey);
    expect(business.publicDisplayName, 'Bob');
    var notifications = 0;
    repo.addListener(() => notifications++);
    await repo.applyUpdatedContact(friend(remark: '  '));
    expect(repo.resolveIdentity(userId: 'bob').displayName, 'Bob');
    expect(notifications, 1);
  });
  test('account projections and persisted avatar presence are isolated',
      () async {
    final store = Store();
    store.values['a'] = ProfileSnapshot.fromJson(
        ProfileSnapshot(profile: owner, contacts: [friend()]).toJson())!;
    store.values['b'] = ProfileSnapshot.fromJson(ProfileSnapshot(
        profile: owner,
        contacts: [friend(remark: null, includeAvatar: false)]).toJson())!;
    final a = ProfileRepository.forTesting(accountKey: 'a', store: store);
    final b = ProfileRepository.forTesting(accountKey: 'b', store: store);
    await a.hydrate();
    await b.hydrate();
    expect(a.resolveIdentity(userId: 'bob').displayName, 'Private');
    expect(b.resolveIdentity(userId: 'bob').displayName, 'Bob');
    expect(a.resolveIdentity(userId: 'bob').cacheKey,
        isNot(b.resolveIdentity(userId: 'bob').cacheKey));
    expect(
        b
            .resolveIdentity(
                userId: 'bob', avatarUrl: 'https://fallback.test/a')
            .avatarUrl,
        'https://fallback.test/a');
    await b.applyUpdatedContact(friend(avatar: null));
    final cleared =
        b.resolveIdentity(userId: 'bob', avatarUrl: 'https://stale.test/a');
    expect(cleared.avatarIsKnown, isTrue);
    expect(cleared.avatarUrl, isNull);
    expect(a.resolveIdentity(userId: 'bob').avatarUrl, isNotNull);
  });
  test('late read cannot overwrite a successful remark and avatar mutation',
      () async {
    final store = Store()
      ..values['a'] = ProfileSnapshot(profile: owner, contacts: [friend()]);
    final pending = Completer<List<ContactSummary>>();
    final started = Completer<void>();
    final repo = ProfileRepository.forTesting(
        accountKey: 'a',
        store: store,
        loadProfile: () async => owner,
        loadContacts: () {
          started.complete();
          return pending.future;
        });
    final read = repo.refresh();
    await started.future;
    await repo.applyUpdatedContact(friend(remark: 'New', avatar: null));
    pending.complete([friend()]);
    await read;
    final identity = repo.resolveIdentity(userId: 'bob');
    expect(identity.displayName, 'New');
    expect(identity.avatarUrl, isNull);
  });
  test('avatar deletion invalidates only the viewing account retained image',
      () async {
    final store = Store()
      ..values['a'] = ProfileSnapshot(profile: owner, contacts: [friend()]);
    final repo = ProfileRepository.forTesting(accountKey: 'a', store: store);
    await repo.hydrate();
    final key = repo.resolveIdentity(userId: 'bob').cacheKey;
    AvatarCache.rememberSuccessful(
        key, const NetworkImage('https://cdn.test/a'));
    AvatarCache.rememberSuccessful(
        'another-account', const NetworkImage('https://cdn.test/b'));
    await repo.applyUpdatedContact(friend(avatar: null));
    expect(AvatarCache.lastSuccessful(key), isNull);
    expect(AvatarCache.lastSuccessful('another-account'), isNotNull);
    await AvatarCache.invalidateUser('another-account');
  });
}
