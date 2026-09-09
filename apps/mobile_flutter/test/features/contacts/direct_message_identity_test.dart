import 'package:flutter/cupertino.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:matrix/matrix.dart';

void main() {
  for (final cached in [false, true]) {
    testWidgets(
        cached
            ? 'cached friend opens without waiting for another contacts request'
            : 'new friend refreshes shared identity before opening a DM',
        (tester) async {
      const friend = ContactSummary(
          userId: 'bob', username: 'bob', matrixUserId: '@bob:test');
      const profile = ProfileData(
          username: 'self',
          nickname: 'self',
          maskedEmail: '',
          fallbackSeed: 'self');
      final store = MemoryProfileStore();
      await store.write('self',
          ProfileSnapshot(profile: profile, contacts: cached ? [friend] : []));
      var loads = 0;
      final quietRefresh = Completer<List<ContactSummary>>();
      final identity = ProfileRepository.forTesting(
          accountKey: 'self',
          store: store,
          loadProfile: () async => profile,
          loadContacts: () async {
            loads++;
            if (cached && loads > 1) return quietRefresh.future;
            return loads == 1 && !cached ? [] : [friend];
          });
      await identity.preload();
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://business.test'),
          sessionStore: SecureSessionStore(_MemoryStore()),
          client: MockClient((_) async => http.Response('{"items":[]}', 200)));
      var openedWithFriend = false;
      final gateway = _Gateway(() {
        openedWithFriend =
            identity.contactsByMatrixId.containsKey(friend.matrixUserId);
      });
      final direct = DirectChatController(gateway);
      final sdk = Client('identity-test');
      final pending = ValueNotifier(0);
      await tester.pumpWidget(CupertinoApp(
          home: ContactsTabPage(
              api: api,
              matrix: MatrixSdkE2eeClient(sdk,
                  homeserver: Uri.parse('https://matrix.test')),
              directChats: direct,
              onVoice: (_) async {},
              onVideo: (_) async {},
              onGroupChat: () {},
              pendingFriendRequests: pending,
              identityCache: identity)));
      await tester.pumpAndSettle();
      // Exercise the production callback without constructing a network room.
      final action =
          tester.widget<ContactsPage>(find.byType(ContactsPage)).onMessage!;
      final opening = action(friend.toDetails());
      await tester.pumpAndSettle();
      expect(openedWithFriend, isTrue);
      // Entry refresh runs quietly; even when it remains pending, the cached
      // friend's DM callback must open immediately without a third request.
      expect(loads, 2);
      if (cached) quietRefresh.complete([friend]);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      await opening;
      await tester.pumpWidget(const SizedBox());
      direct.dispose();
      pending.dispose();
      identity.dispose();
    });
  }
}

class _Gateway implements DirectChatGateway {
  _Gateway(this.onOpen);
  final VoidCallback onOpen;
  @override
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId) async {
    onOpen();
    throw StateError('test stops before room navigation');
  }
}

class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class MemoryProfileStore implements ProfileStore {
  final values = <String, ProfileSnapshot>{};
  @override
  Future<ProfileSnapshot?> read(String accountKey) async => values[accountKey];
  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    values[accountKey] = snapshot;
  }
}
