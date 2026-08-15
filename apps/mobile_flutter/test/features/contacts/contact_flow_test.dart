import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';

final class FakeContactsGateway implements ContactsGateway {
  var deleted = false;
  var blocked = false;

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
  }) async =>
      contact.copyWith(
        remark: remark,
        tags: tags,
        momentsPermission: momentsPermission,
      );

  @override
  Future<void> blockContact(String userId) async => blocked = true;

  @override
  Future<void> deleteContact(String userId) async => deleted = true;
}

void main() {
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

  testWidgets('contacts hide UUID and move settings behind More',
      (tester) async {
    final gateway = FakeContactsGateway();
    await tester.pumpWidget(CupertinoApp(home: ContactsPage(api: gateway)));
    await tester.pumpAndSettle();

    expect(find.text('产品小艾'), findsOneWidget);
    expect(find.textContaining('9eec2ca7'), findsNothing);
    await tester.tap(find.text('产品小艾'));
    await tester.pumpAndSettle();

    expect(find.text('消息'), findsOneWidget);
    expect(find.text('语音通话'), findsOneWidget);
    expect(find.text('视频通话'), findsOneWidget);
    expect(find.text('备注名'), findsNothing);
    expect(find.text('加入黑名单'), findsNothing);

    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pumpAndSettle();
    expect(find.text('备注名'), findsOneWidget);
    expect(find.text('标签（逗号分隔）'), findsOneWidget);
    expect(find.text('朋友圈权限'), findsOneWidget);
    expect(find.text('加入黑名单'), findsOneWidget);
    expect(find.text('删除好友'), findsOneWidget);
  });
}
