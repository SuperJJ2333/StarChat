import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/search/global_search_page.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

void main() {
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
}
