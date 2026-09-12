import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/contacts/contact_profile_sections.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';

const _owner = ProfileData(
  username: 'owner',
  nickname: 'Owner',
  maskedEmail: '',
  fallbackSeed: 'owner',
);

ContactSummary _contact(
  String id, {
  String nickname = 'Nickname',
  String? remark,
  String? avatarUrl = 'https://cdn.test/avatar.png',
  bool avatarIsKnown = true,
  String? nudgeSuffix,
  List<String> tags = const [],
  DateTime? lastSeenAt,
  bool lastSeenKnown = false,
}) =>
    ContactSummary(
      userId: id,
      username: id,
      matrixUserId: '@$id:test',
      nickname: nickname,
      remark: remark,
      avatarUrl: avatarUrl,
      avatarIsKnown: avatarIsKnown,
      nudgeSuffix: nudgeSuffix,
      tags: tags,
      lastSeenAt: lastSeenAt,
      lastSeenKnown: lastSeenKnown,
    );

final class _Store implements ProfileStore {
  var writes = 0;
  final snapshots = <String, ProfileSnapshot>{};

  @override
  Future<ProfileSnapshot?> read(String key) async => snapshots[key];

  @override
  Future<void> write(String key, ProfileSnapshot value) async {
    writes++;
    snapshots[key] = value;
  }
}

final class _HeldWriteStore implements ProfileStore {
  final snapshots = <String, ProfileSnapshot>{};
  var holdNextWrite = false;
  final writeEntered = Completer<void>();
  final releaseWrite = Completer<void>();

  @override
  Future<ProfileSnapshot?> read(String key) async => snapshots[key];

  @override
  Future<void> write(String key, ProfileSnapshot value) async {
    snapshots[key] = value;
    if (holdNextWrite && !writeEntered.isCompleted) {
      writeEntered.complete();
      await releaseWrite.future;
    }
  }
}

final class _ContactsApi implements ContactsGateway {
  @override
  Future<void> blockContact(String userId) async {}

  @override
  Future<Map<String, dynamic>> contactTags() async => const {'items': []};

  @override
  Future<Map<String, dynamic>> createContactTag(String name) async => const {};

  @override
  Future<void> deleteContact(String userId) async {}

  @override
  Future<void> deleteContactTag(String id) async {}

  @override
  Future<void> deleteContactTags(List<String> ids) async {}

  @override
  Future<ContactSummary?> fetchFriendDetail(String userId) async => null;

  @override
  Future<List<ContactSummary>> listContacts() async => const [];

  @override
  Future<Map<String, dynamic>> renameContactTag(String id, String name) async =>
      const {};

  @override
  Future<ContactDetails> updateContactDetails(
    ContactDetails contact, {
    required String? remark,
    required List<String> tags,
    required String momentsPermission,
  }) async =>
      contact;
}

final class _DeferredDetailsApi extends _ContactsApi {
  final pending = <String, Completer<ContactSummary?>>{};
  final requestedUserIds = <String>[];

  @override
  Future<ContactSummary?> fetchFriendDetail(String userId) {
    requestedUserIds.add(userId);
    return pending.putIfAbsent(userId, Completer<ContactSummary?>.new).future;
  }
}

final class _FixedDetailsApi extends _ContactsApi {
  _FixedDetailsApi(this.detail);

  final ContactSummary? detail;
  final requestedUserIds = <String>[];

  @override
  Future<ContactSummary?> fetchFriendDetail(String userId) async {
    requestedUserIds.add(userId);
    return detail;
  }
}

final class _FailingDetailsApi extends _ContactsApi {
  @override
  Future<ContactSummary?> fetchFriendDetail(String userId) =>
      Future<ContactSummary?>.error(StateError('offline'));
}

ProfileRepository _repository(List<ContactSummary> contacts) =>
    ProfileRepository.forTesting(
      accountKey: 'profile-selector',
      store: _Store(),
      loadProfile: () async => _owner,
      loadContacts: () async => contacts,
    );

void main() {
  test('contact selector emits when presence becomes known with no record',
      () async {
    final repository = _repository([_contact('alice')]);
    addTearDown(repository.dispose);
    await repository.preload();
    final selection = repository.selectContact('alice');
    addTearDown(selection.dispose);
    var notifications = 0;
    selection.addListener(() => notifications++);

    await repository
        .applyUpdatedContact(_contact('alice', lastSeenKnown: true));

    expect(selection.value?.lastSeenKnown, isTrue);
    expect(selection.value?.lastSeenAt, isNull);
    expect(notifications, 1);
  });

  test('contact selector accepts an explicit empty presence in place of a time',
      () async {
    final repository = _repository([
      _contact('alice',
          lastSeenAt: DateTime.utc(2026, 9, 12, 4), lastSeenKnown: true),
    ]);
    addTearDown(repository.dispose);
    await repository.preload();
    final selection = repository.selectContact('alice');
    addTearDown(selection.dispose);
    var notifications = 0;
    selection.addListener(() => notifications++);

    await repository
        .applyUpdatedContact(_contact('alice', lastSeenKnown: true));

    expect(selection.value?.lastSeenKnown, isTrue);
    expect(selection.value?.lastSeenAt, isNull);
    expect(notifications, 1);
  });

  test('contact selector emits only for its user semantic changes', () async {
    final repository = _repository([_contact('alice'), _contact('bob')]);
    addTearDown(repository.dispose);
    await repository.preload();
    final selection = repository.selectContact('alice');
    addTearDown(selection.dispose);
    var notifications = 0;
    selection.addListener(() => notifications++);

    await repository.applyUpdatedContact(_contact('bob', nickname: 'Changed'));
    expect(notifications, 0);
    await repository.applyUpdatedContact(_contact('alice'));
    expect(notifications, 0);
    await repository.applyUpdatedContact(
        _contact('alice', nickname: 'Changed', nudgeSuffix: ' nudge'));
    expect(notifications, 1);
    await repository.applyUpdatedContact(
        _contact('alice', nickname: 'Changed', nudgeSuffix: ' nudge'));
    expect(notifications, 1);
    await repository.applyUpdatedContact(_contact('alice',
        nickname: 'Changed', avatarUrl: null, nudgeSuffix: ' nudge'));
    expect(notifications, 2);
  });

  testWidgets('selectors are safe across disposal and listener removal',
      (tester) async {
    final repository = _repository([_contact('alice')]);
    await repository.preload();
    final first = repository.selectContact('alice');
    final second = repository.selectContact('alice');
    first.addListener(first.dispose);
    second.addListener(second.dispose);
    await repository.applyUpdatedContact(_contact('alice', remark: 'Updated'));
    expect(first.isDisposed, isTrue);
    expect(second.isDisposed, isTrue);
    expect(tester.takeException(), isNull);
    repository.dispose();
    first.dispose();
    second.dispose();
    expect(() => repository.selectContact('alice'), throwsStateError);
  });

  testWidgets('selector reports a listener error and continues delivery',
      (tester) async {
    final store = _Store();
    final repository = ProfileRepository.forTesting(
      accountKey: 'listener-errors',
      store: store,
      loadProfile: () async => _owner,
      loadContacts: () async => [_contact('alice')],
    );
    addTearDown(repository.dispose);
    await repository.preload();
    final selection = repository.selectContact('alice');
    addTearDown(selection.dispose);
    final previousOnError = FlutterError.onError;
    FlutterErrorDetails? reported;
    FlutterError.onError = (details) => reported = details;
    addTearDown(() => FlutterError.onError = previousOnError);
    var delivered = false;
    selection.addListener(() => throw StateError('listener failure'));
    selection.addListener(() => delivered = true);
    final writesBefore = store.writes;

    await repository.applyUpdatedContact(_contact('alice', remark: 'Updated'));

    expect(reported?.exception, isA<StateError>());
    expect(delivered, isTrue);
    expect(store.writes, greaterThan(writesBefore));
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile only schedules a rebuild for its selected contact',
      (tester) async {
    final repository = _repository([
      _contact('alice', nickname: 'Alice'),
      _contact('bob', nickname: 'Bob'),
    ]);
    addTearDown(repository.dispose);
    await repository.preload();
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
        api: _ContactsApi(),
        identityCache: repository,
        initialContact: _contact('alice', nickname: 'Alice').toDetails(),
      ),
    ));
    await tester.pump();

    await repository.applyUpdatedContact(_contact('bob', nickname: 'Robert'));
    expect(tester.binding.hasScheduledFrame, isFalse);

    await repository.applyUpdatedContact(_contact('alice', nickname: 'Alicia'));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(find.text('Alicia'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('profile resets and rebinds when repository or user changes',
      (tester) async {
    final first = _repository([_contact('alice', remark: 'First remark')]);
    final second = _repository(const []);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.preload();
    await second.preload();
    Future<void> build(ProfileRepository repository, ContactDetails contact) =>
        tester.pumpWidget(CupertinoApp(
          home: ContactProfilePage(
            api: _ContactsApi(),
            identityCache: repository,
            initialContact: contact,
          ),
        ));

    await build(first, _contact('alice', nickname: 'Alice').toDetails());
    await tester.pump();
    expect(find.text('First remark'), findsOneWidget);
    await build(second, _contact('alice', nickname: 'Alice').toDetails());
    await tester.pump();
    expect(find.text('First remark'), findsNothing);
    await first.applyUpdatedContact(_contact('alice', remark: 'Old account'));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await second
        .applyUpdatedContact(_contact('alice', remark: 'Second remark'));
    await tester.pump();
    expect(find.text('Second remark'), findsOneWidget);

    await build(second, _contact('bob', nickname: 'Bob').toDetails());
    await tester.pump();
    await second.applyUpdatedContact(_contact('alice', remark: 'Ignored'));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await second.applyUpdatedContact(_contact('bob', remark: 'Bob remark'));
    await tester.pump();
    expect(find.text('Bob remark'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'detail presence merges into current identity and survives offline re-entry',
      (tester) async {
    final store = _Store();
    final repository = ProfileRepository.forTesting(
      accountKey: 'presence-merge',
      store: store,
      loadProfile: () async => _owner,
      loadContacts: () async => [_contact('alice', remark: 'Cached remark')],
    );
    addTearDown(repository.dispose);
    await repository.preload();
    final api = _DeferredDetailsApi();
    final seenAt = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
        api: api,
        identityCache: repository,
        initialContact: _contact('alice', remark: 'Entry remark').toDetails(),
      ),
    ));
    await tester.pump();
    expect(api.requestedUserIds, ['alice']);

    await repository.applyUpdatedContact(_contact('alice',
        remark: 'Edited locally', avatarUrl: 'https://cdn.test/edited.png'));
    await tester.pump();
    api.pending['alice']!.complete(_contact('alice',
        remark: 'Stale API remark',
        avatarUrl: 'https://cdn.test/stale.png',
        lastSeenAt: seenAt,
        lastSeenKnown: true));
    await tester.pump();
    await tester.pump();

    expect(repository.contacts.single.remark, 'Edited locally');
    expect(repository.contacts.single.avatarUrl, 'https://cdn.test/edited.png');
    expect(repository.contacts.single.lastSeenKnown, isTrue);
    expect(repository.contacts.single.lastSeenAt, seenAt);
    expect(find.text('Edited locally'), findsOneWidget);
    expect(find.text('5分钟前在线'), findsOneWidget);

    final restored = ProfileRepository.forTesting(
        accountKey: 'presence-merge', store: store);
    addTearDown(restored.dispose);
    await restored.hydrate();
    expect(restored.contacts.single.lastSeenKnown, isTrue);
    expect(restored.contacts.single.lastSeenAt, seenAt);
    expect(restored.contacts.single.remark, 'Edited locally');
    expect(restored.contacts.single.avatarUrl, 'https://cdn.test/edited.png');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'detail persistence cannot roll page identity back after a newer repository update',
      (tester) async {
    final store = _HeldWriteStore();
    final repository = ProfileRepository.forTesting(
      accountKey: 'detail-write-race',
      store: store,
      loadProfile: () async => _owner,
      loadContacts: () async => [_contact('alice', remark: 'Cached')],
    );
    addTearDown(repository.dispose);
    await repository.preload();
    store.holdNextWrite = true;
    final seenAt = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
        api: _FixedDetailsApi(_contact('alice',
            remark: 'Detail remark', lastSeenAt: seenAt, lastSeenKnown: true)),
        identityCache: repository,
        initialContact: repository.contacts.single.toDetails(),
      ),
    ));
    await store.writeEntered.future;

    final newerUpdate = repository.applyUpdatedContact(
        repository.contacts.single.copyWith(remark: 'Newer remark'));
    await tester.pump();
    store.releaseWrite.complete();
    await newerUpdate;
    await tester.pump();
    await tester.pump();

    expect(repository.contacts.single.remark, 'Newer remark');
    expect(find.text('昵称：Newer remark'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'missing-detail persistence uses the latest repository identity after its write waits',
      (tester) async {
    final store = _HeldWriteStore();
    final seenAt = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final repository = ProfileRepository.forTesting(
      accountKey: 'missing-write-race',
      store: store,
      loadProfile: () async => _owner,
      loadContacts: () async => [
        _contact('alice', lastSeenAt: seenAt, lastSeenKnown: true),
      ],
    );
    addTearDown(repository.dispose);
    await repository.preload();
    store.holdNextWrite = true;
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
        api: _FixedDetailsApi(null),
        identityCache: repository,
        initialContact: repository.contacts.single.toDetails(),
      ),
    ));
    await store.writeEntered.future;

    final newerUpdate = repository.applyUpdatedContact(
        repository.contacts.single.copyWith(remark: 'Newer remark'));
    await tester.pump();
    store.releaseWrite.complete();
    await newerUpdate;
    await tester.pump();
    await tester.pump();

    expect(repository.contacts.single.lastSeenKnown, isFalse);
    expect(find.text('昵称：Newer remark'), findsOneWidget);
    expect(find.text('5分钟前在线'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'a missing friend detail hides cached presence but an error keeps it',
      (tester) async {
    final seenAt = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final initial =
        _contact('alice', lastSeenAt: seenAt, lastSeenKnown: true).toDetails();
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
          api: _FixedDetailsApi(null), initialContact: initial),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('5分钟前在线'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
          api: _FailingDetailsApi(), initialContact: initial),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('5分钟前在线'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'a missing detail clears cached presence without removing the friend',
      (tester) async {
    final store = _Store();
    final seenAt = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final repository = ProfileRepository.forTesting(
      accountKey: 'missing-detail',
      store: store,
      loadProfile: () async => _owner,
      loadContacts: () async => [
        _contact('alice', lastSeenAt: seenAt, lastSeenKnown: true),
      ],
    );
    addTearDown(repository.dispose);
    await repository.preload();
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
        api: _FixedDetailsApi(null),
        identityCache: repository,
        initialContact: repository.contacts.single.toDetails(),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(repository.contacts, hasLength(1));
    expect(repository.contacts.single.lastSeenKnown, isFalse);
    expect(repository.contacts.single.lastSeenAt, isNull);

    await repository.applyUpdatedContact(
        repository.contacts.single.copyWith(remark: 'Identity changed'));
    await tester.pump();
    expect(find.text('5分钟前在线'), findsNothing);

    final restored = ProfileRepository.forTesting(
        accountKey: 'missing-detail', store: store);
    addTearDown(restored.dispose);
    await restored.hydrate();
    expect(restored.contacts, hasLength(1));
    expect(restored.contacts.single.lastSeenKnown, isFalse);
    expect(restored.contacts.single.lastSeenAt, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('detail without presence leaves a known cached time unchanged',
      (tester) async {
    final seenAt = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final repository = _repository([
      _contact('alice', lastSeenAt: seenAt, lastSeenKnown: true),
    ]);
    addTearDown(repository.dispose);
    await repository.preload();
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
        api: _FixedDetailsApi(_contact('alice')),
        identityCache: repository,
        initialContact: repository.contacts.single.toDetails(),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(repository.contacts.single.lastSeenKnown, isTrue);
    expect(repository.contacts.single.lastSeenAt, seenAt);
    expect(find.text('5分钟前在线'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'an authorized detail caches a missing local contact for offline profile entry',
      (tester) async {
    final store = _Store();
    final repository = ProfileRepository.forTesting(
      accountKey: 'authorized-detail',
      store: store,
      loadProfile: () async => _owner,
      loadContacts: () async => const [],
    );
    addTearDown(repository.dispose);
    await repository.preload();
    final seenAt = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final fresh = _contact('alice',
        nickname: 'Fresh name',
        remark: 'Fresh remark',
        avatarUrl: 'https://cdn.test/fresh.png',
        lastSeenAt: seenAt,
        lastSeenKnown: true);
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
        api: _FixedDetailsApi(fresh),
        identityCache: repository,
        initialContact: _contact('alice', nickname: 'Entry name').toDetails(),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(repository.contacts.single.userId, 'alice');
    expect(repository.contacts.single.nickname, 'Fresh name');
    expect(repository.contacts.single.lastSeenAt, seenAt);

    final restored = ProfileRepository.forTesting(
        accountKey: 'authorized-detail', store: store);
    addTearDown(restored.dispose);
    await restored.hydrate();
    expect(restored.contacts.single.nickname, 'Fresh name');
    expect(restored.contacts.single.lastSeenAt, seenAt);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unchanged identity accepts explicit empty detail fields',
      (tester) async {
    final repository = _repository([
      _contact('alice',
          nickname: 'Cached nickname',
          remark: 'Cached remark',
          avatarUrl: 'https://cdn.test/cached.png'),
    ]);
    addTearDown(repository.dispose);
    await repository.preload();
    final emptyDetail = _contact('alice',
        nickname: '', remark: null, avatarUrl: null, avatarIsKnown: true);
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
        api: _FixedDetailsApi(emptyDetail),
        identityCache: repository,
        initialContact: repository.contacts.single.toDetails(),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(repository.contacts.single.nickname, isEmpty);
    expect(repository.contacts.single.remark, isNull);
    expect(repository.contacts.single.avatarUrl, isNull);
    expect(repository.contacts.single.avatarIsKnown, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'presence status advances only in foreground and redraws on resume',
      (tester) async {
    var now = DateTime(2026, 9, 12, 12);
    await tester.pumpWidget(CupertinoApp(
      home: FriendIdentityCard(
        contact: _contact('alice',
                lastSeenAt: now.subtract(const Duration(minutes: 1)),
                lastSeenKnown: true)
            .toDetails(),
        now: () => now,
      ),
    ));
    expect(find.text('1分钟前在线'), findsOneWidget);

    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('2分钟前在线'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('2分钟前在线'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('3分钟前在线'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('old api completion cannot write a replacement repository',
      (tester) async {
    final first = _repository([_contact('alice')]);
    final second = _repository([_contact('alice')]);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.preload();
    await second.preload();
    final oldApi = _DeferredDetailsApi();
    final seenAt = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final newApi = _FixedDetailsApi(
        _contact('alice', lastSeenAt: seenAt, lastSeenKnown: true));
    final contact = _contact('alice').toDetails();

    Future<void> build(ContactsGateway api, ProfileRepository repository) =>
        tester.pumpWidget(CupertinoApp(
          home: ContactProfilePage(
            key: const ValueKey('same-profile'),
            api: api,
            identityCache: repository,
            initialContact: contact,
          ),
        ));

    await build(oldApi, first);
    await tester.pump();
    expect(oldApi.requestedUserIds, ['alice']);
    await build(newApi, second);
    await tester.pump();
    await tester.pump();
    expect(newApi.requestedUserIds, ['alice']);

    oldApi.pending['alice']!.complete(_contact('alice',
        lastSeenAt: seenAt.subtract(const Duration(hours: 1)),
        lastSeenKnown: true));
    await tester.pump();
    await tester.pump();
    expect(first.contacts.single.lastSeenKnown, isFalse);
    expect(second.contacts.single.lastSeenAt, seenAt);
    expect(find.text('5分钟前在线'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('old api completion cannot overwrite the same repository',
      (tester) async {
    final repository = _repository([_contact('alice')]);
    addTearDown(repository.dispose);
    await repository.preload();
    final oldApi = _DeferredDetailsApi();
    final newSeenAt =
        DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final newApi = _FixedDetailsApi(
        _contact('alice', lastSeenAt: newSeenAt, lastSeenKnown: true));
    final contact = _contact('alice').toDetails();

    Future<void> build(ContactsGateway api) => tester.pumpWidget(CupertinoApp(
          home: ContactProfilePage(
            key: const ValueKey('same-profile-api'),
            api: api,
            identityCache: repository,
            initialContact: contact,
          ),
        ));

    await build(oldApi);
    await tester.pump();
    await build(newApi);
    await tester.pump();
    await tester.pump();
    expect(newApi.requestedUserIds, ['alice']);
    expect(repository.contacts.single.lastSeenAt, newSeenAt);

    oldApi.pending['alice']!.complete(_contact('alice',
        lastSeenAt: newSeenAt.subtract(const Duration(hours: 1)),
        lastSeenKnown: true));
    await tester.pump();
    await tester.pump();
    expect(repository.contacts.single.lastSeenAt, newSeenAt);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('old detail completion cannot update a switched user profile',
      (tester) async {
    final repository = _repository([_contact('alice'), _contact('bob')]);
    addTearDown(repository.dispose);
    await repository.preload();
    final api = _DeferredDetailsApi();
    final alice = _contact('alice').toDetails();
    final bob = _contact('bob').toDetails();
    Future<void> build(ContactDetails contact) => tester.pumpWidget(
          CupertinoApp(
            home: ContactProfilePage(
              key: const ValueKey('switched-profile'),
              api: api,
              identityCache: repository,
              initialContact: contact,
            ),
          ),
        );

    await build(alice);
    await tester.pump();
    await build(bob);
    await tester.pump();
    expect(api.requestedUserIds, ['alice', 'bob']);
    final freshBob =
        DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    api.pending['bob']!
        .complete(_contact('bob', lastSeenAt: freshBob, lastSeenKnown: true));
    await tester.pump();
    await tester.pump();
    api.pending['alice']!.complete(_contact('alice',
        lastSeenAt: freshBob.subtract(const Duration(hours: 1)),
        lastSeenKnown: true));
    await tester.pump();
    await tester.pump();
    expect(repository.contactsByUserId['alice']?.lastSeenKnown, isFalse);
    expect(repository.contactsByUserId['bob']?.lastSeenAt, freshBob);
    expect(find.text('5分钟前在线'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('detail for another user is ignored', (tester) async {
    final repository = _repository([_contact('alice')]);
    addTearDown(repository.dispose);
    await repository.preload();
    final seenAt = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
        api: _FixedDetailsApi(
            _contact('bob', lastSeenAt: seenAt, lastSeenKnown: true)),
        identityCache: repository,
        initialContact: _contact('alice').toDetails(),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(repository.contacts.single.userId, 'alice');
    expect(repository.contacts.single.lastSeenKnown, isFalse);
    expect(find.text('bob'), findsNothing);
    expect(find.text('5分钟前在线'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('profile actions receive the selected current contact',
      (tester) async {
    final repository = _repository([_contact('alice', nickname: 'Alice')]);
    addTearDown(repository.dispose);
    await repository.preload();
    ContactDetails? messaged;
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
        api: _ContactsApi(),
        identityCache: repository,
        initialContact: _contact('alice', nickname: 'Alice').toDetails(),
        onMessage: (contact) async => messaged = contact,
      ),
    ));
    await tester.pump();
    await repository.applyUpdatedContact(
        _contact('alice', nickname: 'Alicia', remark: 'Private'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('friend-action-message')));
    await tester.pump();
    expect(messaged?.displayName, 'Private');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('page disposal after repository disposal is exception-free',
      (tester) async {
    final repository = _repository([_contact('alice')]);
    await repository.preload();
    await tester.pumpWidget(CupertinoApp(
      home: ContactProfilePage(
        api: _ContactsApi(),
        identityCache: repository,
        initialContact: _contact('alice').toDetails(),
      ),
    ));
    await tester.pump();
    repository.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'presence throttle is reused only by the same API and repository context',
      (tester) async {
    final api = _FixedDetailsApi(_contact('alice', lastSeenKnown: true));
    final first = _repository([_contact('alice', lastSeenKnown: true)]);
    final second = _repository([_contact('alice', lastSeenKnown: true)]);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.preload();
    await second.preload();

    Future<void> open(ProfileRepository repository) async {
      await tester.pumpWidget(CupertinoApp(
        home: ContactProfilePage(
          api: api,
          identityCache: repository,
          initialContact: repository.contacts.single.toDetails(),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    await open(first);
    expect(api.requestedUserIds, ['alice']);
    await tester.pumpWidget(const SizedBox.shrink());

    await open(first);
    expect(api.requestedUserIds, ['alice'],
        reason: 'a fresh same-context presence result is throttled');
    await tester.pumpWidget(const SizedBox.shrink());

    await open(second);
    expect(api.requestedUserIds, ['alice', 'alice'],
        reason: 'a replacement repository must refresh its own account state');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('warmup selects at most nine explicit unique avatars from 50k',
      (tester) async {
    final contacts = List.generate(
        50000,
        (index) =>
            _contact('u$index', avatarUrl: 'https://cdn.test/$index.png'));
    final repository = _repository(contacts);
    addTearDown(repository.dispose);
    await repository.preload();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox));
    final warmed = <String>[];
    await repository.precacheAvatarImages(context,
        matrixUserIds: [
          '@u1:test',
          '@u1:test',
          '@u2:test',
          '@u3:test',
          '@u4:test',
          '@u5:test',
          '@u6:test',
          '@u7:test',
          '@u8:test',
          '@u9:test',
          '@u10:test'
        ],
        prefetch: (key, _) async => warmed.add(key));
    expect(
        warmed, [for (var i = 1; i <= 8; i++) 'identity:profile-selector:u$i']);
  });

  testWidgets('warmup stops after a held request loses its owner',
      (tester) async {
    final repository =
        _repository([_contact('a'), _contact('b'), _contact('c')]);
    addTearDown(repository.dispose);
    await repository.preload();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox));
    final held = Completer<void>();
    var active = true;
    var requests = 0;
    final warming = repository.precacheAvatarImages(context,
        matrixUserIds: ['@a:test', '@b:test', '@c:test'],
        shouldContinue: () => active,
        prefetch: (_, __) async {
          requests++;
          if (requests == 1) await held.future;
        });
    await tester.pump();
    active = false;
    held.complete();
    await warming;
    expect(requests, 1);
  });
}
