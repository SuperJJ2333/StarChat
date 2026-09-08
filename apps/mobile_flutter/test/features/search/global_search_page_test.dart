import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/search/global_search_page.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

void main() {
  testWidgets(
      'global search excludes locked event text but includes decrypted body',
      (tester) async {
    final client = Client('global-search-cache-test');
    final locked =
        Room(id: '!locked:test', client: client, membership: Membership.join);
    locked.lastEvent = Event.fromJson({
      'type': EventTypes.Encrypted,
      'event_id': r'$locked',
      'sender': '@peer:test',
      'origin_server_ts': 1,
      'content': {'algorithm': 'm.megolm.v1.aes-sha2', 'body': 'hidden'}
    }, locked);
    final plain =
        Room(id: '!plain:test', client: client, membership: Membership.join);
    plain.lastEvent = Event.fromJson({
      'type': EventTypes.Message,
      'event_id': r'$plain',
      'sender': '@peer:test',
      'origin_server_ts': 2,
      'content': {'msgtype': 'm.text', 'body': 'visible-body'}
    }, plain);
    client.rooms.addAll([locked, plain]);
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.test'));
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.test'),
        sessionStore: SecureSessionStore());
    await tester.pumpWidget(CupertinoApp(
        home: GlobalSearchPage(
      api: api,
      matrix: matrix,
      contactsLoader: () async => const [],
    )));
    await tester.pumpAndSettle();
    expect(find.text(locked.lastEvent!.text), findsNothing);
    await tester.enterText(
        find.byType(CupertinoSearchTextField), 'visible-body');
    await tester.pumpAndSettle();
    expect(
        find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == 'visible-body'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('global search focuses input and groups friend room results',
      (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(CupertinoApp(
      home: GlobalSearchPage(
        api: api,
        contactsLoader: () async => const [
          ContactSummary(
            userId: 'u1',
            username: 'project-user',
            matrixUserId: '@project:test',
            nickname: '项目伙伴',
          ),
        ],
        rooms: const ['项目群'],
        messages: const ['项目群进度'],
      ),
    ));
    await tester.enterText(find.byType(CupertinoSearchTextField), '项目');
    await tester.pumpAndSettle();
    expect(find.text('朋友'), findsOneWidget);
    expect(find.text('群聊'), findsOneWidget);
    expect(find.text('聊天记录'), findsOneWidget);
    expect(find.text('项目群'), findsWidgets);
  });

  testWidgets('unified search bar renders the shared nav title without hero',
      (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(CupertinoApp(
      home: GlobalSearchPage(api: api, matrix: null),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('global-search-nav')), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
  });
}
