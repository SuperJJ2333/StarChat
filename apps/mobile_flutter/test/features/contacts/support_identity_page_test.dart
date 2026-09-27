import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/support_identity_repository.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';

const _contact = ContactSummary(
  userId: 'support-1', username: 'support', nickname: '客服小张',
  matrixUserId: '@support:test',
);

void main() {
  testWidgets('uncached contacts refresh removes a revoked support badge',
      (tester) async {
    final api = _Api([
      const [SupportIdentity(queryId: 'support-1', userId: 'support-1', matrixUserId: '@support:test', badge: '官方客服', role: SupportRole.supportAgent)],
      const [],
    ]);
    final repository = SupportIdentityRepository(api);
    await tester.pumpWidget(CupertinoApp(home: ContactsPage(
      api: api, onOpenRoom: (_, {anchorEventId}) async {},
      supportIdentities: repository,
      pendingFriendRequests: ValueNotifier(0),
    )));
    await tester.pump();
    expect(find.text('@官方客服'), findsOneWidget);

    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(find.text('@官方客服'), findsOneWidget);
    await repository.refreshKnown();
    await tester.pump();
    expect(find.text('@官方客服'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    repository.dispose();
  });

  testWidgets('late old API support result cannot color a replaced profile',
      (tester) async {
    final old = _Api([null]);
    final fresh = _Api([const []]);
    await tester.pumpWidget(CupertinoApp(home: ContactProfilePage(
      api: old, initialContact: _contact.toDetails(),
    )));
    await tester.pump();
    await tester.pumpWidget(CupertinoApp(home: ContactProfilePage(
      api: fresh, initialContact: _contact.toDetails(),
    )));
    await tester.pump();
    old.complete(const [SupportIdentity(queryId: 'support-1', userId: 'support-1', matrixUserId: '@support:test', badge: '官方客服', role: SupportRole.supportAgent)]);
    await tester.pump();
    expect(find.text('@官方客服'), findsNothing);
  });
}

final class _Api implements ContactsGateway, SupportIdentityGateway {
  _Api(this.responses);
  final List<List<SupportIdentity>?> responses;
  Completer<List<SupportIdentity>>? _pending;
  void complete(List<SupportIdentity> items) => _pending?.complete(items);
  @override Future<List<SupportIdentity>> lookupSupportIdentities(List<String> ids) {
    final value = responses.removeAt(0);
    if (value == null) { _pending = Completer(); return _pending!.future; }
    return Future.value(value);
  }
  @override Future<List<ContactSummary>> listContacts() async => const [_contact];
  @override Future<ContactSummary?> fetchFriendDetail(String id) async => _contact;
  @override Future<Map<String,dynamic>> contactTags() async => const {};
  @override Future<Map<String,dynamic>> createContactTag(String n) async => const {};
  @override Future<Map<String,dynamic>> renameContactTag(String i,String n) async => const {};
  @override Future<void> deleteContactTag(String id) async {}
  @override Future<void> deleteContactTags(List<String> ids) async {}
  @override Future<void> blockContact(String id) async {}
  @override Future<Map<String, dynamic>> blockList() async => {'items': []};
  @override Future<void> unblockContact(String id) async {}
  @override Future<void> deleteContact(String id) async {}
  @override Future<ContactDetails> updateContactDetails(ContactDetails c,{required String? remark,required List<String> tags,required String momentsPermission}) async => c;
}
