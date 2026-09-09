import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/moments/moments_page.dart';
import 'package:liuhetong_mobile/features/moments/moments_privacy_changes.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';

import 'moments_flow_test.dart'
    show momentsApi, momentJson, MomentsIdentityStore;

http.Response _response(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

void main() {
  const account = 'matrix:@privacy:test';
  final cachedFeed = {
    'items': [momentJson(liked: false, likeCount: 0)],
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
    await (await CacheRepository.instance())
        .momentsFor(account)
        .save(cachedFeed);
  });

  testWidgets(
      'privacy invalidation hides cached feed while fresh request waits',
      (tester) async {
    final oldRequest = Completer<http.Response>();
    final freshRequest = Completer<http.Response>();
    var feedRequests = 0;
    final api = await momentsApi((request) async {
      if (request.url.path.endsWith('/moments/feed')) {
        feedRequests++;
        return feedRequests == 1 ? oldRequest.future : freshRequest.future;
      }
      return _response({});
    });
    final identity = ProfileRepository.forTesting(
        accountKey: account, store: MomentsIdentityStore());
    await tester.pumpWidget(
        CupertinoApp(home: MomentsPage(api: api, identityCache: identity)));
    await tester.pumpAndSettle();
    expect(find.text('朋友圈正文'), findsOneWidget);
    expect(feedRequests, 1);

    momentsPrivacyChanges.changed();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('朋友圈正文'), findsNothing,
        reason:
            'A known privacy change must discard cached authorization immediately.');
    expect(feedRequests, 2);

    freshRequest.complete(_response({'items': []}));
    oldRequest.complete(_response({'items': []}));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late pre-privacy response cannot restore denied feed or cache',
      (tester) async {
    final oldRequest = Completer<http.Response>();
    var feedRequests = 0;
    final api = await momentsApi((request) async {
      if (request.url.path.endsWith('/moments/feed')) {
        feedRequests++;
        if (feedRequests == 1) return oldRequest.future;
        return _response({'items': []});
      }
      return _response({});
    });
    final identity = ProfileRepository.forTesting(
        accountKey: account, store: MomentsIdentityStore());
    await tester.pumpWidget(
        CupertinoApp(home: MomentsPage(api: api, identityCache: identity)));
    await tester.pumpAndSettle();
    expect(find.text('朋友圈正文'), findsOneWidget);

    momentsPrivacyChanges.changed();
    await tester.pumpAndSettle();
    expect(feedRequests, 2);
    expect(find.text('朋友圈正文'), findsNothing);

    oldRequest.complete(_response(cachedFeed));
    await tester.pumpAndSettle();
    expect(find.text('朋友圈正文'), findsNothing,
        reason: 'An older request must not replace a newer privacy decision.');
    final persisted =
        await (await CacheRepository.instance()).momentsFor(account).load();
    expect(persisted?['items'] ?? [], isEmpty,
        reason:
            'A late response must not restore revoked content on next entry.');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'feed avatar opens cached friend by business ID without contact lookup',
      (tester) async {
    var contactRequests = 0;
    final api = await momentsApi((request) async {
      if (request.url.path.endsWith('/moments/feed')) {
        return _response(cachedFeed);
      }
      if (request.url.path.contains('/contacts')) {
        contactRequests++;
        return http.Response('{}', 503);
      }
      return _response({'entry_visible': false, 'items': []});
    });
    const friend = ContactSummary(
        userId: 'u1',
        username: 'alice_id',
        matrixUserId: '@alice:test',
        nickname: 'Cached Alice');
    final store = MomentsIdentityStore();
    await store.write(
        account,
        const ProfileSnapshot(
            profile: ProfileData(
                username: 'me',
                nickname: 'Me',
                maskedEmail: '',
                fallbackSeed: 'me'),
            contacts: [friend]));
    final identity =
        ProfileRepository.forTesting(accountKey: account, store: store);
    await identity.hydrate();
    await tester.pumpWidget(
        CupertinoApp(home: MomentsPage(api: api, identityCache: identity)));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) =>
        widget is UserAvatar && widget.diagnosticSource == 'moments-feed'));
    await tester.pumpAndSettle();
    expect(find.byType(ContactProfilePage), findsOneWidget);
    expect(
        tester
            .widget<ContactProfilePage>(find.byType(ContactProfilePage))
            .initialContact
            .userId,
        'u1');
    expect(contactRequests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
