import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/discovery/discovery_page.dart';
import 'package:liuhetong_mobile/features/moments/moments_unread_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('new posts badge is red numeric and updates without reentry',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var count = 0;
    final controller = MomentsUnreadController(
        accountKey: 'A',
        preferences: await SharedPreferences.getInstance(),
        load: ({String? since, String? cursor}) async => {
              'server_time': '2026-09-06T00:00:00Z',
              'items': List.generate(count, (i) => {'id': '$i'}),
            });
    await controller.initialize();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore());
    await tester.pumpWidget(CupertinoApp(
        home: DiscoveryPage(api: api, unreadController: controller)));
    expect(find.byKey(const Key('moments-new-posts-badge')), findsNothing);
    count = 101;
    await controller.refresh();
    await tester.pump();
    expect(find.text('99+'), findsOneWidget);
    await controller.markDisplayed(List.generate(101, (i) => '$i'));
    await tester.pump();
    expect(find.byKey(const Key('moments-new-posts-badge')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
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
