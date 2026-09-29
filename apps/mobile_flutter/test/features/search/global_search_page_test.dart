import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';
import 'package:liuhetong_mobile/features/matrix/duplicate_room_registry.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/features/search/global_search_avatar.dart';
import 'package:liuhetong_mobile/features/search/global_search_index.dart';
import 'package:liuhetong_mobile/features/search/global_search_models.dart';
import 'package:liuhetong_mobile/features/search/global_search_page.dart';
import 'package:liuhetong_mobile/features/search/local_message_search_repository.dart';
import 'package:liuhetong_mobile/ui/chat/group_avatar_mosaic.dart';
import 'package:liuhetong_mobile/ui/components/wechat_list_tile.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _SearchClient extends Client {
  _SearchClient(this.account) : super('global-search-$account');

  final String account;
  Room? primaryRoom;

  @override
  String get userID => '@$account:test';

  @override
  Room? getRoomById(String id) => primaryRoom?.id == id ? primaryRoom : null;
}

MatrixSdkE2eeClient _matrixOwner(String account,
        {DuplicateRoomRegistry? duplicateRooms, _SearchClient? client}) =>
    MatrixSdkE2eeClient(
      client ?? _SearchClient(account),
      homeserver: Uri.parse('https://matrix.test'),
      duplicateRooms: duplicateRooms,
    );

final class _UnavailableAvatarMedia implements AvatarMediaCapability {
  @override
  Future<ResolvedAvatarUrl?> resolveAvatar({
    required Uri? avatarUri,
    required double size,
  }) async =>
      null;
}

GlobalSearchMessageRecord _record(String id, String body,
        {String senderName = '张三', DateTime? at}) =>
    GlobalSearchMessageRecord(
      eventId: id,
      senderId: '@peer:test',
      senderName: senderName,
      timestamp: at ?? DateTime.utc(2026, 9, 15, 10),
      body: body,
    );

GlobalSearchIndex _index(List<GlobalSearchMessageRecord> records,
    {bool isGroup = true}) {
  final index = GlobalSearchIndex();
  index.recordRoom(
    roomId: isGroup ? '!group:test' : '!dm:test',
    roomName: isGroup ? '数智经济中心' : '张三',
    isGroup: isGroup,
    messages: records,
  );
  return index;
}

const _contacts = [
  ContactSummary(
      userId: 'u1',
      username: 'project-user',
      matrixUserId: '@project:test',
      nickname: '项目伙伴'),
];

const _rooms = [
  GlobalSearchRoomResult(
      roomId: '!group:test',
      displayName: '数智经济中心',
      isDirect: false,
      memberCount: 8),
  GlobalSearchRoomResult(
      roomId: '!dm:test', displayName: '张三（私聊）', isDirect: true),
];

final class _Nav {
  final opened = <({String roomId, String? anchorEventId})>[];
  Future<void> open(GlobalSearchRoomResult room,
      {String? anchorEventId}) async {
    opened.add((roomId: room.roomId, anchorEventId: anchorEventId));
  }
}

Future<BusinessApiClient> _api(
    {List<Uri>? requests,
    PerformanceTraceRecorder? performanceRecorder}) async {
  final store = SecureSessionStore(_MemoryStore());
  await store.saveSession(accessToken: 'a', refreshToken: 'r');
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.test'),
    sessionStore: store,
    performanceRecorder: performanceRecorder,
    client: MockClient((request) async {
      requests?.add(request.url);
      return http.Response('{"items":[]}', 200,
          headers: {'content-type': 'application/json'});
    }),
  );
}

Widget _page({
  required BusinessApiClient api,
  GlobalSearchIndex? index,
  LocalMessageSearchRepository? repository,
  _Nav? nav,
  List<GlobalSearchRoomResult> rooms = _rooms,
  Future<List<GlobalSearchRoomResult>> Function()? roomsLoader,
  List<ContactSummary> contacts = _contacts,
  MatrixSdkE2eeClient? matrix,
  Duration debounce = Duration.zero,
  Future<List<ContactSummary>> Function()? contactsLoader,
  bool loadContactsFromApi = false,
  PerformanceTrace? performanceTrace,
  PerformanceTrace? searchPerformanceTrace,
  AvatarMediaCapability? avatarMedia,
}) =>
    CupertinoApp(
      home: GlobalSearchPage(
        api: api,
        index: index,
        repository: repository,
        debounce: debounce,
        contactsLoader:
            loadContactsFromApi ? null : contactsLoader ?? () async => contacts,
        roomsLoader: roomsLoader ?? () async => rooms,
        matrix: matrix,
        performanceTrace: performanceTrace,
        searchPerformanceTrace: searchPerformanceTrace,
        avatarMedia: avatarMedia,
        onOpenRoom: nav == null
            ? (_, {anchorEventId}) async {}
            : (room, {anchorEventId}) =>
                nav.open(room, anchorEventId: anchorEventId),
      ),
    );

/// 账号维度的本机历史仓库（fake 本机加密库；零网络）。
LocalMessageSearchRepository _repository(
    {List<LocalSearchMessage> messages = const []}) {
  final repository = LocalMessageSearchRepository(
    source: InMemoryLocalHistorySource(messages),
    index: GlobalSearchIndex(),
  );
  return repository..attachAccount('@alice:test');
}

LocalSearchMessage _localMessage(String id, String body) => LocalSearchMessage(
      eventId: id,
      senderId: '@peer:test',
      senderName: '张三',
      timestamp: DateTime.utc(2026, 9, 15, 10),
      body: body,
      roomId: '!group:test',
      roomName: '数智经济中心',
      isGroup: true,
    );

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(CupertinoSearchTextField), query);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
}

void main() {
  testWidgets('old-account rows disappear while the new owner is loading',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = await _api();
    final firstIndex = GlobalSearchIndex()
      ..recordRoom(
        roomId: '!first:test',
        roomName: '项目旧群',
        isGroup: true,
        messages: [_record(r'$first', '项目旧记录')],
      );
    final nextIndex = GlobalSearchIndex();
    final firstOwner = _matrixOwner('first');
    final nextOwner = _matrixOwner('next');
    final nextRooms = Completer<List<GlobalSearchRoomResult>>();
    await tester.pumpWidget(_page(
      api: api,
      matrix: firstOwner,
      index: firstIndex,
      contacts: const [],
      rooms: const [
        GlobalSearchRoomResult(
          roomId: '!first:test',
          displayName: '项目旧群',
          isDirect: false,
        ),
      ],
    ));
    await _search(tester, '项目');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.byKey(const Key('global-search-room-!first:test')),
        findsOneWidget);
    expect(find.byKey(const Key('global-search-conversation-!first:test')),
        findsOneWidget);

    await tester.pumpWidget(_page(
      api: api,
      matrix: nextOwner,
      index: nextIndex,
      contacts: const [],
      roomsLoader: () => nextRooms.future,
    ));
    await tester.pump();
    expect(
        find.byKey(const Key('global-search-room-!first:test')), findsNothing);
    expect(find.byKey(const Key('global-search-conversation-!first:test')),
        findsNothing);
    expect(find.text('项目旧群'), findsNothing);

    nextRooms.complete(const [
      GlobalSearchRoomResult(
        roomId: '!next:test',
        displayName: '项目新群',
        isDirect: false,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(
        find.byKey(const Key('global-search-room-!next:test')), findsOneWidget);
    expect(find.byKey(const Key('global-search-conversation-!first:test')),
        findsNothing);
  });

  testWidgets('history waits for its repository to bind the new owner',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = await _api();
    final repository = _repository(messages: [
      _localMessage(r'$prior', '项目旧消息'),
    ]);
    await repository.backfillLocalHistory();
    await tester.pumpWidget(_page(
      api: api,
      matrix: _matrixOwner('alice'),
      repository: repository,
      contacts: const [],
      rooms: const [
        GlobalSearchRoomResult(
          roomId: '!group:test',
          displayName: '项目旧群',
          isDirect: false,
        ),
      ],
    ));
    await _search(tester, '项目');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.byKey(const Key('global-search-conversation-!group:test')),
        findsOneWidget);

    final nextOwner = _matrixOwner('next');
    await tester.pumpWidget(_page(
      api: api,
      matrix: nextOwner,
      repository: repository,
      contacts: const [],
      rooms: const [
        GlobalSearchRoomResult(
          roomId: '!next:test',
          displayName: '项目新群',
          isDirect: false,
        ),
      ],
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.byKey(const Key('global-search-conversation-!group:test')),
        findsNothing);

    repository.attachAccount('@next:test');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(
        find.byKey(const Key('global-search-room-!next:test')), findsOneWidget);
    expect(find.byKey(const Key('global-search-conversation-!group:test')),
        findsNothing);
  });

  testWidgets('initial repository mismatch resumes after account binding',
      (tester) async {
    final api = await _api();
    final repository = _repository();
    await tester.pumpWidget(_page(
      api: api,
      matrix: _matrixOwner('next'),
      repository: repository,
      contacts: const [],
      rooms: const [
        GlobalSearchRoomResult(
          roomId: '!next:test',
          displayName: '项目新群',
          isDirect: false,
        ),
      ],
    ));
    await _search(tester, '项目');
    expect(
        find.byKey(const Key('global-search-room-!next:test')), findsNothing);

    repository.attachAccount('@next:test');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(
        find.byKey(const Key('global-search-room-!next:test')), findsOneWidget);
  });

  testWidgets('older room load cannot replace a newer avatar snapshot',
      (tester) async {
    final api = await _api();
    final firstRooms = Completer<List<GlobalSearchRoomResult>>();
    final index = GlobalSearchIndex()
      ..recordRoom(
        roomId: '!history:test',
        roomName: '项目会话',
        isGroup: true,
        messages: [_record(r'$history', '项目新历史')],
      );
    var loads = 0;
    Future<List<GlobalSearchRoomResult>> loadRooms() {
      if (++loads == 1) return firstRooms.future;
      return Future.value([
        GlobalSearchRoomResult(
          roomId: '!history:test',
          displayName: '项目新会话',
          isDirect: false,
          matrixAvatarUri: Uri.parse('mxc://test/new-avatar'),
        ),
      ]);
    }

    await tester.pumpWidget(_page(
      api: api,
      index: index,
      contacts: const [],
      roomsLoader: loadRooms,
      avatarMedia: _UnavailableAvatarMedia(),
    ));
    await _search(tester, '项目');
    await _search(tester, '项目新');
    expect(loads, 2);
    final historyRow =
        find.byKey(const Key('global-search-conversation-!history:test'));
    expect(historyRow, findsOneWidget);

    firstRooms.complete([
      GlobalSearchRoomResult(
        roomId: '!history:test',
        displayName: '项目旧会话',
        isDirect: false,
        matrixAvatarUri: Uri.parse('mxc://test/old-avatar'),
      ),
    ]);
    await tester.pump();
    await tester.pumpWidget(_page(
      api: api,
      index: index,
      contacts: const [],
      roomsLoader: loadRooms,
      avatarMedia: _UnavailableAvatarMedia(),
    ));
    expect(
      tester
          .widget<MatrixUserAvatar>(find.descendant(
            of: historyRow,
            matching: find.byType(MatrixUserAvatar),
          ))
          .matrixAvatarUri,
      Uri.parse('mxc://test/new-avatar'),
    );
  });

  testWidgets('historical source opens its event with the primary avatar',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = await _api();
    final nav = _Nav();
    final registry = DuplicateRoomRegistry();
    final client = _SearchClient('owner');
    client.primaryRoom = Room(
      client: client,
      id: '!primary:test',
      membership: Membership.join,
    );
    await registry.record(
      accountId: '@owner:test',
      peerId: '@friend:test',
      primaryRoomId: '!primary:test',
      duplicateRoomId: '!source:test',
    );
    final index = GlobalSearchIndex()
      ..recordRoom(
        roomId: '!source:test',
        roomName: '项目旧会话',
        isGroup: false,
        messages: [_record(r'$source', '项目历史记录')],
      );
    await tester.pumpWidget(_page(
      api: api,
      nav: nav,
      matrix: _matrixOwner('owner', client: client, duplicateRooms: registry),
      index: index,
      contacts: const [],
      rooms: [
        GlobalSearchRoomResult(
          roomId: '!primary:test',
          displayName: '项目好友',
          isDirect: true,
          directPeerId: '@friend:test',
          matrixAvatarUri: Uri.parse('mxc://test/primary-avatar'),
        ),
      ],
      avatarMedia: _UnavailableAvatarMedia(),
    ));
    await _search(tester, '项目');

    final historyRow =
        find.byKey(const Key('global-search-conversation-!primary:test'));
    expect(historyRow, findsOneWidget);
    expect(
      tester
          .widget<MatrixUserAvatar>(find.descendant(
            of: historyRow,
            matching: find.byType(MatrixUserAvatar),
          ))
          .matrixAvatarUri,
      Uri.parse('mxc://test/primary-avatar'),
    );
    await tester.tap(historyRow);
    await tester.pump();
    expect(
        nav.opened.single, (roomId: '!source:test', anchorEventId: r'$source'));
  });

  testWidgets('current Matrix avatars paint in 40dp room and history rows',
      (tester) async {
    final api = await _api();
    final nav = _Nav();
    final index = GlobalSearchIndex()
      ..recordRoom(
        roomId: '!project:test',
        roomName: '项目群',
        isGroup: true,
        messages: [_record(r'$group', '项目历史')],
      )
      ..recordRoom(
        roomId: '!direct:test',
        roomName: '项目伙伴',
        isGroup: false,
        messages: [_record(r'$direct', '项目私聊历史')],
      );
    final rooms = [
      GlobalSearchRoomResult(
        roomId: '!project:test',
        displayName: '项目群',
        isDirect: false,
        matrixAvatarUri: Uri.parse('mxc://test/group'),
      ),
      GlobalSearchRoomResult(
        roomId: '!project-mosaic:test',
        displayName: '项目小组',
        isDirect: false,
        avatarMembers: [
          GlobalSearchAvatarMember(
            userId: '@one:test',
            displayName: '成员一',
            matrixAvatarUri: Uri.parse('mxc://test/one'),
          ),
          GlobalSearchAvatarMember(
            userId: '@two:test',
            displayName: '成员二',
            matrixAvatarUri: Uri.parse('mxc://test/two'),
          ),
        ],
      ),
      GlobalSearchRoomResult(
        roomId: '!direct:test',
        displayName: '项目伙伴',
        isDirect: true,
        directPeerId: '@peer:test',
        matrixAvatarUri: Uri.parse('mxc://test/peer'),
      ),
    ];
    await tester.pumpWidget(_page(
      api: api,
      nav: nav,
      rooms: rooms,
      index: index,
      contacts: const [],
      avatarMedia: _UnavailableAvatarMedia(),
    ));
    await _search(tester, '项目');

    for (final rowKey in [
      'global-search-room-!project:test',
      'global-search-room-!project-mosaic:test',
      'global-search-conversation-!project:test',
      'global-search-conversation-!direct:test',
    ]) {
      final row = find.byKey(Key(rowKey));
      expect(row, findsOneWidget);
      expect(tester.widget<WeChatListTile>(row).leadingSize,
          WeChatDimensions.contactAvatar);
      expect(
        tester.getSize(find.descendant(
          of: row,
          matching: find.byType(SearchRoomAvatar),
        )),
        const Size(40, 40),
      );
    }
    final groupRow = find.byKey(const Key('global-search-room-!project:test'));
    expect(
      tester
          .widget<MatrixUserAvatar>(find.descendant(
            of: groupRow,
            matching: find.byType(MatrixUserAvatar),
          ))
          .matrixAvatarUri,
      Uri.parse('mxc://test/group'),
    );
    final groupHistory =
        find.byKey(const Key('global-search-conversation-!project:test'));
    expect(
      tester
          .widget<MatrixUserAvatar>(find.descendant(
            of: groupHistory,
            matching: find.byType(MatrixUserAvatar),
          ))
          .matrixAvatarUri,
      Uri.parse('mxc://test/group'),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('global-search-room-!project-mosaic:test')),
        matching: find.byType(GroupAvatarMosaic),
      ),
      findsOneWidget,
    );
    final directHistory =
        find.byKey(const Key('global-search-conversation-!direct:test'));
    expect(
      tester
          .widget<MatrixUserAvatar>(find.descendant(
            of: directHistory,
            matching: find.byType(MatrixUserAvatar),
          ))
          .matrixAvatarUri,
      Uri.parse('mxc://test/peer'),
    );

    await tester.tap(groupRow);
    await tester.pump();
    expect(nav.opened.last, (roomId: '!project:test', anchorEventId: null));
    await tester.tap(directHistory);
    await tester.pump();
    expect(
        nav.opened.last, (roomId: '!direct:test', anchorEventId: r'$direct'));
  });

  testWidgets('every submitted search has separate content-free diagnostics',
      (tester) async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    final api = await _api(performanceRecorder: recorder);
    await tester.pumpWidget(_page(
      api: api,
      index: _index([_record(r'$1', 'sample local result')]),
      searchPerformanceTrace: recorder.start(PerformanceOperationType.search),
    ));
    await _search(tester, 'sample');
    await _search(tester, 'result');
    final searches = records
        .where((record) => record.operation == PerformanceOperationType.search)
        .toList();
    expect(searches, hasLength(2));
    expect(searches.first.operationId, isNot(searches.last.operationId));
    expect(
        searches.map((r) => r.toJson()).toString(), isNot(contains('sample')));
    await tester.pumpWidget(const SizedBox());
    recorder.clear();
  });
  testWidgets('search page initial contacts request shares page operation ID',
      (tester) async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    final pageTrace = recorder.start(PerformanceOperationType.searchPageOpen);
    final api = await _api(performanceRecorder: recorder);

    await tester.pumpWidget(_page(
      api: api,
      index: GlobalSearchIndex(),
      loadContactsFromApi: true,
      performanceTrace: pageTrace,
    ));
    await tester.pumpAndSettle();

    expect(
        records.any((record) =>
            record.operation == PerformanceOperationType.apiRequest &&
            record.endpointCategory == PerformanceEndpointCategory.friendship &&
            record.operationId == pageTrace.operationId),
        isTrue);
  });

  testWidgets('search page paints before sources and first query has own trace',
      (tester) async {
    final api = await _api();
    final contacts = Completer<List<ContactSummary>>();
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    await tester.pumpWidget(_page(
      api: api,
      contactsLoader: () => contacts.future,
      performanceTrace: recorder.start(PerformanceOperationType.searchPageOpen),
      searchPerformanceTrace: recorder.start(PerformanceOperationType.search),
    ));
    await tester.pump();
    expect(records, isEmpty);
    contacts.complete(_contacts);
    await tester.pump();
    expect(records, hasLength(1));
    expect(records.single.operation, PerformanceOperationType.searchPageOpen);
    expect(
        records.single.stagesUs.keys,
        containsAll([
          PerformanceStage.routeEnter,
          PerformanceStage.firstFrameRendered,
          PerformanceStage.contentReady,
        ]));

    await _search(tester, '项目');
    expect(records, hasLength(2));
    final query = records.last;
    expect(query.operation, PerformanceOperationType.search);
    expect(
        query.stagesUs.keys,
        containsAll([
          PerformanceStage.localSearchStarted,
          PerformanceStage.localSearchDone,
          PerformanceStage.renderResults,
        ]));
    expect(query.stagesUs.containsKey(PerformanceStage.databaseSearchDone),
        isFalse);
  });

  testWidgets('blank query keeps the page clean (no sections, no results)',
      (tester) async {
    final api = await _api();
    await tester
        .pumpWidget(_page(api: api, index: _index([_record(r'$a', '项目文件')])));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('global-search-section-联系人')), findsNothing);
    expect(find.byKey(const Key('global-search-section-群聊')), findsNothing);
    expect(find.byKey(const Key('global-search-section-聊天记录')), findsNothing);
    expect(find.text('无搜索结果'), findsNothing, reason: '空查询既不显示结果也不显示“无结果”');
  });

  testWidgets('keyword shows 联系人/群聊/聊天记录 with typed rows', (tester) async {
    final api = await _api();
    final nav = _Nav();
    await tester.pumpWidget(_page(
      api: api,
      nav: nav,
      rooms: const [
        GlobalSearchRoomResult(
            roomId: '!group:test',
            displayName: '项目数智中心',
            isDirect: false,
            memberCount: 8),
        GlobalSearchRoomResult(
            roomId: '!dm:test', displayName: '项目私聊', isDirect: true),
      ],
      index: _index([_record(r'$hit', '项目文件已发送')]),
    ));
    await _search(tester, '项目');

    expect(find.byKey(const Key('global-search-section-联系人')), findsOneWidget);
    expect(find.byKey(const Key('global-search-section-群聊')), findsOneWidget);
    expect(find.byKey(const Key('global-search-section-聊天记录')), findsOneWidget);
    expect(find.text('朋友'), findsNothing, reason: '分组名必须是「联系人」');
    expect(find.byKey(const Key('global-search-contact-u1')), findsOneWidget);
    expect(find.byKey(const Key('global-search-room-!group:test')),
        findsOneWidget);
    expect(find.byKey(const Key('global-search-conversation-!group:test')),
        findsOneWidget);
    // direct room 不得进入群聊分组，也不得有可点击的群聊行。
    expect(find.byKey(const Key('global-search-room-!dm:test')), findsNothing,
        reason: '私聊房间不得出现在群聊分组');
  });

  testWidgets('group row opens the room through the injected navigation',
      (tester) async {
    final api = await _api();
    final nav = _Nav();
    await tester.pumpWidget(_page(api: api, nav: nav, index: _index([])));
    await _search(tester, '数智');

    await tester.tap(find.byKey(const Key('global-search-room-!group:test')));
    await tester.pump();
    expect(nav.opened.single.roomId, '!group:test');
    expect(nav.opened.single.anchorEventId, isNull);
  });

  testWidgets('single message hit opens the room anchored at the event',
      (tester) async {
    final api = await _api();
    final nav = _Nav();
    await tester.pumpWidget(_page(
      api: api,
      nav: nav,
      index: _index([_record(r'$only', '项目文件已发送')]),
    ));
    await _search(tester, '项目');

    await tester
        .tap(find.byKey(const Key('global-search-conversation-!group:test')));
    await tester.pump();
    expect(nav.opened.single.roomId, '!group:test');
    expect(nav.opened.single.anchorEventId, r'$only', reason: '单条命中直接定位该事件');
  });

  testWidgets(
      'multiple hits aggregate per conversation and open the anchor from the records page',
      (tester) async {
    final api = await _api();
    final nav = _Nav();
    await tester.pumpWidget(_page(
      api: api,
      nav: nav,
      index: _index([
        _record(r'$1', '项目文件1',
            senderName: '张三', at: DateTime.utc(2026, 9, 15, 9)),
        _record(r'$2', '项目文件2',
            senderName: '李四', at: DateTime.utc(2026, 9, 15, 11)),
      ]),
    ));
    await _search(tester, '项目');

    expect(find.text('2条相关聊天记录'), findsOneWidget);
    await tester
        .tap(find.byKey(const Key('global-search-conversation-!group:test')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('global-search-conversation-records')),
        findsOneWidget);
    expect(find.byKey(const Key('global-search-hit-\$2')), findsOneWidget);
    expect(find.byKey(const Key('global-search-hit-\$1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('global-search-hit-\$1')));
    await tester.pump();
    expect(nav.opened.single.anchorEventId, r'$1');
  });

  testWidgets('keyword highlight is rendered in the snippet', (tester) async {
    final api = await _api();
    final nav = _Nav();
    await tester.pumpWidget(_page(
      api: api,
      nav: nav,
      index: _index([
        _record(r'$1', '项目文件1'),
        _record(r'$2', '项目文件2'),
      ]),
    ));
    await _search(tester, '项目');
    await tester
        .tap(find.byKey(const Key('global-search-conversation-!group:test')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final rich = tester.widgetList<Text>(find.byType(Text)).where((text) {
      final span = text.textSpan;
      return span is TextSpan &&
          span.children?.any((child) =>
                  child is TextSpan &&
                  child.style?.fontWeight == FontWeight.w600) ==
              true;
    });
    expect(rich, isNotEmpty, reason: '命中片段必须高亮关键词');
  });

  testWidgets('locked ciphertext is never surfaced; decrypted body is',
      (tester) async {
    final api = await _api(requests: []);
    final nav = _Nav();
    final index = _index([_record(r'$plain', 'visible-body')]);
    await tester.pumpWidget(_page(api: api, nav: nav, index: index));
    await _search(tester, 'hidden-ciphertext');
    expect(find.byKey(const Key('global-search-empty')), findsOneWidget,
        reason: '未解密正文不得进入搜索结果');

    await _search(tester, 'visible-body');
    expect(find.byKey(const Key('global-search-conversation-!group:test')),
        findsOneWidget);
  });

  testWidgets('query never reaches the Business API', (tester) async {
    final requests = <Uri>[];
    final api = await _api(requests: requests);
    await tester.pumpWidget(_page(
      api: api,
      index: _index([_record(r'$1', '项目文件')]),
    ));
    requests.clear();
    await _search(tester, '项目文件');
    expect(requests, isEmpty, reason: '查询词与明文都不得离开设备（禁止服务端明文索引）');
  });

  testWidgets('matrix unavailable degrades without crashing', (tester) async {
    final api = await _api();
    await tester.pumpWidget(CupertinoApp(
      home: GlobalSearchPage(
        api: api,
        index: _index([]),
        debounce: Duration.zero,
        onOpenRoom: (_, {anchorEventId}) async {},
        contactsLoader: () async => throw StateError('matrix unavailable'),
      ),
    ));
    await _search(tester, '项目');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('global-search-error')), findsOneWidget);
  });

  testWidgets('search always offers openable rooms (onOpenRoom is required)',
      (tester) async {
    final api = await _api();
    await tester.pumpWidget(_page(
      api: api,
      index: _index([_record(r'$hit', '项目文件')]),
    ));
    // 架构改造：onOpenRoom 必填（非 optional），因此三个 Tab 都具备
    // 群聊/聊天记录打开能力，不再出现"未注入就不展示分组"的能力分叉。
    await _search(tester, '数智');
    expect(find.byKey(const Key('global-search-section-群聊')), findsOneWidget,
        reason: '群聊分组必须可用（打开能力必填）');

    await _search(tester, '项目');
    expect(find.byKey(const Key('global-search-section-联系人')), findsOneWidget);
    expect(find.byKey(const Key('global-search-section-聊天记录')), findsOneWidget,
        reason: '聊天记录分组必须可用（打开能力必填）');
  });

  testWidgets('unified search bar renders the shared nav title without hero',
      (tester) async {
    final api = await _api();
    await tester.pumpWidget(_page(api: api, index: _index([])));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('global-search-nav')), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
  });

  testWidgets('debounce avoids searching on every keystroke', (tester) async {
    final api = await _api();
    var roomsLoaded = 0;
    await tester.pumpWidget(CupertinoApp(
      home: GlobalSearchPage(
        api: api,
        index: _index([_record(r'$hit', '项目文件')]),
        debounce: const Duration(milliseconds: 250),
        onOpenRoom: (_, {anchorEventId}) async {},
        contactsLoader: () async => const [],
        roomsLoader: () async {
          roomsLoaded++;
          return const [];
        },
      ),
    ));
    await tester.enterText(find.byType(CupertinoSearchTextField), 'a');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(CupertinoSearchTextField), 'ab');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(CupertinoSearchTextField), 'abc');
    expect(roomsLoaded, 0, reason: '快速输入期间不得逐字符查询');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(roomsLoaded, 1, reason: '只在防抖结束后查询一次');
  });

  testWidgets('repository-backed page searches the account-scoped local index',
      (tester) async {
    final api = await _api(requests: []);
    final nav = _Nav();
    final repository =
        _repository(messages: [_localMessage(r'$local', '项目本地历史')]);
    await repository.backfillLocalHistory();

    await tester.pumpWidget(_page(api: api, nav: nav, repository: repository));
    await _search(tester, '项目');

    expect(find.byKey(const Key('global-search-conversation-!group:test')),
        findsOneWidget);
    await tester
        .tap(find.byKey(const Key('global-search-conversation-!group:test')));
    await tester.pump();
    expect(nav.opened.single.anchorEventId, r'$local');
  });

  testWidgets('new local matches wait for one explicit update without spinner',
      (tester) async {
    final api = await _api();
    final repository = _repository(messages: [_localMessage(r'$old', '项目旧消息')]);
    await repository.backfillLocalHistory();
    await tester.pumpWidget(_page(api: api, repository: repository));
    await _search(tester, '项目');
    expect(find.byKey(const Key('global-search-conversation-!group:test')),
        findsOneWidget);
    repository.recordRoomMessages([_localMessage(r'$new', '项目新消息')]);
    await tester.pump();
    expect(find.byKey(const Key('global-search-refresh-new')), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('2条相关聊天记录'), findsNothing);
    await tester.tap(find.byKey(const Key('global-search-refresh-new')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('2条相关聊天记录'), findsOneWidget);
    expect(find.byKey(const Key('global-search-refresh-new')), findsNothing);
  });

  testWidgets('opening the page backfills the attached local repository',
      (tester) async {
    final api = await _api();
    final nav = _Nav();
    // 未显式回填：页面打开时应做一次有界的本机库回填。
    final repository =
        _repository(messages: [_localMessage(r'$local', '项目本地历史')]);

    await tester.pumpWidget(_page(api: api, nav: nav, repository: repository));
    await tester.pumpAndSettle();
    await _search(tester, '项目');

    expect(find.byKey(const Key('global-search-conversation-!group:test')),
        findsOneWidget,
        reason: '打开搜索页后本机历史必须可检索');
  });

  testWidgets('repository hits never expose flash photos or media payloads',
      (tester) async {
    final api = await _api();
    final nav = _Nav();
    final repository = _repository(messages: [
      LocalSearchMessage(
        eventId: r'$flash',
        senderId: '@peer:test',
        senderName: '张三',
        timestamp: DateTime.utc(2026, 9, 15, 10),
        body: '项目闪照',
        roomId: '!group:test',
        roomName: '数智经济中心',
        isGroup: true,
        isFlashPhoto: true,
      ),
      _localMessage(r'$text', '项目文件已发送'),
      _localMessage(r'$text2', '项目文件已收到'),
    ]);
    await repository.backfillLocalHistory();

    await tester.pumpWidget(_page(api: api, nav: nav, repository: repository));
    await _search(tester, '项目');
    await tester
        .tap(find.byKey(const Key('global-search-conversation-!group:test')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('global-search-hit-\$text')), findsOneWidget);
    expect(find.byKey(const Key('global-search-hit-\$text2')), findsOneWidget);
    expect(find.byKey(const Key('global-search-hit-\$flash')), findsNothing,
        reason: '闪照必须在入库前被过滤，绝不能出现在结果页');
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
