import 'dart:async';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:liuhetong_mobile/ui/moments/moment_media_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/moments/moments_page.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final class _ProfileStore implements ProfileStore {
  @override
  Future<ProfileSnapshot?> read(String accountKey) async => null;
  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {}
}

Map<String, dynamic> _author(String id, String name) => {
      'user_id': id,
      'username': id,
      'nickname': name,
      'display_name': name,
    };
Map<String, dynamic> _feed({String text = 'cached post', bool liked = false}) =>
    {
      'items': [
        {
          'id': 'post-1',
          'author': _author('friend', 'Friend'),
          'text': text,
          'image_urls': <String>[],
          'created_at': '2026-09-09T00:00:00Z',
          'viewer_has_liked': liked,
          'like_count': liked ? 2 : 1,
          'like_users': [
            _author('other', 'Other'),
            if (liked) _author('me', 'My name')
          ],
          'comments': <Object>[],
        }
      ],
    };

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Future<(BusinessApiClient, ProfileRepository)> _client(
  Future<http.Response> Function(http.Request) handler, {
  String? matrixId = '@me:test',
  String account = 'matrix:@me:test',
  bool hasBusinessIdentity = true,
  bool hasSession = true,
}) async {
  final session = SecureSessionStore(_MemoryStore());
  final claims = base64Url.encode(utf8.encode(jsonEncode({'sub': 'me'})));
  if (hasSession) {
    await session.saveSession(
        accessToken:
            hasBusinessIdentity ? 'header.$claims.signature' : 'opaque',
        refreshToken: 'refresh',
        matrixUserId: matrixId);
  }
  final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: session,
      client: MockClient(handler));
  final identity =
      ProfileRepository.forTesting(accountKey: account, store: _ProfileStore())
        ..profile = const ProfileData(
            username: 'me',
            nickname: 'My name',
            maskedEmail: '',
            fallbackSeed: 'me');
  identity.contacts = const [
    ContactSummary(
        userId: 'other',
        username: 'other',
        matrixUserId: '@other:test',
        nickname: 'Other'),
    ContactSummary(
        userId: 'friend',
        username: 'friend',
        matrixUserId: '@friend:test',
        nickname: 'Friend'),
  ];
  return (api, identity);
}

Widget _defaultPage((BusinessApiClient, ProfileRepository) client) =>
    CupertinoApp(home: MomentsPage(api: client.$1, identityCache: client.$2));

Future<Widget> _page((BusinessApiClient, ProfileRepository) client) async =>
    CupertinoApp(
        home: await MomentsPage.prepare(
            api: client.$1, identityCache: client.$2));

void main() {
  testWidgets('local pagination does not wait for pending head refresh',
      (tester) async {
    final cache =
        (await CacheRepository.instance()).momentsFor('matrix:@me:test');
    await cache.saveHead({..._feed(), 'next_cursor': 'older'});
    await cache.savePage(
        'older',
        {
          'items': [
            {
              ...(_feed(text: 'local older')['items'] as List).single as Map,
              'id': 'post-2'
            }
          ]
        },
        ticket: cache.currentRevision,
        expectedGeneration: 0);
    final pending = Completer<http.Response>();
    final client = await _client((request) async {
      if (request.url.path.endsWith('/feed')) {
        if (request.url.queryParameters['cursor'] == null) {
          return pending.future;
        }
        throw StateError('offline');
      }
      return _json({});
    });
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moments-load-more')));
    await tester.pumpAndSettle();
    expect(find.text('local older'), findsOneWidget);
    pending.complete(_json({}, 503));
    await tester.pumpAndSettle();
    expect(find.text('local older'), findsOneWidget);
  });

  testWidgets('browsed older page survives offline reentry', (tester) async {
    var offline = false;
    final client = await _client((request) async {
      if (request.url.path.endsWith('/feed')) {
        if (offline) throw StateError('offline');
        if (request.url.queryParameters['cursor'] != null) {
          return _json({
            'items': [
              {
                ...(_feed(text: 'persisted older post')['items'] as List).single
                    as Map,
                'id': 'post-2'
              }
            ],
            'next_cursor': null
          });
        }
        return _json({..._feed(), 'next_cursor': 'older'});
      }
      return _json({});
    });
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moments-load-more')));
    await tester.pumpAndSettle();
    expect(find.text('persisted older post'), findsOneWidget);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    offline = true;
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moments-load-more')));
    await tester.pumpAndSettle();
    expect(find.text('persisted older post'), findsOneWidget);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
  });

  for (final initiallyLiked in [false, true]) {
    testWidgets(
        'detail ${initiallyLiked ? 'unlike' : 'like'} updates names in feed and disk',
        (tester) async {
      var liked = initiallyLiked;
      final client = await _client((request) async {
        if (request.url.path.endsWith('/likes')) {
          liked = request.method != 'DELETE';
          return _json({});
        }
        if (request.url.path.endsWith('/feed')) {
          return _json(_feed(liked: liked));
        }
        if (request.url.path.endsWith('/post-1')) {
          return _json((_feed(liked: liked)['items'] as List).single);
        }
        return _json({});
      });
      await tester.pumpWidget(await _page(client));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cached post'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('moment-like-button')));
      await tester.pumpAndSettle();
      final expected = ['other', if (!initiallyLiked) 'me'];
      expect(
          tester
              .widget<WeChatMomentTile>(find.byType(WeChatMomentTile))
              .item
              .likeUsers
              .map((u) => u.userId),
          expected);
      Navigator.of(tester.element(find.byType(WeChatMomentTile))).pop();
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<WeChatMomentTile>(find.byType(WeChatMomentTile))
              .item
              .likeUsers
              .map((u) => u.userId),
          expected);
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
      await CacheRepository.resetForTest();
      final disk = (await (await CacheRepository.instance())
          .momentsFor('matrix:@me:test')
          .load())!;
      final stored = (disk['items'] as List).single as Map;
      expect(stored['viewer_has_liked'], !initiallyLiked);
      expect((stored['like_users'] as List).map((u) => (u as Map)['user_id']),
          expected);
    });
  }

  testWidgets(
      'successful comment survives overlapping failed like without caching the pending like',
      (tester) async {
    final like = Completer<http.Response>();
    final comment = Completer<http.Response>();
    final client = await _client((request) async {
      if (request.url.path.endsWith('/feed')) return _json(_feed());
      if (request.url.path.endsWith('/likes')) return like.future;
      if (request.url.path.endsWith('/comments')) return comment.future;
      return _json({});
    });
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), 'confirmed comment');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    comment.complete(_json({
      'id': 'comment-1',
      'text': 'confirmed comment',
      'author': _author('me', 'My name')
    }, 201));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<WeChatMomentTile>(find.byType(WeChatMomentTile))
            .item
            .comments
            .map((value) => value.text),
        ['confirmed comment'],
        reason: 'The comment must be acknowledged before failing the like');
    final during = (await (await CacheRepository.instance())
        .momentsFor('matrix:@me:test')
        .load())!;
    final pendingCacheItem = (during['items'] as List).single as Map;
    like.complete(_json({
      'error': {'code': 'FAIL', 'message': 'Try again'}
    }, 503));
    await tester.pumpAndSettle();
    final item =
        tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).item;
    expect(item.comments.map((value) => value.text), ['confirmed comment']);
    expect(item.liked, isFalse);
    expect(item.likeCount, 1);
    expect(item.likeUsers.map((author) => author.userId), ['other']);
    expect(pendingCacheItem['viewer_has_liked'], isFalse,
        reason: 'Comment acknowledgement cannot persist an unconfirmed like');
    await CacheRepository.resetForTest();
    final disk = (await (await CacheRepository.instance())
        .momentsFor('matrix:@me:test')
        .load())!;
    final stored = (disk['items'] as List).single as Map;
    expect(stored['viewer_has_liked'], isFalse);
    expect(stored['like_count'], 1);
    expect((stored['like_users'] as List).map((v) => (v as Map)['user_id']),
        ['other']);
    expect((stored['comments'] as List).single['text'], 'confirmed comment');
  });

  testWidgets(
      'successful image reply survives overlapping failed like without caching the pending like',
      (tester) async {
    final like = Completer<http.Response>();
    final comment = Completer<http.Response>();
    final client = await _client((request) async {
      if (request.url.path.endsWith('/feed')) return _json(_feed());
      if (request.url.path.endsWith('/likes')) return like.future;
      if (request.url.path.endsWith('/comments')) return comment.future;
      return _json({});
    });
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), 'confirmed comment');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    comment.complete(_json({
      'id': 'comment-1',
      'text': 'confirmed comment',
      'author': _author('me', 'My name'),
      'parent_author': _author('other', 'Other'),
      'image_urls': ['https://example.com/image-comment'],
      'image_cache_keys': ['a' * 64]
    }, 201));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<WeChatMomentTile>(find.byType(WeChatMomentTile))
            .item
            .comments
            .map((value) => value.text),
        ['confirmed comment'],
        reason: 'The comment must be acknowledged before failing the like');
    final during = (await (await CacheRepository.instance())
        .momentsFor('matrix:@me:test')
        .load())!;
    final pendingCacheItem = (during['items'] as List).single as Map;
    like.complete(_json({
      'error': {'code': 'FAIL', 'message': 'Try again'}
    }, 503));
    await tester.pumpAndSettle();
    final item =
        tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).item;
    expect(item.comments.map((value) => value.text), ['confirmed comment']);
    expect(item.liked, isFalse);
    expect(item.likeCount, 1);
    expect(item.likeUsers.map((author) => author.userId), ['other']);
    expect(pendingCacheItem['viewer_has_liked'], isFalse,
        reason: 'Comment acknowledgement cannot persist an unconfirmed like');
    await CacheRepository.resetForTest();
    final disk = (await (await CacheRepository.instance())
        .momentsFor('matrix:@me:test')
        .load())!;
    final stored = (disk['items'] as List).single as Map;
    expect(stored['viewer_has_liked'], isFalse);
    expect(stored['like_count'], 1);
    expect((stored['like_users'] as List).map((v) => (v as Map)['user_id']),
        ['other']);
    expect((stored['comments'] as List).single['text'], 'confirmed comment');
    final reply = (stored['comments'] as List).single as Map;
    expect(reply['image_urls'], ['https://example.com/image-comment']);
    expect(reply['image_cache_keys'], ['a' * 64]);
    expect((reply['parent_author'] as Map)['user_id'], 'other');
  });

  for (final actual in ['@b:test', null]) {
    testWidgets(
        'unprepared page never paints stale A cache when API account is $actual',
        (tester) async {
      await (await CacheRepository.instance())
          .momentsFor('matrix:@me:test')
          .save(_feed(text: 'private account A'));
      final pending = Completer<http.Response>();
      final client = await _client(
          (request) async =>
              request.url.path.endsWith('/feed') ? pending.future : _json({}),
          matrixId: actual,
          hasSession: actual != null);
      await tester.pumpWidget(_defaultPage(client));
      expect(find.text('private account A'), findsNothing);
      pending.complete(_json(_feed(text: 'authorized result')));
      await tester.pumpAndSettle();
      expect(find.text('private account A'), findsNothing);
      if (actual == '@b:test') {
        expect(find.text('账号已切换，请重新进入朋友圈'), findsOneWidget);
        final corrected = await _client(
            (request) async => request.url.path.endsWith('/feed')
                ? _json({
                    'error': {'code': 'FAIL', 'message': 'Retry'}
                  }, 503)
                : _json({}),
            matrixId: actual,
            account: 'matrix:$actual');
        await tester.pumpWidget(_defaultPage(corrected));
        await tester.pumpAndSettle();
        expect(find.text('账号已切换，请重新进入朋友圈'), findsNothing);
        expect(find.byKey(const Key('moments-initial-retry')), findsOneWidget);
      }
    });
  }

  testWidgets(
      'cover preferences survive reentry while their refresh is pending',
      (tester) async {
    var reentered = false;
    final pending = Completer<http.Response>();
    const cover =
        'https://business.example/api/v1/profile/avatar/content/account-cover';
    const coverKey =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final client = await _client((request) async {
      if (request.url.path.endsWith('/feed')) return _json(_feed());
      return reentered
          ? pending.future
          : _json({'cover_url': cover, 'cover_cache_key': coverKey});
    });
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    reentered = true;
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    await tester.pumpWidget(await _page(client));
    final header = tester.widget<Container>(find
        .descendant(
            of: find.byKey(const Key('moment-cover-header')),
            matching: find.byType(Container))
        .first);
    expect((header.decoration as BoxDecoration).image!.image.toString(),
        contains(cover));
    expect(
        ((header.decoration as BoxDecoration).image!.image
                as CachedNetworkImageProvider)
            .cacheKey,
        MomentMediaCache.imageProvider(cover,
                cacheKey: coverKey,
                accountKey: 'matrix:@me:test',
                trustedOrigin: 'https://business.example')
            .cacheKey);
    pending.complete(_json({'cover_url': cover, 'cover_cache_key': coverKey}));
    await tester.pumpAndSettle();
  });

  testWidgets('settings never echoes response-only cover cache identity',
      (tester) async {
    Map<String, dynamic>? written;
    final client = await _client((request) async {
      if (request.method == 'PUT') {
        written = jsonDecode(request.body) as Map<String, dynamic>;
      }
      return _json({
        'history_range': 'ALL',
        'personalized_recommendations': true,
        'cover_url': 'https://example.test/cover',
        'cover_cache_key': 'opaque-read-only'
      });
    });
    await tester
        .pumpWidget(CupertinoApp(home: MomentsSettingsPage(api: client.$1)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近一个月'));
    await tester.pumpAndSettle();
    expect(written, {
      'history_range': 'ONE_MONTH',
      'personalized_recommendations': true,
      'profile_entry_enabled': true,
      'excluded_user_ids': []
    });
  });

  testWidgets(
      'older page request finishing last cannot overwrite newer cached feed',
      (tester) async {
    final repository = await CacheRepository.instance();
    await repository.momentsFor('matrix:@me:test').save(_feed());
    final old = Completer<http.Response>();
    var requests = 0;
    final client = await _client((request) async {
      if (request.url.path.endsWith('/feed')) {
        return ++requests == 1 ? old.future : _json(_feed(text: 'newest post'));
      }
      return _json({});
    });
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    expect(find.text('newest post'), findsOneWidget);
    old.complete(_json(_feed(text: 'stale post')));
    await tester.pumpAndSettle();
    expect(find.text('newest post'), findsOneWidget);
    expect(
        (repository.momentsFor('matrix:@me:test').snapshot!['items'] as List)
            .single['text'],
        'newest post');
  });

  testWidgets(
      'missing business identity waits for authoritative names without inventing one',
      (tester) async {
    final pending = Completer<http.Response>();
    final client = await _client((request) async {
      if (request.url.path.endsWith('/feed')) return _json(_feed());
      if (request.url.path.endsWith('/likes')) return pending.future;
      if (request.url.path.endsWith('/post-1')) {
        return _json((_feed(liked: true)['items'] as List).single);
      }
      return _json({});
    }, hasBusinessIdentity: false);
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pump();
    final pendingItem =
        tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).item;
    expect(pendingItem.liked, isTrue);
    expect(pendingItem.likeCount, 1,
        reason:
            'Privacy projection counts only known visible identities until acknowledgment');
    expect(pendingItem.likeUsers.map((user) => user.userId), ['other']);
    pending.complete(_json({}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('moment-liker-other')), findsOneWidget);
    expect(find.byKey(const ValueKey('moment-liker-me')), findsOneWidget);
  });

  testWidgets('liking a loaded older page preserves all currently loaded posts',
      (tester) async {
    final client = await _client((request) async {
      if (request.url.path.endsWith('/feed')) {
        if (request.url.queryParameters['cursor'] != null) {
          return _json({
            'items': [
              {
                ...(_feed(text: 'older post')['items'] as List).single as Map,
                'id': 'post-2'
              }
            ]
          });
        }
        return _json({..._feed(), 'next_cursor': 'older'});
      }
      return _json({});
    });
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moments-load-more')));
    await tester.pumpAndSettle();
    final older = find.byWidgetPredicate(
        (w) => w is WeChatMomentTile && w.item.id == 'post-2');
    await tester.ensureVisible(older);
    await tester.tap(find.descendant(
        of: older, matching: find.byKey(const Key('moment-like-button'))));
    await tester.pumpAndSettle();
    expect(find.text('older post'), findsOneWidget);
    expect(tester.widget<WeChatMomentTile>(older).item.liked, isTrue);
    expect(find.byType(WeChatMomentTile), findsNWidgets(2));
  });

  testWidgets(
      'late background refresh cannot undo a confirmed like in UI or disk',
      (tester) async {
    final cache =
        (await CacheRepository.instance()).momentsFor('matrix:@me:test');
    await cache.save(_feed());
    final pending = Completer<http.Response>();
    final client = await _client((request) async =>
        request.url.path.endsWith('/feed') ? pending.future : _json({}));
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pumpAndSettle();
    pending.complete(_json(_feed()));
    await tester.pumpAndSettle();
    final liked =
        tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).item;
    expect(liked.liked, isTrue);
    expect(liked.likeUsers.map((author) => author.userId), ['other', 'me']);
    await CacheRepository.resetForTest();
    final disk = await (await CacheRepository.instance())
        .momentsFor('matrix:@me:test')
        .load();
    final stored = (disk!['items'] as List).single as Map;
    expect(stored['viewer_has_liked'], isTrue);
    expect(
        (stored['like_users'] as List).map((user) => (user as Map)['user_id']),
        ['other', 'me']);
  });

  testWidgets('failed unlike restores own name and count', (tester) async {
    final pending = Completer<http.Response>();
    final client = await _client((request) async {
      if (request.url.path.endsWith('/feed')) return _json(_feed(liked: true));
      if (request.url.path.endsWith('/likes')) return pending.future;
      return _json({});
    });
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pump();
    expect(find.byKey(const ValueKey('moment-liker-other')), findsOneWidget);
    pending.complete(_json({
      'error': {'code': 'FAIL', 'message': 'Try again'}
    }, 503));
    await tester.pumpAndSettle();
    final restored =
        tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).item;
    expect(restored.liked, isTrue);
    expect(restored.likeCount, 2);
    expect(restored.likeUsers.map((author) => author.userId), ['other', 'me']);
  });

  testWidgets('replacing the page account never retains the previous feed',
      (tester) async {
    final repository = await CacheRepository.instance();
    await repository
        .momentsFor('matrix:@me:test')
        .save(_feed(text: 'account A'));
    await repository
        .momentsFor('matrix:@b:test')
        .save(_feed(text: 'account B'));
    final pendingA = Completer<http.Response>();
    final pendingB = Completer<http.Response>();
    final a = await _client((r) async =>
        r.url.path.endsWith('/feed') ? pendingA.future : _json({}));
    final b = await _client(
        (r) async => r.url.path.endsWith('/feed') ? pendingB.future : _json({}),
        matrixId: '@b:test',
        account: 'matrix:@b:test');
    await tester.pumpWidget(await _page(a));
    await tester.pumpAndSettle();
    expect(find.text('account A'), findsOneWidget);
    await tester.pumpWidget(await _page(b));
    expect(find.text('account A'), findsNothing);
    expect(find.text('account B'), findsOneWidget);
    pendingA.complete(_json(_feed(text: 'late account A')));
    pendingB.complete(_json(_feed(text: 'fresh account B')));
    await tester.pumpAndSettle();
    expect(find.text('fresh account B'), findsOneWidget);
    expect(find.text('late account A'), findsNothing);
  });

  testWidgets(
      'account cached feed is present on first frame while network waits',
      (tester) async {
    await (await CacheRepository.instance())
        .momentsFor('matrix:@me:test')
        .save(_feed());
    final pending = Completer<http.Response>();
    final client = await _client((request) async =>
        request.url.path.endsWith('/feed')
            ? pending.future
            : _json({'cover_url': null}));
    await tester.pumpWidget(await _page(client));
    expect(find.text('cached post'), findsOneWidget);
    pending.complete(_json(_feed(text: 'fresh post')));
    await tester.pumpAndSettle();
    expect(find.text('fresh post'), findsOneWidget);
  });

  testWidgets('optimistic like adds own name and rollback restores list',
      (tester) async {
    final pending = Completer<http.Response>();
    final client = await _client((request) async {
      if (request.url.path.endsWith('/feed')) return _json(_feed());
      if (request.url.path.endsWith('/likes')) return pending.future;
      return _json({'cover_url': null});
    });
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pump();
    final optimistic =
        tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).item;
    expect(
        optimistic.likeUsers.map((author) => author.userId), ['other', 'me']);
    expect(find.byKey(const ValueKey('moment-liker-other')), findsOneWidget);
    expect(find.byKey(const ValueKey('moment-liker-me')), findsOneWidget);
    pending.complete(_json({
      'error': {'code': 'FAIL', 'message': 'Try again'}
    }, 503));
    await tester.pumpAndSettle();
    final reverted =
        tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).item;
    expect(reverted.liked, isFalse);
    expect(reverted.likeCount, 1);
    expect(reverted.likeUsers.map((author) => author.userId), ['other']);
  });

  testWidgets('successful unlike removes own name and survives reentry',
      (tester) async {
    var refresh = false;
    final pending = Completer<http.Response>();
    final client = await _client((request) async {
      if (request.url.path.endsWith('/feed')) {
        return refresh ? pending.future : _json(_feed(liked: true));
      }
      return _json({});
    });
    await tester.pumpWidget(await _page(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pumpAndSettle();
    final unliked =
        tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).item;
    expect(unliked.likeUsers.map((author) => author.userId), ['other']);
    refresh = true;
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    await tester.pumpWidget(await _page(client));
    final reopened =
        tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).item;
    expect(reopened.liked, isFalse);
    expect(reopened.likeCount, 1);
    expect(reopened.likeUsers.map((author) => author.userId), ['other']);
    pending.complete(_json(_feed()));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'unknown authenticated identity never paints shared anonymous feed',
      (tester) async {
    await (await CacheRepository.instance())
        .momentsFor('anonymous')
        .save(_feed(text: 'private other account'));
    final pending = Completer<http.Response>();
    final client = await _client(
        (request) async =>
            request.url.path.endsWith('/feed') ? pending.future : _json({}),
        matrixId: null,
        account: '');
    await tester.pumpWidget(await _page(client));
    // Initial loading animates until the pending network response completes.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('private other account'), findsNothing);
    pending.complete(_json(_feed(text: 'authorized result')));
    await tester.pumpAndSettle();
    expect(find.text('authorized result'), findsOneWidget);
  });
}
