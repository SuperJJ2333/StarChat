import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_controller.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_page.dart';

final class FakeContactsGateway implements ContactsGateway {
  @override
  Future<Map<String, dynamic>> contactTags() async => {'items': []};

  @override
  Future<Map<String, dynamic>> createContactTag(String name) async =>
      {'id': 'tag', 'name': name};

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
          userId: 'user-bob',
          username: 'bob',
          matrixUserId: '@bob:example.test',
        ),
        ContactSummary(
          userId: 'user-carol',
          username: 'carol',
          matrixUserId: '@carol:example.test',
        ),
      ];

  @override
  Future<void> blockContact(String userId) async {}

  @override
  Future<void> deleteContact(String userId) async {}

  @override
  Future<ContactDetails> updateContactDetails(
    ContactDetails contact, {
    required String? remark,
    required List<String> tags,
    required String momentsPermission,
  }) async =>
      contact;
}

final class FakeGroupChatGateway implements GroupChatGateway {
  String? name;
  List<String>? invitees;

  @override
  Future<String> createEncryptedGroupChat({
    required String name,
    required List<String> matrixUserIds,
  }) async {
    this.name = name;
    invitees = matrixUserIds;
    return '!group:example.test';
  }
}

final class FakeGroupChatBackend implements GroupChatBackend {
  String? name;
  List<String>? invitees;

  @override
  Future<String> createPrivateEncryptedRoom({
    required String name,
    required List<String> matrixUserIds,
  }) async {
    this.name = name;
    invitees = matrixUserIds;
    return '!encrypted-group:example.test';
  }

  @override
  Future<void> waitUntilJoined(String roomId) async {}
}

void main() {
  test('group service rejects duplicates and waits for the encrypted room',
      () async {
    final backend = FakeGroupChatBackend();
    final service = GroupChatService(backend);

    final roomId = await service.createEncryptedGroupChat(
      name: '项目群',
      matrixUserIds: const [
        '@bob:example.test',
        '@carol:example.test',
        '@bob:example.test',
      ],
    );

    expect(roomId, '!encrypted-group:example.test');
    expect(backend.invitees, ['@bob:example.test', '@carol:example.test']);
  });

  test('group service rejects fewer than two invited friends', () async {
    final backend = FakeGroupChatBackend();
    final service = GroupChatService(backend);

    expect(
      () => service.createEncryptedGroupChat(
        name: '人数不足',
        matrixUserIds: const ['@bob:example.test'],
      ),
      throwsArgumentError,
    );
  });

  test('group creation requires two friends plus the current member', () async {
    final groups = FakeGroupChatGateway();
    final controller = GroupChatController(
      contacts: FakeContactsGateway(),
      groups: groups,
      currentUserDisplayName: 'Alice',
    );

    await controller.load();
    expect(controller.state.contacts, hasLength(2));
    controller.toggle('@bob:example.test');
    expect(controller.canCreate, isFalse);
    controller.toggle('@carol:example.test');
    expect(controller.canCreate, isTrue);

    final roomId = await controller.create('');

    expect(roomId, '!group:example.test');
    expect(groups.name, '');
    expect(
      groups.invitees,
      ['@bob:example.test', '@carol:example.test'],
    );
    expect(controller.state.status, GroupChatStatus.created);
  });

  test('group name is limited to twenty unicode characters', () async {
    final groups = FakeGroupChatGateway();
    final controller = GroupChatController(
      contacts: FakeContactsGateway(),
      groups: groups,
      currentUserDisplayName: 'Alice',
    );
    await controller.load();
    controller.toggle('@bob:example.test');
    controller.toggle('@carol:example.test');

    await controller.create('一二三四五六七八九十一二三四五六七八九十超出');

    expect(groups.name, '一二三四五六七八九十一二三四五六七八九十');
  });

  testWidgets('group creation page selects contacts and returns the room id',
      (tester) async {
    final groups = FakeGroupChatGateway();
    final controller = GroupChatController(
      contacts: FakeContactsGateway(),
      groups: groups,
      currentUserDisplayName: 'Alice',
    );
    String? createdRoomId;

    await tester.pumpWidget(
      CupertinoApp(
        home: GroupChatPage(
          controller: controller,
          onCreated: (roomId) => createdRoomId = roomId,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('发起群聊'), findsOneWidget);
    await tester.tap(find.text('bob'));
    await tester.tap(find.text('carol'));
    await tester.enterText(
      find.byKey(const Key('group-chat-name')),
      '周末活动群',
    );
    await tester.tap(find.byKey(const Key('group-chat-create')));
    await tester.pumpAndSettle();

    expect(createdRoomId, '!group:example.test');
  });
}
