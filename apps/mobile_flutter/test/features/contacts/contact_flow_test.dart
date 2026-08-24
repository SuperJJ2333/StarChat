import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/chat_identity_cache.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';

final class FakeContactsGateway implements ContactsGateway {
  var deleted = false;
  var blocked = false;
  List<String> lastTags = const [];
  String? lastRemark;

  @override
  Future<Map<String, dynamic>> contactTags() async => {
        'items': [
          {'id': 'tag-1', 'name': '同事'},
          {'id': 'tag-2', 'name': '家人'},
        ],
      };

  @override
  Future<Map<String, dynamic>> createContactTag(String name) async =>
      {'id': 'tag-new', 'name': name};

  @override
  Future<Map<String, dynamic>> renameContactTag(String id, String name) async =>
      {'id': id, 'name': name};

  @override
  Future<void> deleteContactTag(String id) async {}
  @override
  Future<void> deleteContactTags(List<String> ids) async {}

  @override
  Future<List<ContactSummary>> listContacts() async => const [
        ContactSummary(
          userId: '9eec2ca7-76db-45e2-a716-7b918330f094',
          username: 'alice',
          nickname: 'Alice',
          remark: '产品小艾',
          matrixUserId: '@alice:matrix.example.test',
        ),
      ];

  @override
  Future<ContactDetails> updateContactDetails(
    ContactDetails contact, {
    required String? remark,
    required List<String> tags,
    required String momentsPermission,
  }) async {
    lastTags = tags;
    lastRemark = remark;
    return contact.copyWith(
      remark: remark,
      tags: tags,
      momentsPermission: momentsPermission,
    );
  }

  @override
  Future<void> blockContact(String userId) async => blocked = true;

  @override
  Future<void> deleteContact(String userId) async => deleted = true;
}

final class IndexedContactsGateway extends FakeContactsGateway {
  @override
  Future<List<ContactSummary>> listContacts() async => [
        ContactSummary(
          userId: 'z',
          username: 'zane',
          nickname: 'Zane',
          matrixUserId: '@zane:example.test',
        ),
        ContactSummary(
          userId: 'star',
          username: 'alice',
          nickname: 'Alice',
          matrixUserId: '@alice:example.test',
          starred: true,
        ),
        ContactSummary(
          userId: 'a',
          username: 'amy',
          nickname: 'Amy',
          matrixUserId: '@amy:example.test',
        ),
        ContactSummary(
          userId: 'hash',
          username: '9lives',
          nickname: '九命',
          matrixUserId: '@9lives:example.test',
        ),
        ContactSummary(
          userId: 'b',
          username: 'bob',
          nickname: 'Bob',
          matrixUserId: '@bob:example.test',
        ),
        for (var index = 0; index < 12; index++)
          ContactSummary(
            userId: 'b-$index',
            username: 'b$index',
            nickname: 'B$index',
            matrixUserId: '@b$index:example.test',
          ),
      ];
}

void main() {
  testWidgets('contacts rebuild immediately when the shared remark changes',
      (tester) async {
    final store = ContactFlowIdentityStore();
    final cache = ChatIdentityCache.forTesting(
      accountKey: 'matrix:@me:test',
      store: store,
    );
    await store.write(
      'matrix:@me:test',
      const ChatIdentitySnapshot(
        profile: ProfileData(
          username: 'me',
          nickname: '我的昵称',
          maskedEmail: '',
          fallbackSeed: 'me',
        ),
        contacts: [
          ContactSummary(
            userId: 'user-1',
            username: 'alice',
            nickname: 'Alice',
            remark: '旧备注',
            matrixUserId: '@alice:test',
          ),
        ],
      ),
    );
    await cache.hydrate();
    await tester.pumpWidget(CupertinoApp(
      home: ContactsPage(
        api: FakeContactsGateway(),
        identityCache: cache,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('旧备注'), findsOneWidget);

    await cache.applyUpdatedContact(
      const ContactSummary(
        userId: 'user-1',
        username: 'alice',
        nickname: 'Alice',
        remark: '新备注',
        matrixUserId: '@alice:test',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('新备注'), findsOneWidget);
    expect(find.text('旧备注'), findsNothing);
  });

  testWidgets('contacts follow Figma star A-Z hash index and grouping',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      CupertinoApp(home: ContactsPage(api: IndexedContactsGateway())),
    );
    await tester.pumpAndSettle();

    const labels = ['★', ...ContactIndex.alphabet, '#'];
    final index = find.byKey(const Key('contact-index'));
    expect(index, findsOneWidget);
    for (final label in labels) {
      expect(
        find.descendant(of: index, matching: find.text(label)),
        findsOneWidget,
      );
    }
    final positions = ['星标好友', 'A', 'B']
        .map(
          (label) =>
              tester.getTopLeft(find.byKey(Key('contact-section-$label'))).dy,
        )
        .toList(growable: false);
    expect(positions, orderedEquals(positions.toList()..sort()));
    await tester.tap(
      find.descendant(of: index, matching: find.text('Z')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('contact-section-Z')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('contacts index follows the list surface during pull down',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      CupertinoApp(home: ContactsPage(api: IndexedContactsGateway())),
    );
    await tester.pumpAndSettle();

    final index = find.byKey(const Key('contact-index'));
    final firstSection = find.byKey(const Key('contact-section-星标好友'));
    final indexTop = tester.getTopLeft(index).dy;
    final indexHeight = tester.getSize(index).height;
    final sectionTop = tester.getTopLeft(firstSection).dy;

    await tester.drag(find.byType(ListView).first, const Offset(0, 72));
    await tester.pump();

    expect(tester.getTopLeft(firstSection).dy, greaterThan(sectionTop + 20));
    expect(tester.getTopLeft(index).dy, greaterThan(indexTop + 20));
    expect(tester.getSize(index).height, indexHeight);
  });
  test('contact remark is a viewer-local display override', () {
    const contact = ContactSummary(
        userId: 'u2',
        username: 'test',
        nickname: '测试账号',
        remark: '客服',
        matrixUserId: '@test:example.test');
    expect(contact.displayName, '客服');
    expect(contact.nickname, '测试账号');
  });

  test('contact display name is remark then nickname then username', () {
    const base = ContactSummary(
      userId: 'uuid',
      username: 'alice',
      nickname: 'Alice',
      remark: '小艾',
      matrixUserId: '@alice:example.test',
    );
    expect(base.displayName, '小艾');
    expect(base.copyWith(remark: '').displayName, 'Alice');
    expect(base.copyWith(remark: '', nickname: '').displayName, 'alice');
  });
  test('contact details clear an explicitly removed remark', () {
    const contact = ContactDetails(
      userId: 'uuid',
      username: 'alice',
      nickname: 'Alice',
      remark: '旧备注',
      matrixUserId: '@alice:example.test',
    );
    expect(contact.copyWith(clearRemark: true).displayName, 'Alice');
  });

  test('contact details map all identity fields to a summary independently',
      () {
    const details = ContactDetails(
      userId: 'uuid',
      username: 'alice-login',
      nickname: 'Alice 昵称',
      remark: '项目小艾',
      matrixUserId: '@alice:example.test',
      avatarUrl: 'https://cdn.example.test/alice.jpg',
      nudgeSuffix: '拍了拍肩膀',
      momentsPermission: 'HIDE_THEM',
      tags: ['项目组'],
      starred: true,
    );

    final summary = details.toSummary();

    expect(summary.username, 'alice-login');
    expect(summary.nickname, 'Alice 昵称');
    expect(summary.remark, '项目小艾');
    expect(summary.avatarUrl, 'https://cdn.example.test/alice.jpg');
    expect(summary.matrixUserId, '@alice:example.test');
    expect(summary.tags, ['项目组']);
    expect(summary.starred, isTrue);
  });

  testWidgets('friend profile and settings strictly follow Figma order',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = FakeContactsGateway();
    await tester.pumpWidget(CupertinoApp(home: ContactsPage(api: gateway)));
    await tester.pumpAndSettle();

    expect(find.text('产品小艾'), findsOneWidget);
    expect(find.textContaining('9eec2ca7'), findsNothing);
    await tester.tap(find.text('产品小艾'));
    await tester.pumpAndSettle();

    expect(find.text('好友资料'), findsOneWidget);
    expect(find.text('畅聊号：alice'), findsOneWidget);
    expect(find.text('朋友圈'), findsNothing);
    expect(find.text('发消息'), findsOneWidget);
    expect(find.text('语音通话'), findsOneWidget);
    expect(find.text('视频通话'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.chat_bubble_2), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.phone), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.video_camera), findsOneWidget);

    expect(
      tester.getSize(find.byKey(const Key('friend-identity-card'))).height,
      126,
    );
    expect(find.text('刚刚在线'), findsOneWidget);
    final actionTops = ['message', 'voice', 'video']
        .map(
          (action) =>
              tester.getTopLeft(find.byKey(Key('friend-action-$action'))).dy,
        )
        .toList(growable: false);
    expect(actionTops[0], lessThan(actionTops[1]));
    expect(actionTops[1], lessThan(actionTops[2]));
    for (final action in ['message', 'voice', 'video']) {
      expect(
        tester.getSize(find.byKey(Key('friend-action-$action'))),
        const Size(361, 48),
      );
    }

    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pumpAndSettle();
    expect(find.text('好友设置'), findsOneWidget);
    expect(find.text('备注'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    expect(find.text('朋友圈权限'), findsOneWidget);
    expect(find.text('黑名单'), findsOneWidget);
    expect(find.text('删除好友'), findsOneWidget);
    final ordered = ['备注', '标签', '朋友圈权限', '黑名单', '删除好友']
        .map((label) => tester.getTopLeft(find.text(label)).dy)
        .toList(growable: false);
    expect(ordered, ordered.toList()..sort());
    expect(find.byType(CupertinoSwitch), findsOneWidget);
  });

  testWidgets('friend tag picker saves multiple selected tags', (tester) async {
    final gateway = FakeContactsGateway();
    const contact = ContactDetails(
      userId: 'user-1',
      username: 'alice',
      matrixUserId: '@alice:test',
      nickname: 'Alice',
      tags: ['同事'],
    );
    await tester.pumpWidget(CupertinoApp(
      home: ContactTagPickerPage(api: gateway, contact: contact),
    ));
    await tester.pumpAndSettle();
    expect(find.text('同事'), findsOneWidget);
    expect(find.text('家人'), findsOneWidget);
    await tester.tap(find.text('家人'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(gateway.lastTags, containsAll(['同事', '家人']));
  });

  testWidgets(
      'friend remark saves through the gateway and is retained by the profile',
      (tester) async {
    final gateway = FakeContactsGateway();
    const contact = ContactDetails(
      userId: 'user-1',
      username: 'alice',
      matrixUserId: '@alice:test',
      nickname: 'Alice',
    );
    await tester.pumpWidget(CupertinoApp(
      home: ContactMorePage(api: gateway, contact: contact),
    ));
    await tester.tap(find.text('备注'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField), '新的备注');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(gateway.lastRemark, '新的备注');
    expect(find.text('新的备注'), findsOneWidget);
  });

  testWidgets(
      'friend profile covers the root tab bar like the Figma detail page',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = FakeContactsGateway();
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoTabScaffold(
          tabBar: CupertinoTabBar(
            items: const [
              BottomNavigationBarItem(icon: Icon(CupertinoIcons.chat_bubble)),
              BottomNavigationBarItem(icon: Icon(CupertinoIcons.person_2)),
            ],
          ),
          tabBuilder: (_, __) => CupertinoTabView(
            builder: (_) => ContactsPage(api: gateway),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('产品小艾'));
    await tester.pumpAndSettle();

    expect(find.text('好友资料'), findsOneWidget);
    expect(find.byType(CupertinoTabBar), findsNothing);
  });

  testWidgets('friend moments shrink without overflow below 393px baseline',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = FakeContactsGateway();
    await tester.pumpWidget(CupertinoApp(home: ContactsPage(api: gateway)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('产品小艾'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('profile message action navigates once while back pops profile',
      (tester) async {
    var messageRequests = 0;
    await tester.pumpWidget(CupertinoApp(
      home: ContactsPage(
        api: FakeContactsGateway(),
        onMessage: (_) async => messageRequests++,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('产品小艾'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('friend-action-message')));
    await tester.pump();
    expect(messageRequests, 1);
    expect(find.text('好友资料'), findsOneWidget);

    await tester.tap(find.byType(CupertinoNavigationBarBackButton));
    await tester.pumpAndSettle();
    expect(find.text('好友资料'), findsNothing);
    expect(messageRequests, 1);
  });
  testWidgets(
      'contacts navigation exposes WeChat-style search and more actions',
      (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(CupertinoApp(home: ContactsPage(api: api)));
    await tester.pump();
    expect(find.byKey(const Key('contacts-search')), findsOneWidget);
    expect(find.byKey(const Key('contacts-more')), findsOneWidget);
  });
}

final class ContactFlowIdentityStore implements ChatIdentityStore {
  final values = <String, ChatIdentitySnapshot>{};

  @override
  Future<ChatIdentitySnapshot?> read(String accountKey) async =>
      values[accountKey];

  @override
  Future<void> write(String accountKey, ChatIdentitySnapshot snapshot) async {
    values[accountKey] = snapshot;
  }
}
