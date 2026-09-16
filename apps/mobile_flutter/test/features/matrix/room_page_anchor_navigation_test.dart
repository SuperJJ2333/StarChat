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
import 'package:liuhetong_mobile/ui/chat/message_highlight_pulse.dart';
import 'profile_repository_test.dart' show MemoryProfileStore;

/// Task B：全局搜索 / 深链的房间导航 anchor 契约。
///
/// `RoomOpenRequest.anchorEventId → RoomPage.initialAnchorEventId`，进入房间后
/// 定位并高亮该消息；没有 anchor 时不得高亮任何消息。
final class _AnchorClient extends Client {
  _AnchorClient() : super('room-anchor-test') {
    room = _AnchorRoom(this);
  }

  late final _AnchorRoom room;

  @override
  String? get userID => '@anchor-user:test';

  @override
  Room? getRoomById(String roomId) => roomId == room.id ? room : null;
}

final class _AnchorRoom extends Room {
  _AnchorRoom(Client client) : super(id: '!anchor:test', client: client);

  @override
  bool get isDirectChat => false;

  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
  }) async =>
      _AnchorTimeline(this);
}

final class _AnchorTimeline extends Fake implements Timeline {
  _AnchorTimeline(Room room)
      : events = [
          for (var index = 1; index <= 3; index++)
            Event(
              room: room,
              eventId: r'$m' '$index',
              senderId: '@peer:test',
              type: EventTypes.Message,
              originServerTs: DateTime.utc(2026, 9, 10 + index),
              content: {'msgtype': 'm.text', 'body': '消息$index'},
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

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

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
          '{"username":"anchor-user","nickname":"Anchor user",'
          '"masked_email":"","avatar_fallback_seed":"anchor-user"}',
          200,
        );
      }
      return http.Response('{}', 404);
    }),
  );
}

Future<void> _pumpRoom(WidgetTester tester, String? anchorEventId) async {
  final client = _AnchorClient();
  final identities = ProfileRepository.forTesting(
    accountKey: 'matrix:@anchor-user:test',
    store: MemoryProfileStore(),
    loadProfile: () async => const ProfileData(
      username: 'anchor-user',
      nickname: 'Anchor user',
      maskedEmail: '',
      fallbackSeed: 'anchor-user',
    ),
    loadContacts: () async => const [],
  );
  await identities.preload();
  final lease = await MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://matrix.test'))
      .openRoomLease(client.room.id);
  await tester.pumpWidget(CupertinoApp(
    home: RoomPage(
      api: await _api(),
      roomLease: lease,
      roomName: 'Anchor room',
      initialIdentityCache: identities,
      initialAnchorEventId: anchorEventId,
      onCreateGroup: () {},
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

MessageHighlightPulse? _pulseFor(WidgetTester tester, String eventId) {
  final row = find.byKey(ValueKey(eventId));
  if (row.evaluate().isEmpty) return null;
  final pulse = find.descendant(
      of: row, matching: find.byType(MessageHighlightPulse));
  if (pulse.evaluate().isEmpty) return null;
  return tester.widget<MessageHighlightPulse>(pulse.first);
}

/// 1.5s 高亮脉冲结束后卸载组件树，避免测试结束时残留计时器。
Future<void> _disposeRoom(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1600));
  await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
  await tester.pump();
}

void main() {
  testWidgets('打开房间时 anchor 消息被定位并高亮（其他消息不高亮）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpRoom(tester, r'$m2');

    expect(_pulseFor(tester, r'$m2')?.active, isTrue,
        reason: 'anchor 消息必须高亮');
    expect(_pulseFor(tester, r'$m1')?.active, isFalse);
    expect(_pulseFor(tester, r'$m3')?.active, isFalse);
    expect(tester.takeException(), isNull);
    await _disposeRoom(tester);
  });

  testWidgets('没有 anchor 时不高亮任何消息', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpRoom(tester, null);

    for (final id in [r'$m1', r'$m2', r'$m3']) {
      expect(_pulseFor(tester, id)?.active ?? false, isFalse);
    }
    expect(tester.takeException(), isNull);
    await _disposeRoom(tester);
  });

  testWidgets('anchor 指向不存在的消息时不崩溃、不高亮', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpRoom(tester, r'$missing');

    for (final id in [r'$m1', r'$m2', r'$m3']) {
      expect(_pulseFor(tester, id)?.active ?? false, isFalse);
    }
    expect(tester.takeException(), isNull);
    await _disposeRoom(tester);
  });
}
