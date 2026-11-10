import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = ProfileData(
  username: 'owner',
  nickname: 'Owner',
  maskedEmail: '',
  fallbackSeed: 'owner',
);

ContactSummary _contact(String name) => ContactSummary(
      userId: 'contact',
      username: 'contact',
      matrixUserId: '@contact:test',
      nickname: name,
    );

final class _PendingContacts implements ContactsGateway {
  final response = Completer<List<ContactSummary>>();
  int requests = 0;

  @override
  Future<List<ContactSummary>> listContacts() {
    requests++;
    return response.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('disk hydration fills the existing contacts list while offline',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPreferencesProfileStore(
      await SharedPreferences.getInstance(),
    );
    const scope = 'matrix:@owner:test';
    await store.write(
      scope,
      ProfileSnapshot(profile: _owner, contacts: [_contact('上次通讯录')]),
    );
    final api = _PendingContacts();
    final network = Completer<List<ContactSummary>>();
    final repository = ProfileRepository.forTesting(
      accountKey: scope,
      store: store,
      loadProfile: () async => _owner,
      loadContacts: () => network.future,
    );
    addTearDown(repository.dispose);
    final pendingRequests = ValueNotifier(0);
    addTearDown(pendingRequests.dispose);
    Widget page(ProfileRepository? cache) => CupertinoApp(
          home: ContactsPage(
            api: api,
            onOpenRoom: (_, {anchorEventId}) async {},
            pendingFriendRequests: pendingRequests,
            identityCache: cache,
          ),
        );

    await tester.pumpWidget(page(null));
    final scroll = tester.widget<ListView>(find.byType(ListView)).controller;
    await repository.hydrate();
    await tester.pumpWidget(page(repository));
    expect(find.text('上次通讯录'), findsOneWidget);
    expect(tester.widget<ListView>(find.byType(ListView)).controller,
        same(scroll));

    network.complete([_contact('最新通讯录')]);
    api.response.complete([_contact('过期响应')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('最新通讯录'), findsOneWidget);
    expect(find.text('过期响应'), findsNothing);
    expect(tester.widget<ListView>(find.byType(ListView)).controller,
        same(scroll));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending first request shows a list empty state and navigation',
      (tester) async {
    final api = _PendingContacts();
    final pendingRequests = ValueNotifier(0);
    addTearDown(pendingRequests.dispose);
    await tester.pumpWidget(CupertinoApp(
      home: ContactsPage(
        api: api,
        onOpenRoom: (_, {anchorEventId}) async {},
        pendingFriendRequests: pendingRequests,
      ),
    ));
    expect(find.text('通讯录'), findsOneWidget);
    expect(find.text('暂无联系人'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
  });

  testWidgets('admission refresh preserves cached rows and the scroll offset',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPreferencesProfileStore(
      await SharedPreferences.getInstance(),
    );
    const scope = 'matrix:@owner:test';
    final cached = List.generate(
      30,
      (i) => ContactSummary(
        userId: 'contact-$i',
        username: 'contact-$i',
        matrixUserId: '@contact-$i:test',
        nickname: 'Cached ${i.toString().padLeft(2, '0')}',
      ),
    );
    await store.write(
        scope, ProfileSnapshot(profile: _owner, contacts: cached));
    final response = Completer<List<ContactSummary>>();
    var refreshes = 0;
    final repository = ProfileRepository.forTesting(
      accountKey: scope,
      store: store,
      loadProfile: () async => _owner,
      loadContacts: () {
        refreshes++;
        return response.future;
      },
    );
    await repository.hydrate();
    addTearDown(repository.dispose);
    final pendingRequests = ValueNotifier(0);
    addTearDown(pendingRequests.dispose);
    final api = _PendingContacts();
    Widget page({required bool localOnly}) => CupertinoApp(
          home: ContactsPage(
            api: api,
            onOpenRoom: (_, {anchorEventId}) async {},
            pendingFriendRequests: pendingRequests,
            identityCache: repository,
            localOnly: localOnly,
          ),
        );

    await tester.pumpWidget(page(localOnly: true));
    expect(find.text('Cached 00'), findsOneWidget);
    await tester.tap(find.text('Cached 00'));
    await tester.pump();
    expect(find.text('好友资料'), findsNothing);
    expect(api.requests, 0);
    expect(refreshes, 0);
    final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
    scroll.jumpTo(400);
    await tester.pump();

    await tester.pumpWidget(page(localOnly: false));
    expect(refreshes, 1);
    expect(scroll.offset, 400);
    expect(find.text('Cached 12'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    final updated = [
      for (final item in cached)
        item.copyWith(nickname: item.nickname!.replaceFirst('Cached', 'Fresh')),
    ];
    response.complete(updated);
    await repository.preload();
    await tester.pump();
    expect(find.text('Fresh 12'), findsOneWidget);
    expect(scroll.offset, 400);
    expect(api.requests, 0);
    expect((await store.read(scope))!.contacts[12].nickname, 'Fresh 12');
    await tester.pumpWidget(const SizedBox());
  });
}
