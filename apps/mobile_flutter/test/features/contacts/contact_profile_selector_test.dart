import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
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
    );

final class _Store implements ProfileStore {
  var writes = 0;
  @override
  Future<ProfileSnapshot?> read(String key) async => null;

  @override
  Future<void> write(String key, ProfileSnapshot value) async => writes++;
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

ProfileRepository _repository(List<ContactSummary> contacts) =>
    ProfileRepository.forTesting(
      accountKey: 'profile-selector',
      store: _Store(),
      loadProfile: () async => _owner,
      loadContacts: () async => contacts,
    );

void main() {
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

  testWidgets('warmup selects at most nine explicit unique avatars from 50k',
      (tester) async {
    final contacts = List.generate(
        50000,
        (index) => _contact('u$index',
            avatarUrl: 'https://cdn.test/$index.png'));
    final repository = _repository(contacts);
    addTearDown(repository.dispose);
    await repository.preload();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox));
    final warmed = <String>[];
    await repository.precacheAvatarImages(context,
        matrixUserIds: [
          '@u1:test', '@u1:test', '@u2:test', '@u3:test', '@u4:test',
          '@u5:test', '@u6:test', '@u7:test', '@u8:test', '@u9:test',
          '@u10:test'
        ], prefetch: (key, _) async => warmed.add(key));
    expect(warmed, [for (var i = 1; i <= 8; i++) 'identity:profile-selector:u$i']);
  });

  testWidgets('warmup stops after a held request loses its owner',
      (tester) async {
    final repository = _repository([
      _contact('a'), _contact('b'), _contact('c')
    ]);
    addTearDown(repository.dispose);
    await repository.preload();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox));
    final held = Completer<void>();
    var active = true;
    var requests = 0;
    final warming = repository.precacheAvatarImages(context,
        matrixUserIds: ['@a:test', '@b:test', '@c:test'],
        shouldContinue: () => active, prefetch: (_, __) async {
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
