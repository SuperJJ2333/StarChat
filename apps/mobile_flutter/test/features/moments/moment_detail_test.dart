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
  testWidgets('refresh arriving before comment acknowledgment does not duplicate it', (tester) async {
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    final comment = {'id': 'new', 'text': 'hello', 'author': json['author']};
    final get = Completer<http.Response>();
    final post = Completer<http.Response>();
    final api = await fixtures.momentsApi((r) => r.method == 'POST' ? post.future : get.future);
    await tester.pumpWidget(CupertinoApp(home: MomentDetailPage(api: api,
      initialItem: MomentItem.fromJson(json), currentUsername: 'me')));
    await tester.tap(find.byKey(const Key('moment-comment-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('moment-comment-input')), 'hello');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    get.complete(http.Response(jsonEncode({...json, 'comments': [comment]}), 200,
      headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pump(const Duration(milliseconds: 200));
    post.complete(http.Response(jsonEncode(comment), 200,
      headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('moment-comment-new')), findsOneWidget);
  });
  test('renewed signed URLs share image identity only within an account', () {
    final first = momentImageProvider('https://example.com/media/old', 'object1', 'alice');
    final renewed = momentImageProvider('https://example.com/media/new', 'object1', 'alice');
    expect(first, renewed);
    expect(first, isNot(momentImageProvider('https://example.com/media/new', 'object1', 'bob')));
    expect(first, isNot(momentImageProvider('https://example.com/media/new', 'object2', 'alice')));
  });
  testWidgets('own comment exposes delete and removes it after server success', (tester) async {
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    json['comments'] = [{'id': 'mine', 'text': 'my comment', 'author': json['author']}];
    String? deleted;
    final api = await fixtures.momentsApi((request) async {
      if (request.method == 'DELETE') { deleted = request.url.path; return http.Response('', 204); }
      return http.Response(jsonEncode(json), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(CupertinoApp(home: MomentDetailPage(api: api,
      initialItem: MomentItem.fromJson(json), currentUsername: 'alice_id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('moment-comment-mine')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moment-comment-input')), findsNothing);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deleted, endsWith('/moments/m1/comments/mine'));
    expect(find.byKey(const ValueKey('moment-comment-mine')), findsNothing);
  });
  test('image-only reply sends upload references and parses thumbnail cache keys', () async {
    Map<String, dynamic>? body;
    final json = fixtures.momentJson(liked: false, likeCount: 0);
    final api = await fixtures.momentsApi((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'id': 'pic', 'text': '', 'author': json['author'],
        'image_urls': ['https://example.com/signed'], 'image_cache_keys': ['stable']}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final response = await api.commentMoment('m1', '', parentId: 'parent', imageUploadIds: ['upload1']);
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
