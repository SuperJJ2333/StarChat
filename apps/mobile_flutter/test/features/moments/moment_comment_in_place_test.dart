import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'dart:convert';
import 'dart:async';
import 'package:liuhetong_mobile/features/moments/moment_comment_interaction.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
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
  testWidgets(
      'post owner deletion keeps comment on failure and prevents duplicate requests',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    json['comments'] = [
      {
        'id': 'friend-comment',
        'text': 'friend text',
        'author': {
          'user_id': 'friend',
          'username': 'friend',
          'nickname': 'Friend'
        }
      }
    ];
    var item = MomentItem.fromJson(json);
    final response = Completer<http.Response>();
    var calls = 0;
    String? error;
    final api = await fixtures.momentsApi((request) async {
      calls++;
      return response.future;
    });
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoPageScaffold(
                child: Center(
                    child: CupertinoButton(
                        child: const Text('菜单'),
                        onPressed: () => interactWithMomentComment(context,
                            api: api,
                            momentId: item.id,
                            currentUsername: 'alice_id',
                            comment: item.comments.first,
                            longPress: true,
                            currentItem: () => item,
                            onChanged: (value) => item = value,
                            onSelectionChanged: (_) {},
                            onError: (value) => error = value)))))));
    Future<void> delete() async {
      await tester.tap(find.text('菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
    }

    await delete();
    await delete();
    expect(calls, 1);
    expect(item.comments, hasLength(1));
    response.complete(http.Response('{}', 500));
    await tester.pumpAndSettle();
    expect(error, '删除失败，请重试');
    expect(item.comments, hasLength(1));
  });
  testWidgets('confirmed deletion broadcasts even when cache callback fails',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    json['comments'] = [
      {
        'id': 'friend-comment',
        'text': 'friend text',
        'author': {
          'user_id': 'friend',
          'username': 'friend',
          'nickname': 'Friend'
        }
      }
    ];
    var item = MomentItem.fromJson(json);
    final response = Completer<http.Response>();
    var calls = 0;
    String? error;
    final api = await fixtures.momentsApi((request) async {
      calls++;
      return response.future;
    });
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoPageScaffold(
                child: Center(
                    child: CupertinoButton(
                        child: const Text('菜单'),
                        onPressed: () => interactWithMomentComment(context,
                            api: api,
                            momentId: item.id,
                            currentUsername: 'alice_id',
                            comment: item.comments.first,
                            longPress: true,
                            currentItem: () => item,
                            onChanged: (value) => item = value,
                            onConfirmed: (_) async =>
                                throw StateError("cache unavailable"),
                            onSelectionChanged: (_) {},
                            onError: (value) => error = value)))))));
    Future<void> delete() async {
      await tester.tap(find.text('菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
    }

    await delete();
    expect(calls, 1);
    expect(item.comments, hasLength(1));
    response.complete(http.Response('', 204));
    await tester.pumpAndSettle();
    expect(item.comments, isEmpty);
    expect(momentCommentDeletions.value?.api, same(api));
    expect(momentCommentDeletions.value?.commentId, 'friend-comment');
    expect(error, '评论已删除，请刷新页面');
  });
  for (final personal in [false, true]) {
    for (final own in [false, true]) {
      for (final longPress in [false, true]) {
        testWidgets(
            '${personal ? "personal" : "feed"} ${own ? "own" : "other"} ${longPress ? "long press" : "tap"} comment operates in place',
            (tester) async {
          SharedPreferences.setMockInitialValues({});
          await CacheRepository.resetForTest();
          final json = fixtures.momentJson(liked: false, likeCount: 0);
          json['comments'] = [
            {
              'id': 'c1',
              'text': 'comment body',
              'author': longPress
                  ? {
                      'user_id': 'friend',
                      'username': 'friend',
                      'nickname': 'Friend'
                    }
                  : json['author']
            }
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
                  userId: 'friend',
                  username: 'friend',
                  matrixUserId: '@friend:test'),
              ContactSummary(
                  userId: 'u1',
                  username: 'alice_id',
                  matrixUserId: '@alice:test')
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
          if (longPress) {
            await tester
                .longPress(find.byKey(const ValueKey('moment-comment-c1')));
          } else {
            await tester.tap(find.byKey(const ValueKey('moment-comment-c1')));
          }
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
            if (longPress) {
              await tester
                  .longPress(find.byKey(const ValueKey('moment-comment-c1')));
            } else {
              await tester.tap(find.byKey(const ValueKey('moment-comment-c1')));
            }
            await tester.pumpAndSettle();
            await tester.tap(find.text('删除'));
            await tester.pumpAndSettle();
            expect(deleted, endsWith('/moments/m1/comments/c1'));
            expect(
                find.byKey(const ValueKey('moment-comment-c1')), findsNothing);
          } else if (longPress) {
            expect(find.text('复制'), findsOneWidget);
            expect(find.text('删除'), findsNothing);
            await tester.tap(find.text('复制'));
            await tester.pumpAndSettle();
          } else {
            expect(
                find.byKey(const Key('moment-comment-input')), findsOneWidget);
            expect(
                tester
                    .widget<WeChatMomentTile>(find.byType(WeChatMomentTile))
                    .selectedCommentId,
                'c1');
            Navigator.of(tester
                    .element(find.byKey(const Key('moment-comment-input'))))
                .pop();
            await tester.pumpAndSettle();
            expect(
                tester
                    .widget<WeChatMomentTile>(find.byType(WeChatMomentTile))
                    .selectedCommentId,
                isNull);
          }
          if (!own && !longPress) {
            if (longPress) {
              await tester
                  .longPress(find.byKey(const ValueKey('moment-comment-c1')));
            } else {
              await tester.tap(find.byKey(const ValueKey('moment-comment-c1')));
            }
            await tester.pumpAndSettle();
            await tester.enterText(
                find.byKey(const Key('moment-comment-input')),
                'reply in place');
            await tester.pump();
            await tester.tap(find.byKey(const Key('moment-comment-submit')));
            await tester.pumpAndSettle();
            expect(submitted?['parent_id'], 'c1');
            expect(find.byKey(const ValueKey('moment-comment-reply')),
                findsOneWidget);
            expect(find.byType(MomentDetailPage, skipOffstage: false),
                findsNothing);
          }
          await tester.pumpWidget(const SizedBox());
          identity.dispose();
        });
      }
    }
  }
}
