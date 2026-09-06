import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/discovery/discovery_page.dart';

void main() {
  testWidgets(
      'discovery navigation exposes WeChat-style search and more actions',
      (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(CupertinoApp(home: DiscoveryPage(api: api)));
    expect(find.byKey(const Key('discovery-search')), findsOneWidget);
    expect(find.byKey(const Key('discovery-more')), findsOneWidget);
    expect(tester.getTopLeft(find.text('朋友圈')).dy,
        lessThan(tester.getTopLeft(find.text('扫一扫')).dy));
  });
}
