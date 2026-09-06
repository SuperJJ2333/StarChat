import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';

/// BUG4：通讯录"群聊"入口 → 群聊通讯录列表（不再误入发起群聊）。
/// 该区只在 BusinessApiClient 注入时渲染，用 MockClient 构造真实客户端。
void main() {
  testWidgets('ContactsTabPage 透传保存群列表入口', (tester) async {
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(
        accessToken: 'test-access', refreshToken: 'test-refresh');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((_) async => http.Response('{"items":[]}', 200)));
    final sdk = Client('contacts-tab-test');
    final matrix = MatrixSdkE2eeClient(sdk,
        homeserver: Uri.parse('https://matrix.example'));
    final direct = DirectChatController(matrix);
    final pending = ValueNotifier<int>(0);
    var saved = 0;
    var created = 0;
    await tester.pumpWidget(CupertinoApp(
        home: ContactsTabPage(
            api: api,
            matrix: matrix,
            directChats: direct,
            onVoice: (_) async {},
            onVideo: (_) async {},
            onGroupChat: () => created++,
            onGroupAddressList: () => saved++,
            pendingFriendRequests: pending)));
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('contacts-group-address-entry'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(saved, 1);
    expect(created, 0);
    await tester.pumpWidget(const SizedBox());
    direct.dispose();
    pending.dispose();
  });
  Future<BusinessApiClient> api() async {
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(accessToken: 'a', refreshToken: 'r');
    return BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient((request) async => http.Response('{"items":[]}', 200,
          headers: {'content-type': 'application/json'})),
    );
  }

  testWidgets('通讯录首页"群聊"tile 进入群聊通讯录而非发起群聊', (tester) async {
    var addressListOpened = 0;
    var createGroupOpened = 0;
    final client = await api();
    await tester.pumpWidget(CupertinoApp(
      home: ContactsPage(
        api: client,
        pendingFriendRequests: ValueNotifier<int>(0),
        onGroupAddressList: () => addressListOpened++,
        onGroupChat: () => createGroupOpened++,
      ),
    ));
    await tester.pumpAndSettle();

    final tile = find.byKey(const Key('contacts-group-address-entry'));
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(addressListOpened, 1, reason: '群聊 tile 进群聊通讯录');
    expect(createGroupOpened, 0, reason: '不再误入发起群聊');
  });

  testWidgets('onGroupAddressList 缺省时回退发起群聊（向后兼容）', (tester) async {
    var createGroupOpened = 0;
    final client = await api();
    await tester.pumpWidget(CupertinoApp(
      home: ContactsPage(
        api: client,
        pendingFriendRequests: ValueNotifier<int>(0),
        onGroupChat: () => createGroupOpened++,
      ),
    ));
    await tester.pumpAndSettle();
    final tile = find.byKey(const Key('contacts-group-address-entry'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(createGroupOpened, 1);
  });
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
