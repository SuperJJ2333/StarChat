import 'package:flutter/cupertino.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/ui/components/wechat_nav_title.dart';
import 'profile_repository_test.dart' show MemoryProfileStore;

BusinessApiClient _api() => BusinessApiClient(
    baseUri: Uri.parse('https://example.test'),
    sessionStore: SecureSessionStore());

Future<BusinessApiClient> _supportApi() async {
  final sessionStore = SecureSessionStore(_MemoryStore());
  await sessionStore.saveSession(
      accessToken: 'test-access',
      refreshToken: 'test-refresh',
      matrixUserId: '@self:matrix.example');
  return BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: sessionStore,
      client: MockClient((_) async => http.Response.bytes(
          utf8.encode(
              '{"items":[{"query_id":"@friend:test","user_id":"friend","matrix_user_id":"@friend:test","badge":"官方客服","role":"SUPPORT_AGENT"}]}'),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'})));
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

class _Room extends Room {
  _Room({required super.client, this.direct = true})
      : super(id: '!contact-state:test');
  final bool direct;
  @override
  bool get isDirectChat => direct;
  @override
  String? get directChatMatrixID => direct ? '@friend:test' : null;
}

class _RoomClient extends Client {
  _RoomClient({bool direct = true}) : super('contact-state') {
    testRoom = _Room(client: this, direct: direct);
  }
  late final Room testRoom;
  @override
  Room? getRoomById(String roomId) => roomId == testRoom.id ? testRoom : null;
}

Future<MatrixRoomLease> _lease({bool direct = true}) async {
  final client = _RoomClient(direct: direct);
  return MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://matrix.test'))
      .openRoomLease(client.testRoom.id);
}

const _friend = ContactDetails(
    userId: 'friend',
    username: 'friend',
    nickname: 'Friend',
    matrixUserId: '@friend:test');

void main() {
  testWidgets('private room title shows only its verified support suffix',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
      api: await _supportApi(),
      roomLease: await _lease(),
      roomName: 'Friend',
      initialContact: _friend,
      onCreateGroup: () {},
    )));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    final dynamic state = tester.state(find.byType(RoomPage));
    expect(state.isGroup, isFalse);
    final title = tester.widget<WeChatNavTitle>(find.byType(WeChatNavTitle));
    expect(title.matrixUserId, '@friend:test');
    expect(find.text('@官方客服'), findsOneWidget);
  });

  testWidgets('group room title never shows a support suffix', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
      api: await _supportApi(),
      roomLease: await _lease(direct: false),
      roomName: 'Group',
      initialContact: _friend,
      onCreateGroup: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('@官方客服'), findsNothing);
  });
  testWidgets(
      'deleting the active peer clears state and disables profile navigation',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = ProfileRepository.forTesting(
        accountKey: 'test', store: MemoryProfileStore());
    await cache.applyUpdatedContact(_friend.toSummary());
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
            api: _api(),
            roomLease: await _lease(),
            roomName: 'Friend',
            initialContact: _friend,
            initialIdentityCache: cache,
            onCreateGroup: () {})));
    await tester.pump();
    final dynamic state = tester.state(find.byType(RoomPage));
    expect(state.peer, isNotNull);
    await cache.removeContact('friend');
    await tester.pump();
    expect(state.peer, isNull);
    final navigation = tester
        .widget<CupertinoNavigationBar>(find.byType(CupertinoNavigationBar));
    expect((navigation.middle! as CupertinoButton).onPressed, isNull);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    expect(tester.takeException(), isNull,
        reason: 'disposing room voice cleanup must not call setState');
  });

  testWidgets('initial peer survives before the identity cache has loaded',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = ProfileRepository.forTesting(
        accountKey: 'empty', store: MemoryProfileStore());
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
            api: _api(),
            roomLease: await _lease(),
            roomName: 'Friend',
            initialContact: _friend,
            initialIdentityCache: cache,
            onCreateGroup: () {})));
    await tester.pump();
    final dynamic state = tester.state(find.byType(RoomPage));
    expect(state.peer, _friend);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('contact changes do not clear a group page peer fallback',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = ProfileRepository.forTesting(
        accountKey: 'group', store: MemoryProfileStore());
    await cache.applyUpdatedContact(_friend.toSummary());
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
            api: _api(),
            roomLease: await _lease(direct: false),
            roomName: 'Group',
            initialContact: _friend,
            initialIdentityCache: cache,
            onCreateGroup: () {})));
    await tester.pump();
    final dynamic state = tester.state(find.byType(RoomPage));
    await cache.removeContact('friend');
    await tester.pump();
    expect(state.peer, _friend);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    expect(tester.takeException(), isNull);
  });
}
