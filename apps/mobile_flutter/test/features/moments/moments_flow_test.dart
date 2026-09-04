import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moments_page.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_image_grid.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_viewer.dart';

final class MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Map<String, dynamic> momentJson(
        {required bool liked, required int likeCount}) =>
    {
      'id': 'm1',
      'author': {
        'user_id': 'u1',
        'username': 'alice_id',
        'nickname': 'Alice',
        'remark': '项目小爱',
        'display_name': '项目小爱',
        'avatar_url': null,
      },
      'text': '朋友圈正文',
      'image_urls': <String>[],
      'created_at': DateTime.now().toIso8601String(),
      'viewer_has_liked': liked,
      'like_count': likeCount,
      'like_users': <Map<String, dynamic>>[],
      'comments': <Map<String, dynamic>>[],
    };

Future<BusinessApiClient> momentsApi(
    Future<http.Response> Function(http.Request) handler) async {
  final store = SecureSessionStore(MemoryStore());
  await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.example'),
    sessionStore: store,
    client: MockClient(handler),
  );
}

void main() {
  setUp(() async {
    // CacheRepository 依赖 SharedPreferences；测试环境需注入 mock，
    // 否则平台通道永不返回导致 Feed 加载挂起。
    SharedPreferences.setMockInitialValues({});
    CacheRepository.resetForTest();
  });

  testWidgets('moments cover renders the signed-in nickname and avatar',
      (tester) async {
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(jsonEncode({'items': []}), 200,
            headers: {'content-type': 'application/json'});
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(jsonEncode({'cover_url': null}), 200,
            headers: {'content-type': 'application/json'});
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });
    final identityStore = MomentsIdentityStore();
    await identityStore.write(
      'matrix:@me:test',
      const ProfileSnapshot(
        profile: ProfileData(
          username: 'me-login',
          nickname: '我的昵称',
          maskedEmail: '',
          fallbackSeed: 'me-seed',
          avatarUrl: 'https://cdn.example.test/me.jpg',
        ),
        contacts: [],
      ),
    );
    final identityCache = ProfileRepository.forTesting(
      accountKey: 'matrix:@me:test',
      store: identityStore,
    );
    await identityCache.hydrate();

    await tester.pumpWidget(CupertinoApp(
      home: MomentsPage(api: api, identityCache: identityCache),
    ));
    await tester.pumpAndSettle();

    expect(find.text('我的昵称'), findsOneWidget);
    expect(find.text('畅聊朋友圈'), findsNothing);
    final avatar = tester.widget<UserAvatar>(
      find.byKey(const Key('moment-owner-avatar')),
    );
    expect(avatar.nickname, '我的昵称');
    expect(avatar.fallbackSeed, 'me-seed');
    expect(avatar.avatarUrl, 'https://cdn.example.test/me.jpg');
    expect(avatar.diagnosticSource, 'moments-owner');
  });

  testWidgets('owner profile failure shows default avatar and retry action',
      (tester) async {
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(jsonEncode({'items': []}), 200,
            headers: {'content-type': 'application/json'});
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(jsonEncode({'cover_url': null}), 200,
            headers: {'content-type': 'application/json'});
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@me:test',
      store: MomentsIdentityStore(),
      loadProfile: () async => throw StateError('offline detail'),
      loadContacts: () async => const [],
    );

    await tester.pumpWidget(CupertinoApp(
      home: MomentsPage(api: api, identityCache: cache),
    ));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const Key('moment-owner-loading-fallback')), findsOneWidget);
    expect(find.text('资料加载失败'), findsOneWidget);
    expect(find.byKey(const Key('moment-owner-retry')), findsOneWidget);
    expect(find.textContaining('offline detail'), findsNothing);
  });

  testWidgets('moment image grid supports 1 4 and 9 images', (tester) async {
    for (final count in [1, 4, 9]) {
      await tester.pumpWidget(CupertinoApp(
          home: WeChatMomentImageGrid(
              imageUrls: List.generate(count, (i) => 'invalid://$i'))));
      expect(find.byKey(const ValueKey('moment-image')), findsNWidgets(count));
    }
  });

  testWidgets(
      'moments has one feed and likes optimistically before API success',
      (tester) async {
    final likeResponse = Completer<http.Response>();
    var serverLiked = false;
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(
          jsonEncode({
            'items': [
              momentJson(liked: serverLiked, likeCount: serverLiked ? 3 : 2)
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(
          jsonEncode({
            'history_range': 'ALL',
            'personalized_recommendations': true,
            'cover_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/m1/likes' &&
          request.method == 'POST') {
        final response = await likeResponse.future;
        serverLiked = true;
        return response;
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });

    await tester.pumpWidget(CupertinoApp(
      home: MomentsPage(
          api: api,
          identityCache: ProfileRepository.forTesting(
              accountKey: 'matrix:@me:test', store: MomentsIdentityStore())),
    ));
    await tester.pumpAndSettle();
    expect(find.text('推荐'), findsNothing);
    expect(find.text('最新'), findsNothing);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pump();
    expect(find.byIcon(CupertinoIcons.heart_fill), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    likeResponse.complete(http.Response(
      jsonEncode({'id': 'like-1'}),
      201,
      headers: {'content-type': 'application/json'},
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.heart_fill), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('failed optimistic like rolls back and shows API error',
      (tester) async {
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(
          jsonEncode({
            'items': [momentJson(liked: false, likeCount: 2)]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(
          jsonEncode({
            'history_range': 'ALL',
            'personalized_recommendations': true,
            'cover_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/m1/likes') {
        return http.Response(
          jsonEncode({
            'error': {'code': 'MOMENT_LIKE_FAILED', 'message': '点赞同步失败'}
          }),
          503,
          headers: {'content-type': 'application/json'},
        );
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });

    await tester.pumpWidget(CupertinoApp(
      home: MomentsPage(
          api: api,
          identityCache: ProfileRepository.forTesting(
              accountKey: 'matrix:@me:test', store: MomentsIdentityStore())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-like-button')));
    await tester.pumpAndSettle();

    expect(find.byIcon(CupertinoIcons.heart), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('点赞同步失败'), findsOneWidget);
  });

  testWidgets('comment button submits and immediately renders returned comment',
      (tester) async {
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(
          jsonEncode({
            'items': [momentJson(liked: false, likeCount: 0)]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(
          jsonEncode({
            'history_range': 'ALL',
            'personalized_recommendations': true,
            'cover_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/m1/comments') {
        expect(jsonDecode(request.body)['text'], '即时评论');
        return http.Response(
          jsonEncode({
            'id': 'c1',
            'user_id': 'u2',
            'parent_id': null,
            'text': '即时评论',
            'created_at': DateTime.now().toIso8601String(),
            'author': {
              'user_id': 'u2',
              'username': 'bob_id',
              'nickname': 'Bob',
              'remark': '项目小波',
              'display_name': '项目小波',
              'avatar_url': null,
            },
            'parent_author': null,
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });

    await tester.pumpWidget(CupertinoApp(
      home: MomentsPage(
          api: api,
          identityCache: ProfileRepository.forTesting(
              accountKey: 'matrix:@me:test', store: MomentsIdentityStore())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-comment-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), '即时评论');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    await tester.pumpAndSettle();

    expect(find.text('项目小波：即时评论'), findsOneWidget);
  });

  testWidgets('failed comment keeps draft and shows server error',
      (tester) async {
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(
          jsonEncode({
            'items': [momentJson(liked: false, likeCount: 0)]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(
          jsonEncode({
            'history_range': 'ALL',
            'personalized_recommendations': true,
            'cover_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/m1/comments') {
        return http.Response(
          jsonEncode({
            'error': {'code': 'COMMENT_FAILED', 'message': '评论提交失败'}
          }),
          503,
          headers: {'content-type': 'application/json'},
        );
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });

    await tester.pumpWidget(CupertinoApp(
      home: MomentsPage(
          api: api,
          identityCache: ProfileRepository.forTesting(
              accountKey: 'matrix:@me:test', store: MomentsIdentityStore())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-comment-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), '保留这条评论');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    await tester.pumpAndSettle();

    expect(find.text('评论提交失败'), findsOneWidget);
    expect(find.text('保留这条评论'), findsOneWidget);
  });

  testWidgets('cover opens full screen viewer with bottom-right change action',
      (tester) async {
    final api = await momentsApi((request) async {
      if (request.url.path == '/api/v1/moments/feed') {
        return http.Response(
          jsonEncode({'items': <Map<String, dynamic>>[]}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/moments/preferences') {
        return http.Response(
          jsonEncode({
            'history_range': 'ALL',
            'personalized_recommendations': true,
            'cover_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    });

    await tester.pumpWidget(CupertinoApp(
      home: MomentsPage(
          api: api,
          identityCache: ProfileRepository.forTesting(
              accountKey: 'matrix:@me:test', store: MomentsIdentityStore())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-cover-header')));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byKey(const Key('moment-change-cover')), findsOneWidget);
    expect(find.text('换封面'), findsOneWidget);
  });

  testWidgets('selected cover is previewed before persistence completes',
      (tester) async {
    final persisted = Completer<String?>();
    final pixel = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');

    await tester.pumpWidget(CupertinoApp(
      home: WeChatMomentCoverViewer(
        url: null,
        onChangeCover: (onPreview) {
          onPreview(pixel);
          return persisted.future;
        },
      ),
    ));

    await tester.tap(find.byKey(const Key('moment-change-cover')));
    await tester.pump();

    expect(find.byKey(const Key('moment-cover-local-preview')), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

    persisted.complete('https://media.example.test/covers/current.png');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moment-cover-local-preview')), findsNothing);
  });

  Future<(BusinessApiClient, ProfileRepository)> pumpMomentsWithViewer(
    WidgetTester tester,
    String viewerUsername, {
    required Future<http.Response> Function(http.Request) handler,
  }) async {
    final api = await momentsApi(handler);
    final identityStore = MomentsIdentityStore();
    await identityStore.write(
      'matrix:@me:test',
      ProfileSnapshot(
        profile: ProfileData(
          username: viewerUsername,
          nickname: viewerUsername,
          maskedEmail: '',
          fallbackSeed: 'seed',
          avatarUrl: null,
        ),
        contacts: [],
      ),
    );
    final identityCache = ProfileRepository.forTesting(
      accountKey: 'matrix:@me:test',
      store: identityStore,
    );
    await identityCache.hydrate();
    await tester.pumpWidget(CupertinoApp(
      home: MomentsPage(api: api, identityCache: identityCache),
    ));
    await tester.pumpAndSettle();
    return (api, identityCache);
  }

  http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  testWidgets('delete entry is visible only to the moment author',
      (tester) async {
    await pumpMomentsWithViewer(
      tester,
      'someone-else',
      handler: (request) async {
        if (request.url.path == '/api/v1/moments/feed') {
          return jsonResponse({'items': [momentJson(liked: false, likeCount: 0)]});
        }
        if (request.url.path == '/api/v1/moments/preferences') {
          return jsonResponse({'cover_url': null});
        }
        throw StateError('Unexpected: ${request.method} ${request.url}');
      },
    );
    // 非作者（作者 username 是 alice_id）看不到删除入口。
    expect(find.byKey(const Key('moment-delete-button')), findsNothing);
  });

  testWidgets('author sees delete entry; cancel keeps the moment',
      (tester) async {
    await pumpMomentsWithViewer(
      tester,
      'alice_id',
      handler: (request) async {
        if (request.url.path == '/api/v1/moments/feed') {
          return jsonResponse({'items': [momentJson(liked: false, likeCount: 0)]});
        }
        if (request.url.path == '/api/v1/moments/preferences') {
          return jsonResponse({'cover_url': null});
        }
        throw StateError('Unexpected: ${request.method} ${request.url}');
      },
    );
    expect(find.byKey(const Key('moment-delete-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('moment-delete-button')));
    await tester.pumpAndSettle();
    expect(find.text('删除这条朋友圈？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('朋友圈正文'), findsOneWidget);
  });

  testWidgets('delete removes the moment optimistically and syncs the cache',
      (tester) async {
    final deleted = Completer<void>();
    await pumpMomentsWithViewer(
      tester,
      'alice_id',
      handler: (request) async {
        if (request.url.path == '/api/v1/moments/feed') {
          return jsonResponse({'items': [momentJson(liked: false, likeCount: 0)]});
        }
        if (request.url.path == '/api/v1/moments/preferences') {
          return jsonResponse({'cover_url': null});
        }
        if (request.method == 'DELETE' && request.url.path == '/api/v1/moments/m1') {
          await deleted.future;
          return jsonResponse({});
        }
        throw StateError('Unexpected: ${request.method} ${request.url}');
      },
    );

    await tester.tap(find.byKey(const Key('moment-delete-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-delete-confirm')));
    await tester.pump();
    // 乐观删除：API 未返回前条目已消失。
    expect(find.text('朋友圈正文'), findsNothing);

    deleted.complete();
    await tester.pumpAndSettle();
    expect(find.text('朋友圈正文'), findsNothing);
    // 成功后缓存同步：不再把已删条目画回来。
    final cached = await (await CacheRepository.instance()).moments.load();
    expect(
      (cached?['items'] as List?)
              ?.any((m) => (m as Map)['id']?.toString() == 'm1') ??
          false,
      isFalse,
      reason: '删除成功后必须同步磁盘缓存',
    );
  });

  testWidgets('failed delete rolls the moment back with the server error',
      (tester) async {
    final failed = Completer<void>();
    await pumpMomentsWithViewer(
      tester,
      'alice_id',
      handler: (request) async {
        if (request.url.path == '/api/v1/moments/feed') {
          return jsonResponse({'items': [momentJson(liked: false, likeCount: 0)]});
        }
        if (request.url.path == '/api/v1/moments/preferences') {
          return jsonResponse({'cover_url': null});
        }
        if (request.method == 'DELETE' && request.url.path == '/api/v1/moments/m1') {
          await failed.future;
          return jsonResponse(
            {'error': {'code': 'X', 'message': '服务繁忙'}},
            503,
          );
        }
        throw StateError('Unexpected: ${request.method} ${request.url}');
      },
    );

    await tester.tap(find.byKey(const Key('moment-delete-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-delete-confirm')));
    await tester.pump();
    expect(find.text('朋友圈正文'), findsNothing);

    failed.complete();
    await tester.pumpAndSettle();
    // 失败回滚：条目恢复 + 服务端错误文案。
    expect(find.text('朋友圈正文'), findsOneWidget);
    expect(find.byKey(const Key('moment-interaction-error')), findsOneWidget);
    expect(find.text('服务繁忙'), findsOneWidget);
  });
}

final class MomentsIdentityStore implements ProfileStore {
  final values = <String, ProfileSnapshot>{};

  @override
  Future<ProfileSnapshot?> read(String accountKey) async => values[accountKey];

  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    values[accountKey] = snapshot;
  }
}
