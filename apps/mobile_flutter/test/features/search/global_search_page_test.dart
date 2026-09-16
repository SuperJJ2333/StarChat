import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/search/global_search_index.dart';
import 'package:liuhetong_mobile/features/search/global_search_models.dart';
import 'package:liuhetong_mobile/features/search/global_search_page.dart';

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
  Future<void> open(GlobalSearchRoomResult room, {String? anchorEventId}) async {
    opened.add((roomId: room.roomId, anchorEventId: anchorEventId));
  }
}

Future<BusinessApiClient> _api({List<Uri>? requests}) async {
  final store = SecureSessionStore(_MemoryStore());
  await store.saveSession(accessToken: 'a', refreshToken: 'r');
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.test'),
    sessionStore: store,
    client: MockClient((request) async {
      requests?.add(request.url);
      return http.Response('{"items":[]}', 200,
          headers: {'content-type': 'application/json'});
    }),
  );
}

Widget _page({
  required BusinessApiClient api,
  required GlobalSearchIndex index,
  _Nav? nav,
  List<GlobalSearchRoomResult> rooms = _rooms,
  List<ContactSummary> contacts = _contacts,
  Duration debounce = Duration.zero,
}) =>
    CupertinoApp(
      home: GlobalSearchPage(
        api: api,
        index: index,
        debounce: debounce,
        contactsLoader: () async => contacts,
        roomsLoader: () async => rooms,
        onOpenRoom: nav?.open,
      ),
    );

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(CupertinoSearchTextField), query);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
}

void main() {
  testWidgets('blank query keeps the page clean (no sections, no results)',
      (tester) async {
    final api = await _api();
    await tester.pumpWidget(_page(api: api, index: _index([_record(r'$a', '项目文件')])));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('global-search-section-联系人')), findsNothing);
    expect(find.byKey(const Key('global-search-section-群聊')), findsNothing);
    expect(find.byKey(const Key('global-search-section-聊天记录')), findsNothing);
    expect(find.text('无搜索结果'), findsNothing,
        reason: '空查询既不显示结果也不显示“无结果”');
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
    expect(
        find.byKey(const Key('global-search-conversation-!group:test')),
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

    await tester.tap(
        find.byKey(const Key('global-search-conversation-!group:test')));
    await tester.pump();
    expect(nav.opened.single.roomId, '!group:test');
    expect(nav.opened.single.anchorEventId, r'$only',
        reason: '单条命中直接定位该事件');
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
        _record(r'$1', '项目文件1', senderName: '张三', at: DateTime.utc(2026, 9, 15, 9)),
        _record(r'$2', '项目文件2', senderName: '李四', at: DateTime.utc(2026, 9, 15, 11)),
      ]),
    ));
    await _search(tester, '项目');

    expect(find.text('2条相关聊天记录'), findsOneWidget);
    await tester.tap(
        find.byKey(const Key('global-search-conversation-!group:test')));
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
    await tester.tap(
        find.byKey(const Key('global-search-conversation-!group:test')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final rich = tester.widgetList<Text>(find.byType(Text)).where((text) {
      final span = text.textSpan;
      return span is TextSpan &&
          span.children?.any((child) =>
                  child is TextSpan && child.style?.fontWeight == FontWeight.w600) ==
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
    expect(
        find.byKey(const Key('global-search-conversation-!group:test')),
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
    expect(requests, isEmpty,
        reason: '查询词与明文都不得离开设备（禁止服务端明文索引）');
  });

  testWidgets('matrix unavailable degrades without crashing', (tester) async {
    final api = await _api();
    await tester.pumpWidget(CupertinoApp(
      home: GlobalSearchPage(
        api: api,
        index: _index([]),
        debounce: Duration.zero,
        contactsLoader: () async => throw StateError('matrix unavailable'),
      ),
    ));
    await _search(tester, '项目');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('global-search-error')), findsOneWidget);
  });

  testWidgets(
      'without an injected room navigator only contacts are offered',
      (tester) async {
    final api = await _api();
    await tester.pumpWidget(_page(
      api: api,
      nav: null,
      index: _index([_record(r'$hit', '项目文件')]),
    ));
    await _search(tester, '项目');
    expect(find.byKey(const Key('global-search-section-联系人')), findsOneWidget);
    expect(find.byKey(const Key('global-search-section-群聊')), findsNothing,
        reason: '无房间导航能力时不展示无法打开的群聊/聊天记录分组');
    expect(find.byKey(const Key('global-search-section-聊天记录')), findsNothing);
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
