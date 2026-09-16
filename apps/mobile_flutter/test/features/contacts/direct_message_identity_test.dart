import 'package:flutter/cupertino.dart';
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

/// 通讯录只是「好友资料 → 发消息」的入口之一：它必须把 AppHome 的统一入口
/// （权威身份解析 + DirectChatController + _openManagedRoom）原样透传，不得自己
/// 实现 direct chat 查找、RoomLease 管理或 RoomPage 推送。
/// 权威身份解析本身（含刚接受的好友、Matrix ID 已更新的旧快照）由
/// `test/features/matrix/direct_chat_entry_test.dart` 覆盖。
void main() {
  const friend = ContactSummary(
      userId: 'bob',
      username: 'bob',
      matrixUserId: '@bob:test',
      nickname: 'Bob',
      remark: '产品小艾');

  testWidgets('通讯录把 AppHome 的统一「发消息」入口原样透传', (tester) async {
    final harness = await _Harness.create(friend);
    addTearDown(harness.dispose);
    final opened = <ContactDetails>[];

    await tester.pumpWidget(CupertinoApp(
        home: harness.tab(onMessage: (contact) async => opened.add(contact))));
    await tester.pumpAndSettle();

    final page = tester.widget<ContactsPage>(find.byType(ContactsPage));
    expect(identical(page.onMessage, harness.lastOnMessage), isTrue,
        reason: '通讯录不得包装/替换统一入口');
    expect(identical(page.onVoice, harness.lastOnVoice), isTrue);
    expect(identical(page.onVideo, harness.lastOnVideo), isTrue);

    // 资料页「发消息」调用的仍是注入的统一入口（联系人快照原样传入，
    // 由入口按业务 userId 重新解析权威身份）。
    await tester.tap(find.text('产品小艾'));
    await tester.pumpAndSettle();
    expect(find.text('好友资料'), findsOneWidget);
    await tester.tap(find.byKey(const Key('friend-action-message')));
    await tester.pumpAndSettle();
    expect(opened.single.userId, 'bob');
    expect(opened.single.matrixUserId, '@bob:test');
  });
}

final class _Harness {
  _Harness._(this.api, this.matrix, this.direct, this.pending, this.identity);

  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final DirectChatController direct;
  final ValueNotifier<int> pending;
  final ProfileRepository identity;

  Future<void> Function(ContactDetails)? lastOnMessage;
  Future<void> Function(ContactDetails)? lastOnVoice;
  Future<void> Function(ContactDetails)? lastOnVideo;

  static Future<_Harness> create(ContactSummary friend) async {
    final session = SecureSessionStore(_MemoryStore());
    await session.saveSession(
        accessToken: 'test-access', refreshToken: 'test-refresh');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.test'),
        sessionStore: session,
        client: MockClient((_) async => http.Response('{"items":[]}', 200)));
    final identity = ProfileRepository.forTesting(
        accountKey: 'self',
        store: _ProfileStore(friend),
        loadProfile: () async => const ProfileData(
            username: 'self',
            nickname: 'self',
            maskedEmail: '',
            fallbackSeed: 'self'),
        loadContacts: () async => [friend]);
    await identity.preload();
    return _Harness._(
      api,
      MatrixSdkE2eeClient(Client('contacts-tab-entry'),
          homeserver: Uri.parse('https://matrix.test')),
      DirectChatController(_UnusedGateway()),
      ValueNotifier<int>(0),
      identity,
    );
  }

  Widget tab({required Future<void> Function(ContactDetails) onMessage}) {
    lastOnMessage = onMessage;
    lastOnVoice = (_) async {};
    lastOnVideo = (_) async {};
    return ContactsTabPage(
      api: api,
      matrix: matrix,
      directChats: direct,
      onMessage: lastOnMessage!,
      onVoice: lastOnVoice!,
      onVideo: lastOnVideo!,
      onGroupChat: () {},
      pendingFriendRequests: pending,
      identityCache: identity,
    );
  }

  void dispose() {
    direct.dispose();
    pending.dispose();
    identity.dispose();
  }
}

final class _UnusedGateway implements DirectChatGateway {
  @override
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId) =>
      throw StateError('统一入口由 AppHome 注入，通讯录不得自行打开房间');
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

final class _ProfileStore implements ProfileStore {
  _ProfileStore(this.friend);
  final ContactSummary friend;
  ProfileSnapshot? _snapshot;
  @override
  Future<ProfileSnapshot?> read(String accountKey) async => _snapshot;
  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    _snapshot = ProfileSnapshot(
      profile: snapshot.profile,
      contacts: snapshot.contacts.isEmpty ? [friend] : snapshot.contacts,
      contactsRevision: snapshot.contactsRevision,
    );
  }
}
