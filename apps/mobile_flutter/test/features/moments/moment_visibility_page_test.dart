import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_visibility_page.dart';

void main() {
  testWidgets('visibility page separates primary and submenu groups',
      (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    await tester.pumpWidget(CupertinoApp(
      home: MomentVisibilityPage(
        api: api,
        initialSelection: const MomentVisibilitySelection.public(),
      ),
    ));

    expect(find.text('公开'), findsOneWidget);
    expect(find.text('私密'), findsOneWidget);
    expect(find.text('只给谁看'), findsOneWidget);
    expect(find.text('不给谁看'), findsOneWidget);
    expect(find.text('选择标签或朋友'), findsNWidgets(2));
    expect(find.byKey(const Key('visibility-group-gap')), findsOneWidget);
    expect(find.byKey(const Key('visibility-include-chevron')), findsOneWidget);
    expect(find.byKey(const Key('visibility-exclude-chevron')), findsOneWidget);
    expect(find.byType(CupertinoRadio<String>), findsNWidgets(2));
  });
}
