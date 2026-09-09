import 'dart:convert';
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/features/moments/moment_detail_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/ui/moments/moment_image_provider.dart';
import 'moments_flow_test.dart' as fixtures;

void main() {
  testWidgets('pending detail like is never emitted as confirmed persistence',
      (tester) async {
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    final post = Completer<http.Response>();
    final confirmed = <MomentDetailChange>[];
    final api = await fixtures.momentsApi((r) async => r.method == 'POST'
        ? post.future
        : http.Response(jsonEncode(json), 200,
            headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api,
            initialItem: MomentItem.fromJson(json),
            currentUsername: 'me',
            onConfirmed: (_, change) async => confirmed.add(change))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pump();
    expect(confirmed, isEmpty);
    post.complete(http.Response('{}', 200));
    await tester.pumpAndSettle();
    expect(confirmed, [MomentDetailChange.likes]);
  });
  testWidgets(
      'confirmed detail like survives navigating away during its request',
      (tester) async {
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    final post = Completer<http.Response>();
    final confirmed = <MomentDetailChange>[];
    final api = await fixtures.momentsApi((r) async => r.method == 'POST'
        ? post.future
        : http.Response(jsonEncode(json), 200,
            headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api,
            initialItem: MomentItem.fromJson(json),
            currentUsername: 'me',
            onConfirmed: (_, change) async => confirmed.add(change))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pump();
    expect(confirmed, isEmpty);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    post.complete(http.Response('{}', 200));
    await tester.pumpAndSettle();
    expect(confirmed, [MomentDetailChange.likes]);
  });
  test('image replies round trip confirmed snapshot with nullable cache keys',
      () {
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    final source = {
      'id': 'pic',
      'text': '',
      'author': json['author'],
      'parent_author': json['author'],
      'image_urls': ['https://example.com/pic'],
      'image_cache_keys': [null]
    };
    final reply =
        MomentCommentView.fromJson(MomentCommentView.fromJson(source).toJson());
    expect(reply.images, ['https://example.com/pic']);
    expect(reply.imageCacheKeys, [null]);
    expect(reply.parentAuthor?.userId, isNotNull);
  });
  testWidgets(
      'refresh arriving before comment acknowledgment does not duplicate it',
      (tester) async {
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    final comment = {'id': 'new', 'text': 'hello', 'author': json['author']};
    final get = Completer<http.Response>();
    final post = Completer<http.Response>();
    final api = await fixtures
        .momentsApi((r) => r.method == 'POST' ? post.future : get.future);
    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api,
            initialItem: MomentItem.fromJson(json),
            currentUsername: 'me')));
    await tester.tap(find.byKey(const Key('moment-comment-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), 'hello');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    get.complete(http.Response(
        jsonEncode({
          ...json,
          'comments': [comment]
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pump(const Duration(milliseconds: 200));
    post.complete(http.Response(jsonEncode(comment), 200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('moment-comment-new')), findsOneWidget);
  });
  test(
      'renewed signed URLs share trusted digest identity only within an account',
      () {
    final digest = 'a' * 64;
    final first = momentImageProvider(
        'https://example.com/api/v1/profile/avatar/content/old',
        digest,
        'alice',
        'https://example.com');
    final renewed = momentImageProvider(
        'https://example.com/api/v1/profile/avatar/content/new',
        digest,
        'alice',
        'https://example.com');
    expect(first, renewed);
    expect(
        first,
        isNot(momentImageProvider(
            'https://example.com/api/v1/profile/avatar/content/new',
            digest,
            'bob',
            'https://example.com')));
    expect(
        first,
        isNot(momentImageProvider(
            'https://example.com/api/v1/profile/avatar/content/new',
            'b' * 64,
            'alice',
            'https://example.com')));
    expect(
        first,
        isNot(momentImageProvider(
            'https://example.com/api/v1/profile/avatar/content/new',
            digest,
            'alice')));
  });
  testWidgets('confirmed comment deletion survives detail navigation',
      (tester) async {
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    json['comments'] = [
      {'id': 'mine', 'text': 'my comment', 'author': json['author']}
    ];
    final deletion = Completer<http.Response>();
    MomentItem? confirmed;
    final api = await fixtures.momentsApi((request) async =>
        request.method == 'DELETE'
            ? deletion.future
            : http.Response(jsonEncode(json), 200,
                headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api,
            initialItem: MomentItem.fromJson(json),
            currentUsername: 'alice_id',
            onConfirmed: (item, change) async {
              expect(change, MomentDetailChange.comments);
              confirmed = item;
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('moment-comment-mine')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(confirmed, isNull);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    deletion.complete(http.Response('', 204));
    await tester.pumpAndSettle();
    expect(confirmed, isNotNull);
    expect(confirmed!.comments, isEmpty);
  });
  testWidgets('own comment exposes delete and removes it after server success',
      (tester) async {
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    json['comments'] = [
      {'id': 'mine', 'text': 'my comment', 'author': json['author']}
    ];
    String? deleted;
    final api = await fixtures.momentsApi((request) async {
      if (request.method == 'DELETE') {
        deleted = request.url.path;
        return http.Response('', 204);
      }
      return http.Response(jsonEncode(json), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(CupertinoApp(
        home: MomentDetailPage(
            api: api,
            initialItem: MomentItem.fromJson(json),
            currentUsername: 'alice_id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('moment-comment-mine')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moment-comment-input')), findsNothing);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deleted, endsWith('/moments/m1/comments/mine'));
    expect(find.byKey(const ValueKey('moment-comment-mine')), findsNothing);
  });
  test(
      'image-only reply sends upload references and parses thumbnail cache keys',
      () async {
    Map<String, dynamic>? body;
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    final api = await fixtures.momentsApi((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
          jsonEncode({
            'id': 'pic',
            'text': '',
            'author': json['author'],
            'image_urls': ['https://example.com/signed'],
            'image_cache_keys': ['stable']
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final response = await api.commentMoment('m1', '',
        parentId: 'parent', imageUploadIds: ['upload1']);
    expect(body?['image_upload_ids'], ['upload1']);
    expect(body?['parent_id'], 'parent');
    final comment = MomentCommentView.fromJson(response);
    expect(comment.images.single, 'https://example.com/signed');
    expect(comment.imageCacheKeys.single, 'stable');
  });
  testWidgets(
      'detail shows cached content immediately and submits emoji reply with parent',
      (tester) async {
    Map<String, dynamic>? submitted;
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    final comment = {'id': 'c1', 'text': 'hello', 'author': json['author']};
    json['comments'] = [comment];
    final api = await fixtures.momentsApi((request) async {
      if (request.method == 'POST') {
        submitted = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
            jsonEncode({...comment, 'id': 'c2', 'text': submitted!['text']}),
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
    expect(find.text('朋友圈正文'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('moment-comment-c1')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), '😀回复');
    await tester.pump();
    expect(find.text('回复 项目小爱'), findsOneWidget);
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    await tester.pumpAndSettle();
    expect(submitted?['parent_id'], 'c1');
    expect(submitted?['text'], '😀回复');
  });
}
