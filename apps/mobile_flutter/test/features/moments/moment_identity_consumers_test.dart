import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/features/search/global_search_page.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/moments/personal_moments_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_comment_composer.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_page.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_controller.dart';
import 'moments_flow_test.dart' as fixtures;
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';

void main() {
  testWidgets('retained group member search resolves current remark and avatar',
      (tester) async {
    final cache = ProfileRepository.forTesting(
        accountKey: 'group-viewer',
        store: _Store(),
        loadContacts: () async => [],
        loadProfile: () async => const ProfileData(
            username: 'me',
            nickname: 'Me',
            maskedEmail: '',
            fallbackSeed: 'me'));
    addTearDown(cache.dispose);
    await cache.preload();
    await tester.pumpWidget(CupertinoApp(
        home: GroupMemberSearchPage(
            identityCache: cache,
            snapshot: const GroupChatInfoSnapshot(name: 'Group', members: [
              GroupChatMember(matrixUserId: '@friend:test', displayName: 'Old')
            ]))));
    await tester.pump();
    await cache.applyUpdatedContact(const ContactSummary(
        userId: 'friend',
        username: 'friend',
        matrixUserId: '@friend:test',
        nickname: 'Fresh',
        remark: 'Group remark',
        avatarUrl: 'https://example.test/current.png'));
    await tester.pump();
    expect(find.text('Group remark'), findsOneWidget);
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://example.test/current.png');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'open reply composer follows local remark without mutating parent',
      (tester) async {
    final cache = ProfileRepository.forTesting(
        accountKey: 'reply-viewer',
        store: _Store(),
        loadContacts: () async => [],
        loadProfile: () async => const ProfileData(
            username: 'me',
            nickname: 'Me',
            maskedEmail: '',
            fallbackSeed: 'me'));
    addTearDown(cache.dispose);
    await cache.preload();
    final api = await fixtures.momentsApi((_) async => http.Response('{}', 200,
        headers: {'content-type': 'application/json'}));
    const parent = MomentCommentView(
        id: 'parent',
        text: 'Original',
        author: MomentAuthor(
            userId: 'friend',
            username: 'friend',
            nickname: 'Old',
            displayName: 'Old'));
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                child: const Text('Reply'),
                onPressed: () => showMomentCommentComposer(context,
                    api: api,
                    momentId: 'post',
                    parent: parent,
                    identityCache: cache)))));
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(find.text('回复 Old'), findsOneWidget);
    await cache.applyUpdatedContact(const ContactSummary(
        userId: 'friend',
        username: 'friend',
        matrixUserId: '@friend:test',
        nickname: 'Fresh',
        remark: 'Private remark'));
    await tester.pump();
    expect(find.text('回复 Private remark'), findsOneWidget);
    expect(parent.author.displayName, 'Old');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('search updates a retained result and opened friend profile',
      (tester) async {
    const old = ContactSummary(
        userId: 'friend',
        username: 'friend',
        matrixUserId: '@friend:test',
        nickname: 'Old');
    final cache = ProfileRepository.forTesting(
        accountKey: 'search-viewer',
        store: _Store(),
        loadContacts: () async => [old],
        loadProfile: () async => const ProfileData(
            username: 'me',
            nickname: 'Me',
            maskedEmail: '',
            fallbackSeed: 'me'));
    addTearDown(cache.dispose);
    await cache.preload();
    final api = await fixtures.momentsApi((_) async => http.Response('{}', 200,
        headers: {'content-type': 'application/json'}));
    await tester.pumpWidget(
        CupertinoApp(home: GlobalSearchPage(api: api, identityCache: cache)));
    await tester.pumpAndSettle();
    await cache.applyUpdatedContact(old.copyWith(remark: 'First remark'));
    await tester.pumpAndSettle();
    expect(find.text('First remark'), findsOneWidget);
    await tester.tap(find.text('First remark'));
    await tester.pumpAndSettle();
    expect(find.byType(ContactProfilePage), findsOneWidget);
    await cache.applyUpdatedContact(old.copyWith(remark: 'Second remark'));
    await tester.pumpAndSettle();
    expect(find.text('Second remark'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Second remark'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('personal timeline title follows repository updates',
      (tester) async {
    const old = ContactSummary(
        userId: 'friend',
        username: 'friend',
        matrixUserId: '@friend:test',
        nickname: 'Old');
    final cache = ProfileRepository.forTesting(
        accountKey: 'personal-viewer',
        store: _Store(),
        loadContacts: () async => [old],
        loadProfile: () async => const ProfileData(
            username: 'me',
            nickname: 'Me',
            maskedEmail: '',
            fallbackSeed: 'me'));
    addTearDown(cache.dispose);
    await cache.preload();
    final api = await fixtures.momentsApi((_) async => http.Response('{}', 200,
        headers: {'content-type': 'application/json'}));
    await tester.pumpWidget(CupertinoApp(
        home: PersonalMomentsPage(
            api: api,
            identityCache: cache,
            userId: 'friend',
            displayName: 'Snapshot')));
    await tester.pumpAndSettle();
    expect(find.text('Old的朋友圈'), findsOneWidget);
    await cache.applyUpdatedContact(old.copyWith(remark: 'Latest remark'));
    await tester.pumpAndSettle();
    expect(find.text('Latest remark的朋友圈'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('retained Moments tile resolves author, replies and likes live',
      (tester) async {
    final cache = ProfileRepository.forTesting(
        accountKey: 'viewer',
        store: _Store(),
        loadContacts: () async => [],
        loadProfile: () async => const ProfileData(
            username: 'me',
            nickname: 'Me',
            maskedEmail: '',
            fallbackSeed: 'me'));
    addTearDown(cache.dispose);
    await cache.preload();
    const author = MomentAuthor(
        userId: 'friend',
        username: 'friend',
        nickname: 'Old',
        displayName: 'Old');
    final item = MomentItem(
        id: 'post',
        author: author,
        text: 'post',
        images: [],
        createdAt: DateTime.now(),
        likeUsers: const [author],
        comments: const [
          MomentCommentView(
              id: 'comment',
              text: 'hello',
              author: author,
              parentAuthor: author)
        ]);
    await tester.pumpWidget(
        CupertinoApp(home: WeChatMomentTile(item: item, identityCache: cache)));
    await tester.pump();
    await cache.applyUpdatedContact(const ContactSummary(
        userId: 'friend',
        username: 'friend',
        matrixUserId: '@friend:test',
        nickname: 'Fresh',
        remark: 'Local remark',
        avatarUrl: 'https://example.test/fresh.png'));
    await tester.pump();
    expect(find.text('Local remark'), findsNWidgets(3));
    expect(find.text('回复 '), findsOneWidget);
    expect(
        tester
            .widgetList<UserAvatar>(find.byType(UserAvatar))
            .map((avatar) => avatar.avatarUrl),
        everyElement('https://example.test/fresh.png'));
    await cache.applyUpdatedContact(const ContactSummary(
        userId: 'friend',
        username: 'friend',
        matrixUserId: '@friend:test',
        nickname: 'Cleared'));
    await tester.pump();
    expect(
        tester
            .widgetList<UserAvatar>(find.byType(UserAvatar))
            .map((avatar) => avatar.avatarUrl),
        everyElement(isNull));
    expect(find.text('Cleared'), findsNWidgets(3));
    expect(item.author.displayName, 'Old',
        reason: 'Local remark must never mutate serializable author snapshot');
    await tester.pumpWidget(const SizedBox());
  });
}

class _Store implements ProfileStore {
  @override
  Future<ProfileSnapshot?> read(String key) async => null;
  @override
  Future<void> write(String key, ProfileSnapshot snapshot) async {}
}
