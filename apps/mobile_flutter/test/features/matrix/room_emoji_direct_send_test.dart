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
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/mention_composer_model.dart';
import 'package:liuhetong_mobile/ui/chat/chat_emoji_panel.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_emoji_catalog.dart';
import 'profile_repository_test.dart' show MemoryProfileStore;

final class _NudgeClient extends Client {
  static int serial = 0;
  _NudgeClient() : super('room-page-emoji-${++serial}') {
    room = _NudgeRoom(this);
  }

  late final _NudgeRoom room;

  @override
  String? get userID => '@emoji-user-$serial:test';

  @override
  Room? getRoomById(String roomId) => roomId == room.id ? room : null;
}

final class _NudgeRoom extends Room {
  _NudgeRoom(Client client)
      : super(
            id: '!emoji-integration-${_NudgeClient.serial}:test',
            client: client);

  final sent = <({String type, Map<String, dynamic> content})>[];
  final transactions = <String?>[];
  bool failNext = false;

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
    transactions.add(txid);
    if (failNext) {
      failNext = false;
      throw StateError('simulated send failure');
    }
    sent.add((type: type, content: content));
    return '\$emoji-event-${transactions.length}';
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
        ].reversed.toList();

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
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if ((tester.state(find.byType(RoomPage)) as dynamic).controller != null) {
      return;
    }
  }
  fail('RoomPage did not become ready');
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
  testWidgets(
      'dynamic selection sends separately and preserves draft selection and reply',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = _NudgeClient();
    await _pumpRoom(tester, client);
    final state = tester.state(find.byType(RoomPage)) as dynamic;
    final input = state.input as TextEditingController;
    input.value = const TextEditingValue(
        text: 'unfinished @someone',
        selection: TextSelection(baseOffset: 2, extentOffset: 7));
    final mention = state.mentionComposer as MentionComposerModel;
    mention.triggerAt(11);
    mention.replaceTrigger(displayName: 'someone', userId: '@someone:test');
    final mentionsBefore = mention.recipientUserIds();
    expect(mentionsBefore, ['@someone:test']);
    final before = input.value;
    state.replyingTo = state.controller.messages.first;
    final reply = state.replyingTo;
    await tester.tap(find.byKey(const Key('composer-emoji')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('emoji-tab-super')));
    await tester.pump();
    expect(find.byType(ChatEmojiPanel), findsOneWidget);
    await tester
        .tap(find.byKey(Key('fluent-emoji-${fluentEmojis.first.name}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(client.room.sent, hasLength(1));
    expect(client.room.sent.single.content['body'], fluentEmojis.first.char);
    expect(client.room.sent.single.content['m.relates_to'], isNull);
    expect(client.room.sent.single.content['m.mentions'], isNull);
    expect(input.value, before);
    expect(mention.recipientUserIds(), mentionsBefore);
    expect(identical(state.replyingTo, reply), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  testWidgets(
      'repeated dynamic taps send separate messages and static tab edits draft',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = _NudgeClient();
    await _pumpRoom(tester, client);
    final state = tester.state(find.byType(RoomPage)) as dynamic;
    final input = state.input as TextEditingController;
    input.value = const TextEditingValue(
        text: 'draft', selection: TextSelection.collapsed(offset: 5));
    await tester.tap(find.byKey(const Key('composer-emoji')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('emoji-tab-super')));
    await tester.pump();
    final dynamicButton =
        find.byKey(Key('fluent-emoji-${fluentEmojis.first.name}'));
    await tester.tap(dynamicButton);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(dynamicButton);
    await tester.pump(const Duration(milliseconds: 100));
    expect(client.room.sent.map((event) => event.content['body']),
        [fluentEmojis.first.char, fluentEmojis.first.char]);
    expect(client.room.transactions.toSet(), hasLength(2));
    expect(input.text, 'draft');
    await tester.tap(find.byKey(const Key('emoji-tab-smiley')));
    await tester.pumpAndSettle();
    final panel = tester.widget<ChatEmojiPanel>(find.byType(ChatEmojiPanel));
    panel.onEmojiSelected('😂');
    await tester.pump();
    expect(input.text, 'draft😂');
    expect(client.room.sent, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'dynamic transport failure retains retryable local echo and untouched draft',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = _NudgeClient()..room.failNext = true;
    await _pumpRoom(tester, client);
    final state = tester.state(find.byType(RoomPage)) as dynamic;
    final input = state.input as TextEditingController;
    input.text = 'unfinished';
    await tester.tap(find.byKey(const Key('composer-emoji')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('emoji-tab-super')));
    await tester.pump();
    await tester
        .tap(find.byKey(Key('fluent-emoji-${fluentEmojis.first.name}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final timeline = state.controller as RoomTimelineController;
    final local = timeline.messages.last;
    expect(local.text, fluentEmojis.first.char);
    expect(local.deliveryState, RoomDeliveryState.failed);
    expect(input.text, 'unfinished');
    expect(client.room.sent, isEmpty);
    await timeline.retry(local.id);
    await tester.pump();
    expect(client.room.sent.single.content['body'], fluentEmojis.first.char);
    expect(client.room.transactions.toSet(), hasLength(1));
    expect(input.text, 'unfinished');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  testWidgets(
      'retained dynamic callback still obeys current room send permission',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = _NudgeClient();
    await _pumpRoom(tester, client);
    final state = tester.state(find.byType(RoomPage)) as dynamic;
    final input = state.input as TextEditingController;
    input.text = 'protected draft';
    await tester.tap(find.byKey(const Key('composer-emoji')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('emoji-tab-super')));
    await tester.pump();
    final select = tester
        .widget<ChatEmojiPanel>(find.byType(ChatEmojiPanel))
        .onDynamicEmojiSelected;
    final page = tester.widget<RoomPage>(find.byType(RoomPage));
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
      api: page.api,
      roomLease: page.roomLease,
      roomName: page.roomName,
      initialIdentityCache: page.initialIdentityCache,
      onCreateGroup: page.onCreateGroup,
      readOnly: true,
    )));
    await tester.pump();
    select(fluentEmojis.first.char);
    await tester.pump(const Duration(milliseconds: 100));
    expect(client.room.sent, isEmpty);
    expect(
        (state.controller as RoomTimelineController)
            .messages
            .last
            .deliveryState,
        RoomDeliveryState.failed);
    expect(input.text, 'protected draft');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
