import 'dart:async';

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
import 'package:liuhetong_mobile/features/matrix/room_navigation_coordinator.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/chat/message_highlight_pulse.dart';
import 'profile_repository_test.dart' show MemoryProfileStore;

import 'package:liuhetong_mobile/features/search/global_search_index.dart';
import 'package:liuhetong_mobile/features/search/global_search_page.dart';

/// Task B：全局搜索 / 深链的房间导航 anchor 契约。
///
/// `RoomOpenRequest.anchorEventId → RoomPage.initialAnchorEventId`，进入房间后
/// 定位并高亮该消息；没有 anchor 时不得高亮任何消息。
final class _AnchorClient extends Client {
  _AnchorClient({String roomId = '!anchor:test'})
      : super('room-anchor-test-$roomId') {
    room = _AnchorRoom(this, roomId);
  }

  late final _AnchorRoom room;

  @override
  String? get userID => '@anchor-user:test';

  @override
  Room? getRoomById(String roomId) => roomId == room.id ? room : null;
}

final class _AnchorRoom extends Room {
  _AnchorRoom(Client client, String roomId) : super(id: roomId, client: client);
  Completer<void>? timelineGate;
  Completer<Timeline>? contextGate;
  Object? contextError;
  int liveMessageCount = 3;
  final timelines = <_AnchorTimeline>[];
  final contextRequests = <String>[];

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
  }) async {
    if (timelineGate != null) await timelineGate!.future;
    if (eventContextId != null) {
      contextRequests.add(eventContextId);
      if (contextError != null) throw contextError!;
      if (contextGate != null) return contextGate!.future;
    }
    final timeline = _AnchorTimeline(this,
        eventContextId: eventContextId, liveMessageCount: liveMessageCount);
    timelines.add(timeline);
    return timeline;
  }
}

final class _TrackedContextTimeline extends Timeline {
  _TrackedContextTimeline(Room room)
      : super(
            room: room,
            chunk: TimelineChunk(isFragment: true, events: [
              Event(
                room: room,
                eventId: r'$cold-old',
                senderId: '@synthetic:test',
                type: EventTypes.Message,
                originServerTs: DateTime.utc(2025, 9, 1),
                content: {
                  'msgtype': MessageTypes.Text,
                  'body': 'synthetic context'
                },
              )
            ]));
  int subscriptionCancels = 0;
  @override
  void cancelSubscriptions() {
    subscriptionCancels++;
    super.cancelSubscriptions();
  }
}

final class _AnchorTimeline extends Fake implements Timeline {
  _AnchorTimeline(Room room, {String? eventContextId, int liveMessageCount = 3})
      : events = [
          for (var index = 1;
              index <=
                  (eventContextId == null
                      ? liveMessageCount
                      : eventContextId == r'$cold-old'
                          ? 1
                          : 0);
              index++)
            Event(
              room: room,
              eventId: eventContextId ?? r'$m' '$index',
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
  bool get canRequestFuture => false;

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

void main() {
  for (final delayed in [false, true]) {
    testWidgets(
        'global search old hit opens exact bubble through initial notifier (delayed=$delayed)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = _AnchorClient(roomId: '!global-anchor-$delayed:test');
      client.room.liveMessageCount = 100;
      if (delayed) client.room.contextGate = Completer<Timeline>();
      final matrix = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://matrix.test'));
      final api = await _api();
      final identities = ProfileRepository.forTesting(
        accountKey: 'matrix:@anchor-user:test',
        store: MemoryProfileStore(),
        loadProfile: () async => const ProfileData(
            username: 'anchor-user',
            nickname: 'Anchor user',
            maskedEmail: '',
            fallbackSeed: 'anchor-user'),
        loadContacts: () async => const [],
      );
      await identities.preload();
      final index = GlobalSearchIndex()
        ..recordRoom(
            roomId: '!global-anchor-$delayed:test',
            roomName: 'Synthetic room',
            isGroup: true,
            messages: [
              GlobalSearchMessageRecord(
                  eventId: r'$cold-old',
                  senderId: '@peer:test',
                  senderName: 'Synthetic peer',
                  timestamp: DateTime.utc(2025, 9, 1),
                  body: 'needle old history'),
            ]);
      final navigator = GlobalKey<NavigatorState>();
      final notifiers = <ValueNotifier<RoomOpenRequest>>[];
      final leases = <MatrixRoomLease>[];
      await tester.pumpWidget(CupertinoApp(
          navigatorKey: navigator,
          home: GlobalSearchPage(
            api: api,
            index: index,
            contactsLoader: () async => [],
            roomsLoader: () async => [],
            debounce: Duration.zero,
            onOpenRoom: (room, {anchorEventId}) async {
              final request = RoomOpenRequest(
                  roomId: room.roomId,
                  roomName: room.displayName,
                  anchorEventId: anchorEventId,
                  source: RoomOpenSource.search);
              final navigation = ValueNotifier(request);
              notifiers.add(navigation);
              final lease = await matrix.openRoomLease(request.roomId);
              leases.add(lease);
              await navigator.currentState!.push(CupertinoPageRoute<void>(
                  builder: (_) => RoomPage(
                        api: api,
                        roomLease: lease,
                        roomName: request.roomName,
                        initialIdentityCache: identities,
                        initialAnchorEventId: request.anchorEventId,
                        initialAnchorRoomId: request.anchorRoomId,
                        navigationRequests: navigation,
                        onCreateGroup: () {},
                      )));
            },
          )));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField).first, 'needle');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
          Key('global-search-conversation-!global-anchor-$delayed:test')));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(notifiers.single.value.anchorEventId, r'$cold-old');
      expect(find.byType(RoomPage), findsOneWidget);
      expect(client.room.contextRequests, [r'$cold-old']);
      if (delayed) {
        expect(find.byKey(const ValueKey(r'$cold-old')), findsNothing);
        client.room.contextGate!.complete(_TrackedContextTimeline(client.room));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
      }
      final target = find.byKey(const ValueKey(r'$cold-old'));
      expect(target, findsOneWidget,
          reason:
              'global hit must open selected history instead of latest window');
      final pulse = find.descendant(
          of: target, matching: find.byType(MessageHighlightPulse));
      expect(tester.widget<MessageHighlightPulse>(pulse).active, isTrue);
      notifiers.single.value = RoomOpenRequest(
          roomId: '!global-anchor-$delayed:test',
          roomName: 'Synthetic room',
          anchorEventId: r'$m50',
          source: RoomOpenSource.search);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      final reopenedTarget = find.byKey(const ValueKey(r'$m50'));
      expect(reopenedTarget, findsOneWidget);
      expect(
          tester
              .widget<MessageHighlightPulse>(find.descendant(
                  of: reopenedTarget,
                  matching: find.byType(MessageHighlightPulse)))
              .active,
          isTrue);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
      await tester.pump();
      for (final lease in leases) {
        await lease.cancel();
      }
      identities.dispose();
      for (final navigation in notifiers) {
        navigation.dispose();
      }
    });
  }
}
