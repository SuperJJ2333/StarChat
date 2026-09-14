
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/ui/chat/flash_photo.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'profile_repository_test.dart' show MemoryProfileStore;

final class _FlashClient extends Client {
  _FlashClient(String tag) : super('room-page-flash-$tag') {
    room = _FlashRoom(this, tag);
  }

  late final _FlashRoom room;

  @override
  String? get userID => '@flash-user:test';

  @override
  Room? getRoomById(String roomId) => roomId == room.id ? room : null;
}

final class _FlashRoom extends Room {
  _FlashRoom(Client client, String tag)
      : super(id: '!flash-$tag:test', client: client);

  @override
  bool get isDirectChat => false;

  @override
  bool get encrypted => true;

  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
  }) async =>
      _FlashTimeline(this);

  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
  }) async =>
      r'$flash-echo';
}

final class _FlashTimeline extends Fake implements Timeline {
  _FlashTimeline(Room room)
      : events = [
          Event(
            room: room,
            eventId: r'$flash',
            senderId: '@peer:test',
            type: EventTypes.Message,
            originServerTs: DateTime.utc(2026, 9, 14),
            content: const {
              'msgtype': 'm.image',
              'body': '[闪照]',
              'flash': '1',
            },
          ),
        ];

  @override
  final List<Event> events;

  @override
  bool get isFragmentedTimeline => false;

  @override
  bool get canRequestHistory => false;

  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {}

  @override
  void cancelSubscriptions() {}
}

ProfileData _profile() => const ProfileData(
      username: 'flash-user',
      nickname: 'Flash user',
      maskedEmail: '',
      fallbackSeed: 'flash-user',
    );

Future<BusinessApiClient> _api() async {
  final session = SecureSessionStore(_MemoryStore());
  await session.saveSession(
      accessToken: 'test-access', refreshToken: 'test-refresh');
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.test'),
    sessionStore: session,
    client: MockClient((request) async {
      if (request.url.path.endsWith('/profile/me')) {
        return http.Response(
          '{"username":"flash-user","nickname":"Flash user",'
          '"masked_email":"","avatar_fallback_seed":"flash-user"}',
          200,
        );
      }
      return http.Response('{}', 404);
    }),
  );
}

Future<MatrixRoomLease> _lease(_FlashClient client) =>
    MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://matrix.test'))
        .openRoomLease(client.room.id);

ProfileRepository _identityCache() => ProfileRepository.forTesting(
      accountKey: 'matrix:@flash-user:test',
      store: MemoryProfileStore(),
      loadProfile: () async => _profile(),
      loadContacts: () async => const [],
    );

Future<void> _pumpRoom(WidgetTester tester, _FlashClient client) async {
  final identities = _identityCache();
  await identities.preload();
  await tester.pumpWidget(CupertinoApp(
    home: RoomPage(
      api: await _api(),
      roomLease: await _lease(client),
      roomName: 'Flash room',
      initialIdentityCache: identities,
      onCreateGroup: () {},
    ),
  ));
  await tester.pump();
  await tester.pump();
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

void main() {
  testWidgets('flash photo: no forward action, destroyed caption blocks reopen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = _FlashClient('a');
    await _pumpRoom(tester, client);

    // 马赛克气泡 + 闪电角标渲染。
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('flash-photo-bubble')), findsOneWidget);
    expect(find.byKey(const Key('flash-bolt-badge')), findsOneWidget);

    // 长按菜单不含「转发」（直接触发气泡长按回调，避免路由残留）。
    final row = find
        .byType(WeChatMessageBubble)
        .evaluate()
        .map((element) => element.widget as WeChatMessageBubble)
        .firstWhere((widget) => widget.onLongPress != null);
    row.onLongPress!();
    await tester.pump();
    await tester.pump();
    expect(find.text('转发'), findsNothing,
        reason: '闪照禁止转发，菜单不得出现转发入口');
    expect(find.byKey(const Key('flash-photo-viewer')), findsNothing);

    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(tester.takeException(), isNull);

    // 已看标记驱动销毁态：换一台“已看过”的设备（预置标记）再进房。
    SharedPreferences.setMockInitialValues({
      'flash-viewed:matrix:@flash-user:test': [r'$flash'],
    });
    final viewedClient = _FlashClient('b');
    await _pumpRoom(tester, viewedClient);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(FlashPhotoBubble).evaluate().isNotEmpty) break;
    }
    final bubble =
        tester.widget<FlashPhotoBubble>(find.byType(FlashPhotoBubble));
    expect(bubble.viewed, isTrue, reason: '预置已看标记应驱动气泡销毁态');
    expect(find.byKey(const Key('flash-destroyed-caption')), findsOneWidget);

    await tester.tap(find.byKey(const Key('flash-photo-bubble')),
        warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('flash-photo-viewer')), findsNothing,
        reason: '已销毁的闪照不能再打开查看');

    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
