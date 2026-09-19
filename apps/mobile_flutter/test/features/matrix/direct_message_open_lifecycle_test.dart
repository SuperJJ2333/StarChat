import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/matrix/pending_conversation_page.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 好友资料「发消息」的**打开生命周期边界**回归。
///
/// 真机复现：通讯录 → 好友 A → 好友资料 → 发消息（Room A）→ 再进入好友资料
/// → 再点「发消息」**完全没反应**。根因是 `DirectMessageOpenGate` 的锁定范围
/// 覆盖了整个 `Navigator.push(RoomPage)` 生命周期（`await push` 只在页面关闭
/// 后才完成），于是 Room A 打开期间同一好友的第二次请求被闸门吞掉，根本到不了
/// `RoomNavigationCoordinator` 的 popUntil。
///
/// 这里穿过真实生产链路（只有 Matrix/Business 传输被替换为不触网的替身）：
///   ContactProfilePage / ContactsTabPage 的 onMessage（AppHome._openMessage）
///   → DirectMessageOpenGate → resolveFriendContact
///   → DirectChatController + CoordinatedDirectChatGateway
///   → RoomNavigationCoordinator → RoomPage + MatrixRoomLease
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PersistentOutboxManager.shared = PersistentOutboxManager(
        InMemoryOutboxStore(),
        accountId: _selfMatrixId);
  });
  tearDown(() {
    PersistentOutboxManager.shared?.dispose();
    PersistentOutboxManager.shared = null;
  });

  testWidgets('Test 1: 好友资料首次「发消息」只解析一次身份/房间，只开一个 RoomPage+租约', (tester) async {
    final harness = await _Harness.start(tester);
    addTearDown(harness.dispose);

    final leasesBefore = harness.managedResources;
    await harness.tapFriendProfileSend(tester);
    await tester.pumpAndSettle();

    expect(harness.lookedUpMatrixUserIds, [_peerMatrixId],
        reason: '身份解析用目录里的权威 Matrix ID，且只解析一次房间');
    expect(harness.canonicalRoomLookups, 1, reason: 'canonical 私聊房间只解析一次');
    expect(harness.matrixHttpRequests, 0, reason: '本地既有加密私聊足够打开，全程不得触网');
    expect(find.byType(RoomPage), findsOneWidget);
    expect(harness.managedResources - leasesBefore, 1,
        reason: '只取一份 RoomLease');
    expect(harness.roomLeaseOf(tester).roomId, _roomId);
  });

  testWidgets('Test 2: Room A 内再次「发消息」不再被闸门吞掉，popUntil 回到原 Room A',
      (tester) async {
    final harness = await _Harness.start(tester);
    addTearDown(harness.dispose);

    // 第一次：通讯录 → 好友 → 好友资料 → 发消息
    await harness.tapFriendProfileSend(tester);
    await tester.pumpAndSettle();
    expect(find.byType(RoomPage), findsOneWidget);
    final leaseAfterFirstOpen = harness.roomLeaseOf(tester);
    final resourcesAfterFirstOpen = harness.managedResources;

    // Room A 已 active；从这里再进入「好友资料」并点「发消息」。
    await harness.pressSendFromFriendProfileStub(tester);
    await tester.pumpAndSettle();

    expect(harness.lastSendCompleted, isTrue,
        reason: '第二次请求必须真的走完（single-flight 复用，而不是被静默丢弃）');
    expect(harness.canonicalRoomLookups, 2,
        reason: '第二次请求必须到达 RoomNavigationCoordinator（闸门已释放）');
    expect(harness.profileStubVisible, isFalse,
        reason: 'RoomNavigationCoordinator 应 popUntil 回到原 Room A');
    expect(find.byType(RoomPage), findsOneWidget, reason: '不得 push 第二个 Room A');
    expect(identical(harness.roomLeaseOf(tester), leaseAfterFirstOpen), isTrue,
        reason: '不得创建第二份 RoomLease');
    expect(harness.managedResources, resourcesAfterFirstOpen,
        reason: '租约登记数量保持不变');
  });

  testWidgets('Test 3: Room A 仍打开时闸门已释放（释放点在 canonical 房间获取完成，而非页面关闭）',
      (tester) async {
    final harness = await _Harness.start(tester);
    addTearDown(harness.dispose);

    await harness.tapFriendProfileSend(tester);
    await tester.pumpAndSettle();
    expect(find.byType(RoomPage), findsOneWidget);
    expect(harness.canonicalRoomLookups, 1);

    // Room A 还没有关闭：新的一次「发消息」必须重新进入身份 + canonical 解析，
    // 而不是被当成「好友 A 仍在 opening」。
    await harness.pressSendFromFriendProfileStub(tester);
    await tester.pumpAndSettle();

    expect(harness.canonicalRoomLookups, 2,
        reason: 'canonical 房间获取完成后闸门即释放，页面开着也必须能再次进入');
    expect(find.byType(RoomPage), findsOneWidget, reason: '已打开的房间只回到原页面');
  });

  testWidgets('Test 4: 慢身份解析时并发两次「发消息」：解析与房间查找各一次，只开一个页面', (tester) async {
    final harness = await _Harness.start(tester, peerInCache: false);
    addTearDown(harness.dispose);
    await harness.openContactsTab(tester);
    final leasesBefore = harness.managedResources;
    // 只统计并发窗口内的身份解析次数（排除启动/进入通讯录时的既有刷新）。
    harness.contactsLoads = 0;

    // 人为让 resolveFriendContact 的目录刷新挂住。
    harness.holdNextContactsLoad();
    harness.contactsForNextLoad = const [_friendSummary];
    final onMessage = harness.contactsOnMessage(tester);
    harness.recordSend(onMessage(_friendDetails));
    harness.recordSend(onMessage(_friendDetails));
    await tester.pump();

    expect(harness.contactsLoads, 1,
        reason: '并发两次点击只触发 1 次身份解析（第二次复用同一个 flight）');
    expect(harness.canonicalRoomLookups, 0, reason: '身份未解析出结果前不得解析房间');

    harness.completeContactsLoad();
    await tester.pumpAndSettle();

    expect(harness.canonicalRoomLookups, 1, reason: 'canonical 私聊房间查找只执行一次');
    expect(find.byType(RoomPage), findsOneWidget);
    expect(harness.managedResources - leasesBefore, 1,
        reason: '只取一份 RoomLease');

    // single-flight：两个调用都拿到同一个 target 并交给协调器；Room A 关闭后
    // 两个 future 都必须完成。
    harness.closeRoomA(tester);
    await tester.pumpAndSettle();
    expect(harness.allSendsCompleted, isTrue,
        reason: '复用的 future 必须把结果交给两个调用方，不能吞掉第二次请求');
  });

  testWidgets('Test 5: directChats.open 失败不阻塞进入（pending），重试后进入房间',
      (tester) async {
    final harness = await _Harness.start(tester, directChatMetadata: false);
    addTearDown(harness.dispose);

    await harness.tapFriendProfileSend(tester);
    await tester.pump();

    // Offline First：本地没有会话时立即进入 pending conversation，不弹旧口径弹窗、
    // 也不等待网络仲裁完成。
    expect(find.byType(PendingConversationPage), findsOneWidget,
        reason: '本地没有会话也必须可以进入会话页面');
    expect(find.text('无法打开加密会话'), findsNothing, reason: '产品要求禁止旧口径标题');
    expect(find.byType(RoomPage), findsNothing);

    await tester.pumpAndSettle();
    expect(harness.businessHttpRequests, greaterThan(0),
        reason: '后台仲裁仍会查询业务侧 canonical 房间');
    expect(find.text('重试'), findsOneWidget, reason: '后台建立失败必须在页面内可见并可重试');

    // 恢复业务 canonical 与本地私聊元数据后重试：闸门不得残留 opening。
    harness.publishDirectChatMetadata();
    final lookupsBeforeRetry = harness.businessCanonicalLookups;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.byType(RoomPage), findsOneWidget);
    expect(find.byType(PendingConversationPage), findsNothing);
    expect(harness.businessCanonicalLookups, greaterThan(lookupsBeforeRetry),
        reason: '重试必须重新解析身份 + canonical 房间');
  });

  testWidgets('同一好友并发打开在 canonical 未响应时只保留一个 pending 页面', (tester) async {
    final harness = await _Harness.start(tester, directChatMetadata: false);
    addTearDown(harness.dispose);
    await harness.openContactsTab(tester);
    harness._counters.canonicalGate = Completer<http.Response>();
    final onMessage = harness.contactsOnMessage(tester);
    harness.recordSend(onMessage(_friendDetails));
    harness.recordSend(onMessage(_friendDetails));
    await tester.pumpAndSettle();
    expect(find.byType(PendingConversationPage, skipOffstage: false),
        findsOneWidget);
    expect(find.byType(RoomPage, skipOffstage: false), findsNothing);
    // A later entry while the pending page remains open also reuses it.
    harness.recordSend(onMessage(_friendDetails));
    await tester.pumpAndSettle();
    expect(find.byType(PendingConversationPage, skipOffstage: false),
        findsOneWidget);
    harness._counters.canonicalGate!
        .complete(http.Response('{"detail":"unavailable"}', 503));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(PendingConversationPage))).pop();
    await tester.pumpAndSettle();
    expect(harness.allSendsCompleted, isTrue);
    expect(find.byType(PendingConversationPage, skipOffstage: false),
        findsNothing);
  });

  testWidgets('Test 6: Room A 内第二次「发消息」仍用目录里的权威 Matrix ID（过期快照不回归）',
      (tester) async {
    final harness = await _Harness.start(tester);
    addTearDown(harness.dispose);

    await harness.tapFriendProfileSend(tester);
    await tester.pumpAndSettle();
    expect(find.byType(RoomPage), findsOneWidget);

    // 入口快照带着改绑前的旧 Matrix ID（朋友圈/群成员/通知入口的现实形态）。
    await harness.pressSendFromFriendProfileStub(tester,
        contact: const ContactDetails(
          userId: 'bob',
          username: 'bob',
          matrixUserId: '@bob:old',
          nickname: '旧快照',
        ));
    await tester.pumpAndSettle();

    expect(harness.lookedUpMatrixUserIds.last, _peerMatrixId,
        reason: '必须用权威 ContactDetails 的 matrixUserId 打开 canonical 私聊');
    expect(harness.lookedUpMatrixUserIds, isNot(contains('@bob:old')));
    expect(harness.profileStubVisible, isFalse,
        reason: '第二次请求必须到达协调器并回到原 Room A');
    expect(find.byType(RoomPage), findsOneWidget);
  });
}

const _selfMatrixId = '@self:test';
const _peerMatrixId = '@bob:test';
const _roomId = '!dm-a:test';

const _selfProfile = ProfileData(
    username: 'self', nickname: 'self', maskedEmail: '', fallbackSeed: 'self');

const _friendSummary = ContactSummary(
  userId: 'bob',
  username: 'bob',
  matrixUserId: _peerMatrixId,
  nickname: 'Bob',
  remark: '产品小艾',
);

const _friendDetails = ContactDetails(
  userId: 'bob',
  username: 'bob',
  matrixUserId: _peerMatrixId,
  nickname: 'Bob',
  remark: '产品小艾',
);

/// 真实 SDK [Client]，只统计 canonical 私聊查找；任何 Matrix HTTP 都是缺陷。
final class _CountingClient extends Client {
  _CountingClient(super.clientName, {required super.httpClient});

  /// 每次 canonical 私聊解析所用的 Matrix ID（顺序即调用顺序）。
  final lookedUpMatrixUserIds = <String>[];

  int get canonicalRoomLookups => lookedUpMatrixUserIds.length;

  @override
  String? getDirectChatFromUserId(String userId) {
    lookedUpMatrixUserIds.add(userId);
    return super.getDirectChatFromUserId(userId);
  }
}

/// 房间成员/加密/m.direct 用真实 SDK 状态；时间线用空实现（本用例不渲染消息）。
final class _DirectRoom extends Room {
  _DirectRoom(Client client, {required super.id})
      : super(
          client: client,
          membership: Membership.join,
          summary: RoomSummary.fromJson({
            'm.joined_member_count': 2,
            'm.invited_member_count': 0,
          }),
        ) {
    partial = false;
  }

  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      _EmptyTimeline();
}

final class _EmptyTimeline extends Fake implements Timeline {
  @override
  List<Event> get events => const [];
  @override
  bool get canRequestHistory => false;
  @override
  void cancelSubscriptions() {}
  @override
  Future<Event?> getEventById(String eventId) async => null;
}

/// 「Room A → 好友资料」页替身：只保留与真实资料页同一个统一「发消息」入口。
final class _FriendProfileStub extends StatelessWidget {
  const _FriendProfileStub({
    required this.onMessage,
    required this.contact,
    required this.onSend,
  });

  final ContactAction onMessage;
  final ContactDetails contact;
  final void Function(Future<void> future) onSend;

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(middle: Text('好友资料')),
        child: Center(
          child: CupertinoButton(
            key: const Key('stub-friend-message'),
            onPressed: () => onSend(onMessage(contact)),
            child: const Text('发消息'),
          ),
        ),
      );
}

final class _Counters {
  int matrixHttp = 0;
  int businessHttp = 0;
  int businessCanonicalLookups = 0;
  bool canonicalAvailable = false;
  Completer<http.Response>? canonicalGate;
}

final class _MemoryStore implements SecureKeyValueStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

final class _ProfileStore implements ProfileStore {
  @override
  Future<ProfileSnapshot?> read(String accountKey) async => null;
  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {}
}

final class _ThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}

final class _Send {
  bool completed = false;
}

/// AppHome 全链路测试台：真实 AppHome + 真实 RoomNavigationCoordinator +
/// 真实 DirectChatController/CoordinatedDirectChatGateway，只替换传输与缓存。
final class _Harness {
  _Harness._(this._counters, this.client, this.matrix, this.api, this.cache);

  static Future<_Harness> start(
    WidgetTester tester, {
    bool peerInCache = true,
    bool directChatMetadata = true,
  }) async {
    final counters = _Counters();
    final client = _CountingClient(
      'direct-message-open-lifecycle',
      httpClient: MockClient((_) async {
        counters.matrixHttp++;
        throw StateError('本用例不得触发 Matrix HTTP');
      }),
    )..setUserId(_selfMatrixId);
    final room = _DirectRoom(client, id: _roomId);
    client.rooms.add(room);
    _setMember(room, _selfMatrixId, 'join');
    _setMember(room, _peerMatrixId, 'join');
    _setEncryption(room);
    if (directChatMetadata) _publishDirectChatMetadata(client);

    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.test'));

    final session = SecureSessionStore(_MemoryStore());
    await session.saveSession(
        accessToken: 'test-access', refreshToken: 'test-refresh');
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: session,
      client: MockClient((request) async {
        counters.businessHttp++;
        if (request.url.path.endsWith('/direct-conversations') &&
            request.method == 'GET') {
          counters.businessCanonicalLookups++;
          if (counters.canonicalGate != null) {
            return counters.canonicalGate!.future;
          }
          if (counters.canonicalAvailable) {
            return http.Response('{"matrix_room_id":"$_roomId"}', 200);
          }
        }
        if (request.url.path.contains('direct-conversations')) {
          return http.Response('{"detail":"unavailable"}', 503);
        }
        return http.Response('{"items":[]}', 200);
      }),
    );

    late final _Harness harness;
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:$_selfMatrixId',
      store: _ProfileStore(),
      loadProfile: () async => _selfProfile,
      loadContacts: () => harness.loadContacts(),
    );
    harness = _Harness._(counters, client, matrix, api, cache);
    harness.contactsForNextLoad =
        peerInCache ? const [_friendSummary] : const <ContactSummary>[];

    await cache.preload();
    await tester.pumpWidget(CupertinoApp(
      home: AppHome(
        api: api,
        matrix: matrix,
        onLogout: () async {},
        themeController: ThemeController(store: _ThemeStore()),
        profileRepositoryFactory: (_, __) async => cache,
      ),
    ));
    await tester.pump();
    await tester.pump();
    return harness;
  }

  final _Counters _counters;
  final _CountingClient client;
  final MatrixSdkE2eeClient matrix;
  final BusinessApiClient api;
  final ProfileRepository cache;

  int contactsLoads = 0;
  List<ContactSummary> contactsForNextLoad = const [];
  Completer<List<ContactSummary>>? _heldContactsLoad;
  final List<_Send> _sends = [];
  ContactAction? _contactsOnMessage;

  int get matrixHttpRequests => _counters.matrixHttp;
  int get businessHttpRequests => _counters.businessHttp;
  int get businessCanonicalLookups => _counters.businessCanonicalLookups;
  int get canonicalRoomLookups => client.canonicalRoomLookups;
  List<String> get lookedUpMatrixUserIds => client.lookedUpMatrixUserIds;
  int get managedResources => matrix.debugManagedResourceCount;

  bool get lastSendCompleted => _sends.isEmpty || _sends.last.completed;
  bool get allSendsCompleted => _sends.every((send) => send.completed);
  bool get profileStubVisible =>
      find.byType(_FriendProfileStub).evaluate().isNotEmpty;

  Future<List<ContactSummary>> loadContacts() async {
    contactsLoads++;
    final held = _heldContactsLoad;
    // 挂住期间每一次目录刷新都计入 contactsLoads：这是「身份解析执行了几次」的
    // 可观测口径（并发窗口内必须只有 1 次）。
    if (held != null) return held.future;
    return contactsForNextLoad;
  }

  void holdNextContactsLoad() =>
      _heldContactsLoad = Completer<List<ContactSummary>>();

  void completeContactsLoad() {
    final held = _heldContactsLoad;
    _heldContactsLoad = null;
    held?.complete(contactsForNextLoad);
  }

  void publishDirectChatMetadata() {
    _counters.canonicalAvailable = true;
    _publishDirectChatMetadata(client);
  }

  void recordSend(Future<void> future) {
    final send = _Send();
    _sends.add(send);
    unawaited(future.then((_) => send.completed = true,
        onError: (Object _) => send.completed = true));
  }

  MatrixRoomLease roomLeaseOf(WidgetTester tester) =>
      tester.widget<RoomPage>(find.byType(RoomPage)).roomLease;

  void closeRoomA(WidgetTester tester) {
    Navigator.of(tester.element(find.byType(RoomPage)), rootNavigator: true)
        .pop();
  }

  ContactAction contactsOnMessage(WidgetTester tester) =>
      tester.widget<ContactsTabPage>(find.byType(ContactsTabPage)).onMessage;

  Future<void> openContactsTab(WidgetTester tester) async {
    await tester.tap(find.text('通讯录'));
    await tester.pumpAndSettle();
    expect(find.byType(ContactsTabPage), findsOneWidget,
        reason: '身份缓存就绪后通讯录 Tab 必须可进入');
    _contactsOnMessage ??=
        tester.widget<ContactsTabPage>(find.byType(ContactsTabPage)).onMessage;
  }

  /// 真实 UI 路径：通讯录 → 好友 → 好友资料 → 发消息。
  Future<void> tapFriendProfileSend(WidgetTester tester) async {
    await openContactsTab(tester);
    await tester.tap(find.text('产品小艾'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('friend-action-message')), findsOneWidget);
    await tester.tap(find.byKey(const Key('friend-action-message')));
    await tester.pumpAndSettle();
  }

  /// Room A 内重新进入「好友资料」并点击「发消息」（Room A → 好友资料 → 发消息）。
  /// [contact] 可传入过期快照，用于验证权威 Matrix ID 不回归。
  Future<void> pressSendFromFriendProfileStub(WidgetTester tester,
      {ContactDetails contact = _friendDetails}) async {
    final roomPage = tester.widget<RoomPage>(find.byType(RoomPage));
    final onMessage = _contactsOnMessage!;
    expect(roomPage.onMessage, onMessage, reason: '房间内与资料页必须是同一个「发消息」统一入口');
    final navigator = Navigator.of(tester.element(find.byType(RoomPage)),
        rootNavigator: true);
    unawaited(navigator.push(CupertinoPageRoute<void>(
      builder: (_) => _FriendProfileStub(
        onMessage: onMessage,
        contact: contact,
        onSend: recordSend,
      ),
    )));
    await tester.pumpAndSettle();
    expect(profileStubVisible, isTrue, reason: '好友资料页必须压在 Room A 之上');
    await tester.tap(find.byKey(const Key('stub-friend-message')));
    await tester.pumpAndSettle();
  }

  void dispose() {
    cache.dispose();
  }
}

void _publishDirectChatMetadata(Client client) {
  client.accountData['m.direct'] = BasicEvent.fromJson({
    'type': 'm.direct',
    'content': <String, Object?>{
      _peerMatrixId: <String>[_roomId],
    },
  });
}

void _setMember(Room room, String userId, String membership) => _setState(
      room,
      EventTypes.RoomMember,
      <String, Object?>{'membership': membership},
      stateKey: userId,
      sender: userId,
    );

void _setEncryption(Room room) => _setState(
      room,
      EventTypes.Encryption,
      {'algorithm': Client.supportedGroupEncryptionAlgorithms.first},
    );

void _setState(Room room, String type, Map<String, Object?> content,
    {String stateKey = '', String sender = _selfMatrixId}) {
  room.setState(Event.fromMatrixEvent(
    MatrixEvent.fromJson({
      'type': type,
      'state_key': stateKey,
      'sender': sender,
      'event_id': '\$${type.hashCode}-$stateKey',
      'origin_server_ts': 1,
      'content': content,
    }),
    room,
  ));
}
