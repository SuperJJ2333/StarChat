import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:liuhetong_mobile/features/moments/moment_publish_coordinator.dart';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_composer_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_image_preprocessor.dart';
import 'package:liuhetong_mobile/features/moments/moment_draft_store.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

Uint8List pngBytes() => Uint8List.fromList(const [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0A,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9C,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0D,
      0x0A,
      0x2D,
      0xB4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ]);

void main() {
  late PathProviderPlatform originalPaths;
  late Directory scratch;
  setUp(() async {
    originalPaths = PathProviderPlatform.instance;
    scratch = await Directory(
            '../../docs/verification/artifacts/2026-09-28/ios-media-room-followup/moments/legacy-composer')
        .absolute
        .create(recursive: true);
    scratch = await scratch.createTemp('case-');
    PathProviderPlatform.instance = _Paths(scratch.path);
  });
  tearDown(() async {
    for (final api in _queues) {
      await MomentPublishQueues.revoke(api);
    }
    _queues.clear();
    PathProviderPlatform.instance = originalPaths;
    // Keep synthetic fixtures under verification until platform cache handles close.
  });
  testWidgets('dark composer separates navigation from editor surface',
      (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(_MemoryStore()),
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    await tester.pumpWidget(CupertinoApp(
      theme: const CupertinoThemeData(brightness: Brightness.dark),
      home: MomentComposerPage(api: api),
    ));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CupertinoNavigationBar>(find.byType(CupertinoNavigationBar))
            .backgroundColor,
        WeChatColors.darkSurface);
    final editor = tester
        .widget<CupertinoTextField>(find.byType(CupertinoTextField).first);
    expect(editor.decoration!.color, WeChatColors.darkElevated);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('composer keeps only approved WeChat-style option rows',
      (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/moments/draft')) {
          return http.Response(jsonEncode({}), 200,
              headers: {'content-type': 'application/json'});
        }
        throw StateError('Unexpected ${request.method} ${request.url}');
      }),
    );
    await tester.pumpWidget(
      CupertinoApp(home: MomentComposerPage(api: api)),
    );
    await tester.pumpAndSettle();

    expect(find.text('这一刻的想法…'), findsOneWidget);
    expect(find.text('谁可以看'), findsOneWidget);
    expect(find.text('公开'), findsOneWidget);
    expect(find.text('添加链接'), findsOneWidget);
    expect(find.text('所在位置'), findsNothing);
    expect(find.text('提醒谁看'), findsNothing);
    expect(find.byKey(const Key('moment-compose-publish')), findsOneWidget);
    expect(find.byKey(const Key('moment-pick-images')), findsOneWidget);
  });

  testWidgets('publish failure retains text and shows a retryable error',
      (tester) async {
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(
        accessToken: 'access',
        refreshToken: 'refresh',
        matrixUserId: '@composer:example.test');
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/moments/draft') &&
            request.method == 'GET') {
          return http.Response(jsonEncode({}), 200,
              headers: {'content-type': 'application/json'});
        }
        if (request.url.path.endsWith('/moments') && request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'error': {
                'code': 'MOMENT_UNAVAILABLE',
                'message': '暂时无法发表',
              }
            }),
            503,
            headers: {'content-type': 'application/json'},
          );
        }
        throw StateError('Unexpected ${request.method} ${request.url}');
      }),
    );
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).first, '保留的内容');
    await tester.pump();
    final queue = await _publish(tester);
    expect(queue.jobs.single.state, MomentPublishState.failed);
    expect(queue.jobs.single.payload['text'], '保留的内容');
    expect(queue.jobs.single.message, '暂时无法发表');
    expect(find.byKey(const Key('moment-compose-error')), findsNothing);
  });

  testWidgets('selected images upload before publish and use remote URLs',
      (tester) async {
    final preprocessor = MomentImagePreprocessor.functional((bytes) async {
      return Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]);
    });
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(
        accessToken: 'access',
        refreshToken: 'refresh',
        matrixUserId: '@composer:example.test');
    Map<String, dynamic>? published;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/moments/draft') &&
            request.method == 'GET') {
          return http.Response(jsonEncode({}), 200,
              headers: {'content-type': 'application/json'});
        }
        if (request.url.path.endsWith('/moments/media/uploads') &&
            request.method == 'POST') {
          return http.Response(jsonEncode({'id': 'upload-1'}), 201,
              headers: {'content-type': 'application/json'});
        }
        if (request.url.path.endsWith('/uploads/upload-1/content') &&
            request.method == 'PUT') {
          // 压缩管线统一转 JPEG：MIME 与扩展名都必须归一。
          expect(request.headers['content-type'], 'image/jpeg');
          expect(request.bodyBytes, isNotEmpty);
          return http.Response('', 204);
        }
        if (request.url.path.endsWith('/uploads/upload-1/complete') &&
            request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'id': 'upload-1',
              'status': 'COMPLETED',
              'media_url': 'https://media.example.test/photo.png',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/moments') && request.method == 'POST') {
          published =
              Map<String, dynamic>.from(jsonDecode(request.body) as Map);
          return http.Response(jsonEncode({'id': 'moment-1'}), 201,
              headers: {'content-type': 'application/json'});
        }
        if (request.url.path.endsWith('/moments/draft') &&
            request.method == 'DELETE') {
          return http.Response('', 204);
        }
        throw StateError('Unexpected ${request.method} ${request.url}');
      }),
    );
    final image =
        XFile.fromData(pngBytes(), name: 'photo.png', mimeType: 'image/png');

    await tester.pumpWidget(CupertinoApp(
      home: MomentComposerPage(
        api: api,
        initialImages: [image],
        imagePreprocessor: preprocessor,
      ),
    ));
    await tester.pumpAndSettle();
    await _publish(tester);
    expect(published?['image_urls'], ['https://media.example.test/photo.png']);
  });
  testWidgets('old editor cannot admit content into a switched account',
      (tester) async {
    final session = SecureSessionStore(_MemoryStore());
    await session.saveSession(
        accessToken: 'old',
        refreshToken: 'old-refresh',
        matrixUserId: '@old:example.test');
    var publishes = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: session,
        client: MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/moments')) {
            publishes++;
          }
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).first, '旧账号编辑内容');
    await tester.pump();
    await session.saveSession(
        accessToken: 'new',
        refreshToken: 'new-refresh',
        matrixUserId: '@new:example.test');
    await tester.runAsync(
        () => tester.tap(find.byKey(const Key('moment-compose-publish'))));
    for (var i = 0;
        i < 50 &&
            find.byKey(const Key('moment-compose-error')).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pumpAndSettle();
    expect(publishes, 0);
    expect(find.text('账号已切换，请重新打开发表页面'), findsOneWidget);
  });

  testWidgets('old editor discard cannot delete switched account draft',
      (tester) async {
    final session = SecureSessionStore(_MemoryStore());
    await session.saveSession(
        accessToken: 'old',
        refreshToken: 'old-refresh',
        matrixUserId: '@old:example.test');
    var deletes = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: session,
        client: MockClient((request) async {
          if (request.method == 'DELETE' ||
              request.url.path.endsWith('/clear-if-unchanged')) {
            deletes++;
          }
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).first, 'old editor');
    await session.saveSession(
        accessToken: 'new',
        refreshToken: 'new-refresh',
        matrixUserId: '@new:example.test');
    final local = InMemoryMomentDraftStore(MomentDraftSnapshot(
        scope: 'matrix:@new:example.test',
        payload: const {'text': 'new account draft'},
        savedAt: DateTime.now()));
    MomentDraftStores.shared = local;
    await tester.tap(find.byKey(const Key('moment-compose-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不保存'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(deletes, 0);
    expect(local.read()?.payload['text'], 'new account draft');
    MomentDraftStores.reset();
  });

  testWidgets('reopened video draft passes exact GET snapshot to compare clear',
      (tester) async {
    final session = SecureSessionStore(_MemoryStore());
    await session.saveSession(
        accessToken: 'test',
        refreshToken: 'refresh',
        matrixUserId: '@a:example.test');
    const draft = {
      'text': 'saved video',
      'visibility': 'SELF',
      'image_urls': <String>[],
      'video_urls': ['https://example.test/api/v1/moments/media/video?renewed'],
      'video_poster_media_ids': ['eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee']
    };
    Map<String, dynamic>? expected;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: session,
        client: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(jsonEncode(draft), 200);
          }
          if (request.url.path.endsWith('/clear-if-unchanged')) {
            expected = Map<String, dynamic>.from(
                jsonDecode(request.body)['expected_payload'] as Map);
            return http.Response('{"cleared":true}', 200);
          }
          return http.Response('{"id":"post"}', 201);
        }));
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    await _publish(tester);
    for (var i = 0; i < 100 && expected == null; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(expected, draft);
  });

  testWidgets('non-text payload editing invalidates an admitted draft cleanup',
      (tester) async {
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    final before = MomentDraftStores.editingRevision;
    await tester.tap(find.text('添加链接'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-link-input')), 'https://example.test');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(MomentDraftStores.editingRevision, greaterThan(before));
  });

  testWidgets('delayed server draft does not replace edits made while loading',
      (tester) async {
    final started = Completer<void>();
    final draft = Completer<http.Response>();
    final session = SecureSessionStore(_MemoryStore());
    await session.saveSession(
        accessToken: 'test',
        refreshToken: 'refresh',
        matrixUserId: '@a:example.test');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: session,
        client: MockClient((request) async {
          started.complete();
          return draft.future;
        }));
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    expect(started.isCompleted, isTrue);
    await tester.enterText(
        find.byType(CupertinoTextField).first, 'new unsaved text');
    await tester.tap(find.text('添加链接'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-link-input')), 'https://example.test/new');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    draft.complete(http.Response(
        '{"text":"old server text","visibility":"SELF","image_urls":[]}', 200));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).first)
            .controller!
            .text,
        'new unsaved text');
    expect(find.text('https://example.test/new'), findsOneWidget);
    expect(find.text('公开'), findsOneWidget);
  });

  testWidgets(
      'delayed draft after account switch cannot hydrate or persist new scope',
      (tester) async {
    addTearDown(MomentDraftStores.reset);
    final started = Completer<void>();
    final draft = Completer<http.Response>();
    final session = SecureSessionStore(_MemoryStore());
    await session.saveSession(
        accessToken: 'old',
        refreshToken: 'old-refresh',
        matrixUserId: '@old:example.test');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: session,
        client: MockClient((request) async {
          started.complete();
          return draft.future;
        }));
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    expect(started.isCompleted, isTrue);
    await session.saveSession(
        accessToken: 'new',
        refreshToken: 'new-refresh',
        matrixUserId: '@new:example.test');
    final local = InMemoryMomentDraftStore(MomentDraftSnapshot(
        scope: 'matrix:@new:example.test',
        payload: const {'text': 'new account draft'},
        savedAt: DateTime.now()));
    MomentDraftStores.shared = local;
    draft.complete(http.Response(
        '{"text":"old account server draft","image_urls":[]}', 200));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).first)
            .controller!
            .text,
        isEmpty);
    expect(local.read()?.scope, 'matrix:@new:example.test');
    expect(local.read()?.payload['text'], 'new account draft');
  });

  testWidgets('missing draft is treated as an empty composer', (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/moments/draft')) {
          return http.Response(
            jsonEncode({
              'error': {'code': 'MOMENT_DRAFT_NOT_FOUND', 'message': '草稿不存在'}
            }),
            404,
            headers: {'content-type': 'application/json'},
          );
        }
        throw StateError('Unexpected ${request.method} ${request.url}');
      }),
    );
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('moment-compose-error')), findsNothing);
    expect(find.text('这一刻的想法…'), findsOneWidget);
  });
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final _queues = <BusinessApiClient>[];
Future<MomentPublishCoordinator> _publish(WidgetTester tester) async {
  final api =
      tester.widget<MomentComposerPage>(find.byType(MomentComposerPage)).api;
  _queues.add(api);
  final queue = await tester.runAsync(() => MomentPublishQueues.open(api));
  await tester.runAsync(
      () => tester.tap(find.byKey(const Key('moment-compose-publish'))));
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (queue!.jobs.isNotEmpty &&
        !queue.jobs.any((j) =>
            j.state == MomentPublishState.queued ||
            j.state == MomentPublishState.uploading)) {
      break;
    }
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
  await tester.pumpAndSettle();
  return queue!;
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String> getApplicationDocumentsPath() async => root;
  @override
  Future<String> getTemporaryPath() async => root;
}
