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
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_controller.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_page.dart';
import 'profile_repository_test.dart' show MemoryProfileStore;

final class _NudgeClient extends Client {
  _NudgeClient({this.account = '@nudge-integration-user:test', String? roomId})
      : super('room-page-nudge') {
    room = _NudgeRoom(this, roomId: roomId);
  }

  final String account;
  late final _NudgeRoom room;
  int stateReads = 0;
  Completer<List<MatrixEvent>>? stateGate;
  @override
  Future<List<MatrixEvent>> getRoomState(String roomId) {
    stateReads++;
    return stateGate?.future ?? Future.value([]);
  }

  @override
  String? get userID => account;

  @override
  Room? getRoomById(String roomId) => roomId == room.id ? room : null;
}

final class _NudgeRoom extends Room {
  static int serial = 0;
  _NudgeRoom(Client client, {String? roomId})
      : super(
            id: roomId ?? '!nudge-integration-${++serial}:test',
            client: client);

  String secondBody = '😊';
  void members(int level) {
    for (final id in ['@first-target:test', '@second-target:test']) {
      setState(Event(
          room: this,
          originServerTs: DateTime.utc(2026),
          eventId: 'member$id',
          senderId: id,
          stateKey: id,
          type: EventTypes.RoomMember,
          content: {'membership': 'join', 'displayname': id}));
    }
    setState(Event(
        room: this,
        originServerTs: DateTime.utc(2026),
        eventId: 'power',
        senderId: client.userID!,
        stateKey: '',
        type: EventTypes.RoomPowerLevels,
        content: {
          'users': {'@first-target:test': level, '@second-target:test': level}
        }));
    summary.mJoinedMemberCount = 2;
    summary.mInvitedMemberCount = 0;
  }

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
            content: {
              'msgtype': 'm.text',
              'body': (room as _NudgeRoom).secondBody
            },
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

Completer<http.Response>? contactsGate;
int contactReads = 0;
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
      if (request.url.path.endsWith('/friends')) {
        contactReads++;
        return contactsGate?.future ?? http.Response('{"items":[]}', 200);
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final role in [(100, '群主'), (50, '管理员')]) {
    testWidgets('animated emoji and normal message both show ${role.$2}',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = _NudgeClient()..room.members(role.$1);
      await _pumpRoom(tester, client);
      expect(find.text('first target'), findsOneWidget);
      expect(find.text(role.$2), findsNWidgets(2));
      await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    });
  }
  testWidgets(
      'group info opens using local members while contacts and room state are held',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    contactsGate = Completer<http.Response>();
    final client = _NudgeClient()..room.members(100);
    client.stateGate = Completer<List<MatrixEvent>>();
    await _pumpRoom(tester, client);
    await tester.tap(find.byKey(const Key('chat-details')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(GroupChatInfoPage), findsOneWidget);
    expect(find.text('聊天信息(2)'), findsWidgets);
    contactsGate!.complete(http.Response('{"items":[]}', 200));
    contactsGate = null;
    client.stateGate!.complete([]);
    await tester.pump();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
  });
  test(
      'cached members publish before held state refresh and sync does not rerequest state',
      () async {
    final client = _NudgeClient()..room.members(100);
    client.stateGate = Completer<List<MatrixEvent>>();
    final lease = await _lease(client);
    final controller =
        GroupChatInfoController(lease.openGroupChatInfoGateway());
    final sync = StreamController<void>.broadcast(sync: true);
    controller.bindMembershipChanges(sync.stream, roomId: lease.roomId);
    final loading = controller.load();
    expect(controller.state.snapshot?.members.length, 2);
    client.stateGate!.complete([]);
    await loading;
    final reads = client.stateReads;
    sync.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(client.stateReads, reads);
    controller.dispose();
    await sync.close();
  });
  test(
      'local sync removes departed members and immediately applies power changes without remote reads',
      () async {
    final client = _NudgeClient()..room.members(100);
    var transferReads = 0;
    final lease = await _lease(client);
    final controller = GroupChatInfoController(lease.openGroupChatInfoGateway(),
        loadOwnershipTransfers: () async {
      transferReads++;
      return [];
    });
    final sync = StreamController<void>.broadcast(sync: true);
    controller.bindMembershipChanges(sync.stream, roomId: lease.roomId);
    await controller.load();
    final reads = client.stateReads;
    client.room.members(0);
    client.room.setState(Event(
        room: client.room,
        originServerTs: DateTime.utc(2026),
        eventId: 'left',
        senderId: '@second-target:test',
        stateKey: '@second-target:test',
        type: EventTypes.RoomMember,
        content: {'membership': 'leave'}));
    for (var i = 0; i < 10; i++) {
      sync.add(null);
    }
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.snapshot!.members.map((m) => m.matrixUserId),
        ['@first-target:test']);
    expect(controller.state.snapshot!.ownerId, isEmpty);
    expect(controller.state.snapshot!.adminIds, isEmpty);
    expect(client.stateReads, reads);
    expect(transferReads, 1);
    controller.dispose();
    await sync.close();
  });
  test(
      'simultaneous loads share refresh and disposal ignores its late completion',
      () async {
    final client = _NudgeClient()..room.members(100);
    client.stateGate = Completer<List<MatrixEvent>>();
    final lease = await _lease(client);
    final controller =
        GroupChatInfoController(lease.openGroupChatInfoGateway());
    final first = controller.load();
    final second = controller.load();
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(client.stateReads, 1);
    controller.dispose();
    client.stateGate!.complete([]);
    await Future.wait([first, second]);
  });
  test(
      'same room identifier under another account never receives previous members or roles',
      () async {
    final first = _NudgeClient(account: '@a:test', roomId: '!same:test')
      ..room.members(100);
    final second = _NudgeClient(account: '@b:test', roomId: '!same:test');
    final firstLease = await _lease(first);
    final secondLease = await _lease(second);
    final a =
        firstLease.openGroupChatInfoGateway() as GroupChatInfoLocalGateway;
    final b =
        secondLease.openGroupChatInfoGateway() as GroupChatInfoLocalGateway;
    expect(a.readLocalSnapshot().currentUserId, '@a:test');
    expect(a.readLocalSnapshot().members, hasLength(2));
    expect(b.readLocalSnapshot().currentUserId, '@b:test');
    expect(b.readLocalSnapshot().members, isEmpty);
    expect(b.readLocalSnapshot().ownerId, isEmpty);
    firstLease.canceled = true;
    expect(a.readLocalSnapshot, throwsStateError);
  });
  test(
      'session key notification refreshes announcement preview without fetching room state',
      () async {
    final client = _NudgeClient()..room.members(100);
    final lease = await _lease(client);
    final controller =
        GroupChatInfoController(lease.openGroupChatInfoGateway());
    final sync = StreamController<void>.broadcast(sync: true);
    controller.bindMembershipChanges(sync.stream, roomId: lease.roomId);
    await controller.load();
    final reads = client.stateReads;
    client.room.setState(Event(
        room: client.room,
        originServerTs: DateTime.utc(2026),
        eventId: 'topic',
        senderId: '@first-target:test',
        stateKey: '',
        type: EventTypes.RoomTopic,
        content: {'topic': 'local recovered preview'}));
    client.room.onSessionKeyReceived.add('test-session');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.snapshot!.announcement, 'local recovered preview');
    expect(client.stateReads, reads);
    controller.dispose();
    await sync.close();
  });
  test(
      'late transfer status cannot roll back power updates received during initial load',
      () async {
    final client = _NudgeClient()..room.members(100);
    final transfer = Completer<List<Map<String, dynamic>>>();
    final lease = await _lease(client);
    final controller = GroupChatInfoController(lease.openGroupChatInfoGateway(),
        loadOwnershipTransfers: () => transfer.future);
    final sync = StreamController<void>.broadcast(sync: true);
    controller.bindMembershipChanges(sync.stream, roomId: lease.roomId);
    final loading = controller.load();
    await Future<void>.delayed(Duration.zero);
    client.room.members(0);
    sync.add(null);
    expect(controller.state.snapshot!.ownerId, isEmpty);
    transfer.complete([]);
    await loading;
    expect(controller.state.snapshot!.ownerId, isEmpty);
    controller.dispose();
    await sync.close();
  });
  test(
      'held initial load uses a neutral announcement hint and respects explicit clear over legacy topic',
      () async {
    final client = _NudgeClient()..room.members(100);
    client.stateGate = Completer<List<MatrixEvent>>();
    final lease = await _lease(client);
    final gateway = lease.openGroupChatInfoGateway();
    final local = gateway as GroupChatInfoLocalGateway;
    final controller = GroupChatInfoController(gateway);
    void state(String type, Map<String, dynamic> content) =>
        client.room.setState(Event(
            room: client.room,
            originServerTs: DateTime.utc(2026),
            eventId: 'state-$type',
            senderId: '@first-target:test',
            stateKey: '',
            type: type,
            content: content));
    state(EventTypes.RoomTopic, {'topic': 'legacy announcement'});
    final loading = controller.load();
    try {
      expect(controller.state.snapshot!.announcement, '点击查看公告');
      state('com.changliao.group.announcement', {'event_id': r'$document'});
      expect(local.readLocalSnapshot().announcement, '点击查看公告');
      state('com.changliao.group.announcement', {});
      expect(local.readLocalSnapshot().announcement, isEmpty,
          reason: 'Explicit clear suppresses the legacy topic');
    } finally {
      state('com.changliao.group.announcement', {});
      client.stateGate!.complete([]);
      await loading;
      controller.dispose();
    }
  });
}
