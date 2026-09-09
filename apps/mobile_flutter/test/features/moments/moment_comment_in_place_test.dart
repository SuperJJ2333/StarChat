import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/moments/moments_page.dart';
import 'package:liuhetong_mobile/features/moments/personal_moments_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_detail_page.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';
import 'moments_flow_test.dart' as fixtures;

void main() {
  for (final personal in [false, true]) {
    for (final own in [false, true]) {
      testWidgets(
          '${personal ? "personal" : "feed"} ${own ? "own" : "other"} comment operates in place',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        await CacheRepository.resetForTest();
        final json = fixtures.momentJson(liked: false, likeCount: 0);
        json['comments'] = [
          {'id': 'c1', 'text': 'comment body', 'author': json['author']}
        ];
        String? deleted;
        Map<String, dynamic>? submitted;
        final api = await fixtures.momentsApi((r) async {
          if (r.method == 'POST' && r.url.path.endsWith('/comments')) {
            submitted = jsonDecode(r.body) as Map<String, dynamic>;
            return http.Response(
                jsonEncode({
                  'id': 'reply',
                  'text': submitted!['text'],
                  'author': {
                    'user_id': 'me',
                    'username': 'me',
                    'nickname': 'Me'
                  }
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          if (r.method == 'DELETE') {
            deleted = r.url.path;
            return http.Response('', 204);
          }
          return http.Response(
              jsonEncode(r.url.path.endsWith('/m1')
                  ? json
                  : {
                      'items': [json]
                    }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        });
        final identity = ProfileRepository.forTesting(
            accountKey: 'matrix:@me:test',
            store: fixtures.MomentsIdentityStore(),
            loadProfile: () async => throw StateError('offline'))
          ..contacts = const [
            ContactSummary(
                userId: 'u1', username: 'alice_id', matrixUserId: '@alice:test')
          ]
          ..profile = ProfileData(
              username: own ? 'alice_id' : 'me',
              nickname: 'Me',
              maskedEmail: '',
              fallbackSeed: 'me');
        await tester.pumpWidget(CupertinoApp(
            home: personal
                ? PersonalMomentsPage(
                    api: api,
                    identityCache: identity,
                    userId: 'u1',
                    displayName: 'Alice')
                : MomentsPage(api: api, identityCache: identity)));
        await tester.pumpAndSettle();
        await tester
            .ensureVisible(find.byKey(const ValueKey('moment-comment-c1')));
        await tester.tap(find.byKey(const ValueKey('moment-comment-c1')));
        await tester.pumpAndSettle();
        expect(
            find.byType(MomentDetailPage, skipOffstage: false), findsNothing);
        if (own) {
          expect(find.text('复制'), findsOneWidget);
          expect(find.text('删除'), findsOneWidget);
          expect(find.byKey(const Key('moment-comment-input')), findsNothing);
          await tester.tap(find.text('复制'));
          await tester.pumpAndSettle();
          expect(deleted, isNull);
          await tester.tap(find.byKey(const ValueKey('moment-comment-c1')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('删除'));
          await tester.pumpAndSettle();
          expect(deleted, endsWith('/moments/m1/comments/c1'));
          expect(find.byKey(const ValueKey('moment-comment-c1')), findsNothing);
        } else {
          expect(find.byKey(const Key('moment-comment-input')), findsOneWidget);
          expect(
              tester
                  .widget<WeChatMomentTile>(find.byType(WeChatMomentTile))
                  .selectedCommentId,
              'c1');
          Navigator.of(
                  tester.element(find.byKey(const Key('moment-comment-input'))))
              .pop();
          await tester.pumpAndSettle();
          expect(
              tester
                  .widget<WeChatMomentTile>(find.byType(WeChatMomentTile))
                  .selectedCommentId,
              isNull);
        }
        if (!own) {
          await tester.tap(find.byKey(const ValueKey('moment-comment-c1')));
          await tester.pumpAndSettle();
          await tester.enterText(
              find.byKey(const Key('moment-comment-input')), 'reply in place');
          await tester.pump();
          await tester.tap(find.byKey(const Key('moment-comment-submit')));
          await tester.pumpAndSettle();
          expect(submitted?['parent_id'], 'c1');
          expect(find.byKey(const ValueKey('moment-comment-reply')),
              findsOneWidget);
          expect(
              find.byType(MomentDetailPage, skipOffstage: false), findsNothing);
        }
        await tester.pumpWidget(const SizedBox());
        identity.dispose();
      });
    }
  }
}
