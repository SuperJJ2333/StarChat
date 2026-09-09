import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/moments/moments_page.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'moments_flow_test.dart' as fixtures;

void main() {
  testWidgets('every Moments entry refreshes owner identity after preload',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
    var loads = 0;
    final identity = ProfileRepository.forTesting(
        accountKey: 'matrix:@me:test',
        store: fixtures.MomentsIdentityStore(),
        loadContacts: () async => [],
        loadProfile: () async {
          loads++;
          return const ProfileData(
              username: 'me',
              nickname: 'Owner',
              maskedEmail: '',
              fallbackSeed: 'me');
        });
    addTearDown(identity.dispose);
    await identity.preload();
    final api = await fixtures.momentsApi((_) async => http.Response('{}', 200,
        headers: {'content-type': 'application/json'}));
    for (var entry = 1; entry <= 2; entry++) {
      await tester.pumpWidget(
          CupertinoApp(home: MomentsPage(api: api, identityCache: identity)));
      await tester.pumpAndSettle();
      expect(loads, entry + 1);
      expect(find.text('Owner'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });
}
