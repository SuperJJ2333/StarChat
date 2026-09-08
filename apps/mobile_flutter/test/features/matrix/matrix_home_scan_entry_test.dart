import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/scan_qr_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:liuhetong_mobile/ui/components/conversation_list_tile.dart';
import 'package:matrix/matrix.dart';

/// 首页加号「扫一扫」入口：此前是无动作空项，点击只收起菜单；
/// 现在必须跳转 ScanQrPage(api: widget.api)（与发现页同款入口）。
void main() {
  late BusinessApiClient api;

  setUp(() async {
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
    api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      // 心跳/资料加载等后台请求一律 500——页面侧均已捕获，不影响本测试。
      client: MockClient((request) async =>
          request.url.path.endsWith('/profile/privacy')
              ? http.Response('{"auto_allow_group_join":false}', 200)
              : http.Response('{}', 500)),
    );
  });

  Future<void> pumpHome(WidgetTester tester,
      {bool dark = false,
      bool invite = false,
      bool encrypted = false,
      bool previewOnly = false}) async {
    final sdk = _NoNetworkClient();
    if (encrypted) {
      final room =
          Room(id: '!locked:example', client: sdk, membership: Membership.join);
      room.lastEvent = Event.fromJson({
        'event_id': r'$locked',
        'type': EventTypes.Encrypted,
        'sender': '@peer:matrix.example',
        'origin_server_ts': 1000,
        'content': {
          'algorithm': 'm.megolm.v1.aes-sha2',
          'body': 'fake-error-detail'
        },
      }, room);
      sdk.rooms.add(room);
    }
    if (invite) {
      sdk.rooms.add(Room(
          id: '!pending:example', client: sdk, membership: Membership.invite));
    }
    final matrix = MatrixSdkE2eeClient(
      sdk,
      homeserver: Uri.parse('https://matrix.example'),
    );
    await tester.pumpWidget(CupertinoApp(
      theme: CupertinoThemeData(
          brightness: dark ? Brightness.dark : Brightness.light),
      home: MatrixHomePage(
        api: api,
        previewOnly: previewOnly,
        matrix: matrix,
        themeController: ThemeController(store: _MemoryThemeStore()),
        onCreateGroup: () {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'cached-only startup displays local rooms before authentication refresh',
      (tester) async {
    await pumpHome(tester, previewOnly: true, encrypted: true);
    expect(find.byKey(const ValueKey<String>('conversation-!locked:example')),
        findsOneWidget);
    expect(find.textContaining('fake-error-detail'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('locked group preview is blank without sender or unread prefix',
      (tester) async {
    await pumpHome(tester, encrypted: true);
    final tile = tester.widget<ConversationListTile>(
        find.byKey(const ValueKey<String>('conversation-!locked:example')));
    expect(tile.subtitle, '');
    expect(find.textContaining('消息尚未解密'), findsNothing);
    expect(find.textContaining('fake-error-detail'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending group invitation header uses a dark surface',
      (tester) async {
    await pumpHome(tester, dark: true, invite: true);
    final panel = tester
        .widget<Container>(find.byKey(const Key('pending-group-invites')));
    expect(panel.color, WeChatColors.darkElevated);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('消息加号菜单的扫一扫跳转 ScanQrPage', (tester) async {
    await pumpHome(tester);

    await tester.tap(find.byKey(const Key('messages-more')));
    await tester.pumpAndSettle();
    expect(find.text('扫一扫'), findsOneWidget);

    await tester.tap(find.text('扫一扫'));
    await tester.pumpAndSettle();

    expect(find.byType(ScanQrPage), findsOneWidget,
        reason: '扫一扫必须进入扫码页而不是仅收起菜单');
    final page = tester.widget<ScanQrPage>(find.byType(ScanQrPage));
    expect(page.api, same(api), reason: '扫码页必须拿到组合根的 api 实例');
  });
}

/// 不触网的 Matrix Client：覆盖 /sync 端点方法返回空同步结果，
/// 页面 initState 的首次 sync() 立即完成且无网络副作用。
final class _NoNetworkClient extends Client {
  _NoNetworkClient() : super('home-scan-entry-test');

  // Invite display names need the current member, just as a signed-in client does.
  @override
  String get userID => '@self:matrix.example';

  @override
  Future<SyncUpdate> sync(
          {String? filter,
          String? since,
          bool? fullState,
          PresenceType? setPresence,
          int? timeout}) async =>
      SyncUpdate.fromJson(const {});
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

final class _MemoryThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}
