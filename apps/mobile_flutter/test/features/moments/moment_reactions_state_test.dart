import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';
import 'package:liuhetong_mobile/features/moments/moments_page.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/moments/moments_privacy_changes.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/moments/moment_reactions.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/features/moments/moment_detail_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';
import 'moments_flow_test.dart' as fixtures;

void main() {
  testWidgets('popped detail rollback preserves a newer feed comment',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    final write = Completer<http.Response>();
    final api = await fixtures.momentsApi((r) async {
      Object data = {};
      if (r.url.path.endsWith('/likes')) return write.future;
      if (r.url.path.endsWith('/feed')) {
        data = {
          'items': [json]
        };
      }
      if (r.url.path.endsWith('/m1')) data = json;
      if (r.url.path.endsWith('/comments')) {
        data = {
          'id': 'later',
          'text': 'later comment',
          'author': {'user_id': 'me', 'username': 'me', 'nickname': 'Me'}
        };
      }
      return http.Response(jsonEncode(data), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final identity = ProfileRepository.forTesting(
        accountKey: 'matrix:@me:test', store: fixtures.MomentsIdentityStore())
      ..profile = const ProfileData(
          username: 'me', nickname: 'Me', maskedEmail: '', fallbackSeed: 'me');
    await tester.pumpWidget(
        CupertinoApp(home: MomentsPage(api: api, identityCache: identity)));
    await tester.pumpAndSettle();
    tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).onOpen!();
    await tester.pumpAndSettle();
    tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).onLike!();
    await tester.pump();
    Navigator.of(tester.element(find.byType(MomentDetailPage))).pop();
    await tester.pumpAndSettle();
    tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).onComment!();
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), 'later comment');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<WeChatMomentTile>(find.byType(WeChatMomentTile))
            .item
            .comments
            .map((c) => c.id),
        ['later']);
    write.complete(http.Response('{}', 500));
    await tester.pumpAndSettle();
    final tile = tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile));
    expect(tile.item.liked, isFalse);
    expect(tile.item.comments.map((c) => c.id), ['later']);
    await tester.pumpWidget(const SizedBox());
    identity.dispose();
  });
  for (final inherited in [true, false]) {
    testWidgets(
        'privacy refresh supersedes ${inherited ? "inherited" : "local"} pending reaction',
        (tester) async {
      final old = fixtures.momentJson(liked: true, likeCount: 1);
      old['like_users'] = [old['author']];
      final fresh = fixtures.momentJson(liked: false, likeCount: 0);
      var private = false;
      final response = Completer<http.Response>();
      final api = await fixtures.momentsApi((r) async {
        if (r.method == 'DELETE') return response.future;
        return http.Response(jsonEncode(private ? fresh : old), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });
      final before = MomentItem.fromJson(old);
      final pending = inherited ? PendingMomentReaction.begin(api, 'm1') : null;
      await tester.pumpWidget(CupertinoApp(
          home: MomentDetailPage(
              api: api, initialItem: before, currentUsername: 'me')));
      await tester.pumpAndSettle();
      if (!inherited) {
        tester
            .widget<WeChatMomentTile>(find.byType(WeChatMomentTile))
            .onLike!();
        await tester.pump();
      }
      private = true;
      momentsPrivacyChanges.changed();
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<WeChatMomentTile>(find.byType(WeChatMomentTile))
              .item
              .likeUsers,
          isEmpty);
      if (inherited) {
        pending!.finish(api, before);
      } else {
        response.complete(http.Response('{}', 500));
      }
      await tester.pumpAndSettle();
      final tile =
          tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile));
      expect(tile.item.likeUsers, isEmpty,
          reason: 'old completion must not restore blocked audience');
      expect(tile.onLike, isNotNull);
    });
  }
  testWidgets(
      'detail inherits pending feed write and preserves reply during rollback',
      (tester) async {
    final before =
        MomentItem.fromJson(fixtures.momentJson(liked: false, likeCount: 0));
    var reads = 0;
    final api = await fixtures.momentsApi((_) async {
      reads++;
      return http.Response('{}', 200);
    });
    final pending = PendingMomentReaction.begin(api, before.id);
    final optimistic =
        toggleMomentReaction(before, momentViewer(null, username: 'me'));
    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api, initialItem: optimistic, currentUsername: 'me')));
    await tester.pump();
    expect(
        tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).onLike,
        isNull);
    expect(reads, 0,
        reason: 'pending write must not be replaced by stale detail refresh');
    pending.finish(api, before);
    await tester.pumpAndSettle();
    final tile = tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile));
    expect(tile.item.liked, isFalse);
    expect(tile.item.likeUsers, isEmpty);
    expect(tile.onLike, isNotNull);
  });
  testWidgets('detail popped during failed write still rolls parent back',
      (tester) async {
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    final write = Completer<http.Response>();
    final api = await fixtures.momentsApi((r) async => r.method == 'POST'
        ? write.future
        : http.Response(jsonEncode(json), 200,
            headers: {'content-type': 'application/json; charset=utf-8'}));
    MomentItem? parent;
    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api,
            initialItem: MomentItem.fromJson(json),
            currentUsername: 'me',
            onChanged: (value) => parent = value)));
    await tester.pumpAndSettle();
    tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).onLike!();
    await tester.pump();
    expect(parent!.liked, isTrue);
    await tester.pumpWidget(const SizedBox());
    write.complete(http.Response('{}', 500));
    await tester.pumpAndSettle();
    expect(parent!.liked, isFalse);
    expect(PendingMomentReaction.find(api, 'm1'), isNull);
  });
  test(
      'projection redacts stranger reply parent and hidden friend without mutating DTO',
      () {
    final identity = ProfileRepository.forTesting(
        accountKey: 'me', store: fixtures.MomentsIdentityStore());
    identity.contacts = [
      const ContactSummary(
          userId: 'u1',
          username: 'alice_id',
          matrixUserId: '@alice:test',
          momentsPermission: 'HIDE_THEIRS')
    ];
    final json = fixtures.momentJson(liked: false, likeCount: 1);
    json['like_users'] = [json['author']];
    json['comments'] = [
      {
        'id': 'reply',
        'text': 'hello',
        'author': {'user_id': 'me', 'username': 'me'},
        'parent_author': json['author']
      }
    ];
    final item = MomentItem.fromJson(json);
    final visible = visibleMomentReactions(item, identity, username: 'me');
    expect(visible.likeUsers, isEmpty);
    expect(visible.comments.single.parentAuthor, isNull);
    expect(item.comments.single.parentAuthor, isNotNull);
    identity.dispose();
  });
  test('timestamp preserves UTC and remains optional for older cached comments',
      () {
    final json = {
      'id': 'c',
      'text': 'hi',
      'author': {'user_id': 'me'},
      'created_at': '2026-09-09T05:03:00+00:00'
    };
    expect(MomentCommentView.fromJson(json).createdAt,
        DateTime.utc(2026, 9, 9, 5, 3));
    json.remove('created_at');
    expect(MomentCommentView.fromJson(json).createdAt, isNull);
  });
  testWidgets('cached strangers do not paint before contacts are available',
      (tester) async {
    final json = fixtures.momentJson(liked: false, likeCount: 1);
    json['like_users'] = [json['author']];
    json['comments'] = [
      {'id': 'stranger', 'text': 'hidden cached text', 'author': json['author']}
    ];
    final get = Completer<http.Response>();
    final api = await fixtures.momentsApi((_) => get.future);
    final identity = ProfileRepository.forTesting(
        accountKey: 'viewer', store: fixtures.MomentsIdentityStore());
    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api,
            identityCache: identity,
            initialItem: MomentItem.fromJson(json),
            currentUsername: 'me')));
    final tile = tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile));
    expect(tile.item.comments, isEmpty);
    expect(tile.item.likeUsers, isEmpty);
    expect(tile.item.likeCount, 0);
    await tester.pumpWidget(const SizedBox());
    get.complete(http.Response('{}', 404));
    await tester.pumpAndSettle();
    identity.dispose();
  });
  testWidgets('like projects viewer immediately and rollback preserves comment',
      (tester) async {
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    final write = Completer<http.Response>();
    var likes = 0;
    final api = await fixtures.momentsApi((r) async {
      if (r.url.path.endsWith('/likes')) {
        likes++;
        return write.future;
      }
      if (r.method == 'POST') {
        return http.Response(
            jsonEncode(
                {'id': 'new', 'text': 'new comment', 'author': json['author']}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response(jsonEncode(json), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api,
            initialItem: MomentItem.fromJson(json),
            currentUsername: 'me')));
    await tester.pumpAndSettle();
    final initial =
        tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile));
    initial.onLike!();
    initial.onLike!();
    await tester.pump();
    var tile = tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile));
    expect(tile.item.likeUsers.map((u) => u.username), ['me']);
    expect(tile.item.likeCount, 1);
    expect(likes, 1);
    tile.onComment!();
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), 'new comment');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    await tester.pumpAndSettle();
    write.complete(http.Response('{}', 500));
    await tester.pumpAndSettle();
    tile = tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile));
    expect(tile.item.likeUsers, isEmpty);
    expect(tile.item.liked, isFalse);
    expect(tile.item.comments.map((c) => c.id), ['new']);
  });
  testWidgets('own comment can copy exact text without deleting',
      (tester) async {
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    json['comments'] = [
      {'id': 'mine', 'text': 'hello 😀', 'author': json['author']}
    ];
    var deletes = 0;
    final api = await fixtures.momentsApi((r) async {
      if (r.method == 'DELETE') deletes++;
      return http.Response(jsonEncode(json), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api,
            initialItem: MomentItem.fromJson(json),
            currentUsername: 'alice_id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('moment-comment-mine')));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copied, 'hello 😀');
    expect(deletes, 0);
  });
}
