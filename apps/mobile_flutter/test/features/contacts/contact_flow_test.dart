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

  testWidgets('friend profile and settings strictly follow Figma order',
      (tester) async {
    final gateway = FakeContactsGateway();
    await tester.pumpWidget(CupertinoApp(home: ContactsPage(api: gateway)));
    await tester.pumpAndSettle();

    expect(find.text('产品小艾'), findsOneWidget);
    expect(find.textContaining('9eec2ca7'), findsNothing);
    await tester.tap(find.text('产品小艾'));
    await tester.pumpAndSettle();

    expect(find.text('好友资料'), findsOneWidget);
    expect(find.text('畅聊号：alice'), findsOneWidget);
    expect(find.text('朋友圈'), findsOneWidget);
    expect(find.text('发消息'), findsOneWidget);
    expect(find.text('语音通话'), findsOneWidget);
    expect(find.text('视频通话'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.chat_bubble_2), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.phone), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.video_camera), findsOneWidget);

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
}
