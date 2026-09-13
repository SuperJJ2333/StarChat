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
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';
import 'profile_repository_test.dart' show MemoryProfileStore;

final class _NudgeClient extends Client {
  _NudgeClient() : super('room-page-nudge') {
    room = _NudgeRoom(this);
  }

  late final _NudgeRoom room;

  @override
  String? get userID => '@nudge-integration-user:test';

  @override
  Room? getRoomById(String roomId) => roomId == room.id ? room : null;
}

final class _NudgeRoom extends Room {
  _NudgeRoom(Client client)
      : super(id: '!nudge-integration:test', client: client);

  final sent = <({String type, Map<String, dynamic> content})>[];

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
      _NudgeTimeline(this);

  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
  }) async {
    sent.add((type: type, content: content));
    return r'$nudge-event';
  }
}

final class _NudgeTimeline extends Fake implements Timeline {
  _NudgeTimeline(Room room)
      : events = [
          Event(
            room: room,
            eventId: r'$first',
            senderId: '@first-target:test',
            type: EventTypes.Message,
            originServerTs: DateTime.utc(2026, 9, 13),
            content: const {'msgtype': 'm.text', 'body': 'first target'},
          ),
          Event(
            room: room,
            eventId: r'$second',
            senderId: '@second-target:test',
            type: EventTypes.Message,
            originServerTs: DateTime.utc(2026, 9, 13, 0, 1),
            content: const {'msgtype': 'm.text', 'body': 'second target'},
          ),
        ];

  @override
  final List<Event> events;

  @override
  bool get canRequestHistory => false;

  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {}

  @override
  void cancelSubscriptions() {}
}

ProfileData _profile() => const ProfileData(
      username: 'nudge-user',
      nickname: 'Nudge user',
      maskedEmail: '',
      fallbackSeed: 'nudge-user',
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
          '{"username":"nudge-user","nickname":"Nudge user",'
          '"masked_email":"","avatar_fallback_seed":"nudge-user"}',
          200,
        );
      }
      return http.Response('{}', 404);
    }),
  );
}

Future<MatrixRoomLease> _lease(_NudgeClient client) =>
    MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://matrix.test'))
        .openRoomLease(client.room.id);

ProfileRepository _identityCache() => ProfileRepository.forTesting(
      accountKey: 'matrix:@nudge-integration-user:test',
      store: MemoryProfileStore(),
      loadProfile: () async => _profile(),
      loadContacts: () async => const [],
    );

Future<void> _pumpRoom(WidgetTester tester, _NudgeClient client) async {
  final identities = _identityCache();
  await identities.preload();
  await tester.pumpWidget(CupertinoApp(
    home: RoomPage(
      api: await _api(),
      roomLease: await _lease(client),
      roomName: 'Nudge room',
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

Future<void> _nudgeFromBubble(WidgetTester tester, Finder target) async {
  tester.widget<WeChatMessageBubble>(target).onAvatarDoubleTap!();
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
      'RoomPage blocks a fourth nudge to another target and remains limited after reentry',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final firstClient = _NudgeClient();
    await _pumpRoom(tester, firstClient);
    expect(
        (tester.state(find.byType(RoomPage)) as dynamic).ownProfile, isNotNull);

    final bubbles = find.byType(WeChatMessageBubble);
    expect(bubbles, findsNWidgets(2));
    for (var index = 0; index < 3; index++) {
      await _nudgeFromBubble(tester, bubbles.first);
    }
    expect(firstClient.room.sent, hasLength(3));
    expect(
        firstClient.room.sent.every((event) =>
            event.type == 'com.changliao.nudge' &&
            event.content['target_user_id'] == '@first-target:test'),
        isTrue);

    await _nudgeFromBubble(tester, bubbles.last);
    await tester.pump();
    expect(firstClient.room.sent, hasLength(3));
    expect(find.byKey(const Key('room-nudge-toast')), findsOneWidget);
    expect(find.text('拍一拍太频繁，请稍后再试'), findsOneWidget);

    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(tester.takeException(), isNull);

    final reenteredClient = _NudgeClient();
    await _pumpRoom(tester, reenteredClient);
    await _nudgeFromBubble(tester, find.byType(WeChatMessageBubble).last);
    await tester.pump();
    expect(reenteredClient.room.sent, isEmpty);
    expect(find.byKey(const Key('room-nudge-toast')), findsOneWidget);

    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'a page disposed with pending room work must not throw');
  });
}
