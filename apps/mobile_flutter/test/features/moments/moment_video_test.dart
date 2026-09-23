import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_composer_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';
import 'package:liuhetong_mobile/features/matrix/gallery_video_preview.dart';

void main() {
  testWidgets('pending upload disables attachment deletion', (tester) async {
    final uploaded = Completer<void>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/media/uploads'))
            return http.Response('{"id":"pending"}', 201);
          if (request.method == 'PUT') {
            await uploaded.future;
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/complete'))
            return http.Response(
                '{"media_url":"media://moments/u/video.mp4"}', 200);
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(api: api, initialImages: [
      XFile.fromData(Uint8List.fromList([1, 2, 3]),
          name: 'video.mp4', mimeType: 'video/mp4')
    ])));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pump();
    final buttons = find.ancestor(
        of: find.byIcon(CupertinoIcons.clear_circled_solid),
        matching: find.byType(CupertinoButton));
    expect(buttons, findsOneWidget);
    expect(tester.widget<CupertinoButton>(buttons).onPressed, isNull);
    uploaded.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('gallery photo with missing thumbnail uses loaded image bytes',
      (tester) async {
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(
            api: api,
            galleryPicker: (_, __) async => (
                  photos: [
                    GalleryPhoto(
                        id: 'photo',
                        thumbnail: Uint8List(0),
                        mimeType: 'image/png',
                        originalBytes: () async => png,
                        compressedBytes: () async => png)
                  ],
                  original: true,
                  flash: false
                ))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-pick-images')));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'pending gallery bytes lock publish until selected media is ready',
      (tester) async {
    final bytes = Completer<Uint8List>();
    var publishes = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((request) async {
          if (request.method == 'POST') publishes++;
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(
            api: api,
            galleryPicker: (_, __) async => (
                  photos: [
                    GalleryPhoto(
                        id: 'slow',
                        thumbnail: Uint8List(0),
                        isVideo: true,
                        mimeType: 'video/mp4',
                        originalBytes: () => bytes.future,
                        compressedBytes: () => bytes.future)
                  ],
                  original: true,
                  flash: false
                ))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).first, 'message');
    await tester.tap(find.byKey(const Key('moment-pick-images')));
    await tester.pump();
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('moment-compose-publish')))
            .onPressed,
        isNull);
    expect(publishes, 0);
    bytes.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('moment-compose-publish')))
            .onPressed,
        isNotNull);
  });
  testWidgets(
      'album entry routes to shared mixed gallery and cancellation returns',
      (tester) async {
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('相册'), findsOneWidget);
    await tester.tap(find.byKey(const Key('moment-pick-images')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final gallery =
        tester.widget<ImagePickerPage>(find.byType(ImagePickerPage));
    expect(gallery.photosOnly, isFalse);
    expect(gallery.maxCount, 9);
    Navigator.of(tester.element(find.byType(ImagePickerPage))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(MomentComposerPage), findsOneWidget);
  });

  testWidgets('oversized album video is rejected before reading its bytes',
      (tester) async {
    var reads = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(
            api: api,
            galleryPicker: (_, __) async => (
                  photos: [
                    GalleryPhoto(
                        id: 'large',
                        thumbnail: Uint8List(0),
                        isVideo: true,
                        mimeType: 'video/mp4',
                        originalSizeBytes: () async => 20 * 1024 * 1024 + 1,
                        originalBytes: () async {
                          reads++;
                          return Uint8List(1);
                        },
                        compressedBytes: () async => Uint8List(1))
                  ],
                  original: true,
                  flash: false,
                ))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-pick-images')));
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(find.text('视频大小不能超过20MB'), findsOneWidget);
  });

  testWidgets('restored draft publishes video reference without upload',
      (tester) async {
    Map<String, dynamic>? published;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/draft')) {
            return http.Response(
                jsonEncode({
                  'text': 'draft',
                  'visibility': 'SELF',
                  'video_urls': ['media://moments/u/saved.mp4']
                }),
                200);
          }
          if (request.method == 'POST') {
            expect(request.url.path, '/api/v1/moments');
            published = jsonDecode(request.body) as Map<String, dynamic>;
          }
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pumpAndSettle();
    expect(published?['video_urls'], ['media://moments/u/saved.mp4']);
    expect(published?['visibility'], 'SELF');
  });

  testWidgets(
      'shared viewer mode hides gallery selection and offers failure retry',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: GalleryVideoPreviewPage(
            viewerOnly: true,
            loadRendition: () async => throw StateError('offline'),
            thumbnailBytes: Uint8List(0),
            duration: null,
            selected: false,
            onToggle: () {})));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gallery-video-select')), findsNothing);
    expect(find.byKey(const Key('gallery-video-retry')), findsOneWidget);
    expect(find.text('视频加载失败，请返回刷新或重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('video DTO survives reaction copy and renders a play entry',
      (tester) async {
    final item = MomentItem.fromJson({
      'id': 'v',
      'author': {'user_id': 'u', 'nickname': '用户'},
      'text': '',
      'image_urls': [],
      'video_urls': ['https://example.test/video'],
      'video_cache_keys': ['a' * 64],
    }).copyWith(liked: true);
    await tester.pumpWidget(CupertinoApp(home: WeChatMomentTile(item: item)));
    expect(find.text('播放视频'), findsOneWidget);
  });

  testWidgets(
      'composer uploads video without image conversion and retries publish without reupload',
      (tester) async {
    var uploads = 0;
    var publishes = 0;
    final publishKeys = <String?>[];
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(_Store()),
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/moments/draft')) return http.Response('{}', 200);
        if (path.endsWith('/moments/media/uploads')) {
          uploads++;
          expect(jsonDecode(request.body)['mime_type'], 'video/mp4');
          return http.Response('{"id":"v"}', 201);
        }
        if (path.endsWith('/content')) {
          expect(request.bodyBytes, [0, 0, 0, 16, 102, 116, 121, 112]);
          return http.Response('', 204);
        }
        if (path.endsWith('/complete')) {
          return http.Response(
              '{"status":"COMPLETED","media_url":"media://moments/u/v.mp4"}',
              200);
        }
        if (path.endsWith('/moments')) {
          publishes++;
          publishKeys.add(request.headers['Idempotency-Key']);
          final payload = jsonDecode(request.body);
          expect(payload['image_urls'], isEmpty);
          expect(payload['video_urls'], ['media://moments/u/v.mp4']);
          return publishes == 1
              ? http.Response(
                  '{"error":{"code":"RETRY","message":"retry"}}', 503)
              : http.Response('{}', 201);
        }
        return http.Response('{}', 200);
      }),
    );
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(api: api, initialImages: [
      XFile.fromData(Uint8List.fromList([0, 0, 0, 16, 102, 116, 121, 112]),
          name: 'v.mp4', mimeType: 'video/mp4'),
    ])));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pumpAndSettle();
    expect(uploads, 1);
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pumpAndSettle();
    expect(uploads, 1);
    expect(publishes, 2);
    expect(publishKeys[0], isNotNull);
    expect(publishKeys[1], publishKeys[0]);
  });
}

class _Store implements SecureKeyValueStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
