import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/features/moments/moment_comment_composer.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';
import 'package:liuhetong_mobile/ui/chat/chat_emoji_panel.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:http/testing.dart';

class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Future<BusinessApiClient> momentsApi(
    Future<http.Response> Function(http.Request) handler) async {
  final store = SecureSessionStore(_MemoryStore());
  await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
  return BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient(handler));
}

void main() {
  for (final dpr in [2.0, 5.0]) {
    testWidgets('comment original preview bounds both decoded axes at DPR $dpr',
        (tester) async {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = Size(800 * dpr, 600 * dpr);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final bytes = base64Decode(
          'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
      final api = await momentsApi((_) async => http.Response('{}', 200));
      final photo = GalleryPhoto(
          id: 'original',
          thumbnail: bytes,
          originalBytes: () async => bytes,
          compressedBytes: () async =>
              throw StateError('must retain original'));
      await tester.pumpWidget(CupertinoApp(
          home: Builder(
              builder: (context) => CupertinoButton(
                  child: const Text('open'),
                  onPressed: () => showMomentCommentComposer(context,
                      api: api,
                      momentId: 'm1',
                      galleryPicker: (_, __) async =>
                          (photos: [photo], original: true))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('moment-comment-gallery')));
      await tester.pumpAndSettle();
      final preview = tester.widget<Image>(find.byType(Image).first);
      expect(preview.image, isA<ResizeImage>(),
          reason: '48px preview must not decode the full original');
      final provider = preview.image as ResizeImage;
      expect(provider.width, (48 * dpr).ceil().clamp(48, 192));
      expect(provider.height, provider.width);
      expect(provider.policy, ResizeImagePolicy.fit);
      expect((provider.imageProvider as MemoryImage).bytes, bytes,
          reason: 'GIF animation/upload payload must remain intact');
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'comment photo button opens the exact shared gallery with original toggle',
      (tester) async {
    final api = await momentsApi((_) async => http.Response('{}', 200));
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                child: const Text('open'),
                onPressed: () => showMomentCommentComposer(context,
                    api: api, momentId: 'm1')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-comment-gallery')));
    await tester.pump(const Duration(milliseconds: 500));
    final picker = tester.widget<ImagePickerPage>(find.byType(ImagePickerPage));
    expect(picker.photosOnly, true);
    expect(picker.maxCount, 9);
    expect(picker.showOriginalToggle, true);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'local gallery GIF appears in shared custom panel and can be reselected',
      (tester) async {
    final bytes = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
    final api = await momentsApi((_) async => http.Response('{}', 200));
    final photo = GalleryPhoto(
        id: 'local',
        thumbnail: bytes,
        originalBytes: () async => bytes,
        compressedBytes: () async => bytes);
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                child: const Text('open'),
                onPressed: () => showMomentCommentComposer(context,
                    api: api,
                    momentId: 'm1',
                    galleryPicker: (_, __) async =>
                        (photos: [photo], original: false))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-comment-gallery')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.smiley));
    await tester.pump(const Duration(milliseconds: 350));
    final panel = tester.widget<ChatEmojiPanel>(find.byType(ChatEmojiPanel));
    expect(panel.customItems.single.isAnimated, true);
    expect(panel.customItems.single.bytes, bytes);
    await tester.tap(find.byKey(const Key('emoji-tab-custom')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('custom-button-0')));
    await tester.pump();
    expect(find.text('移除'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'gallery GIF uses original bytes MIME and upload references; retry reuses completed upload and comment key',
      (tester) async {
    final bytes = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
    final requests = <http.Request>[];
    var attempts = 0;
    final api = await momentsApi((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/uploads')) {
        return http.Response('{"id":"up1"}', 200);
      }
      if (request.method == 'PUT') return http.Response('{}', 200);
      if (request.url.path.endsWith('/complete')) {
        return http.Response(
            '{"media_url":"https://business.example/gif"}', 200);
      }
      attempts++;
      return http.Response(
          attempts == 1
              ? '{}'
              : '{"id":"c1","text":"draft","author":{"user_id":"u","username":"u"}}',
          attempts == 1 ? 500 : 200);
    });
    var originals = 0;
    final photo = GalleryPhoto(
        id: 'gif',
        thumbnail: bytes,
        mimeType: 'image/jpeg',
        originalBytes: () async {
          originals++;
          return bytes;
        },
        compressedBytes: () async => throw StateError('wrong mode'));
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                child: const Text('open'),
                onPressed: () => showMomentCommentComposer(context,
                        api: api,
                        momentId: 'm1', galleryPicker: (_, limit) async {
                      expect(limit, 9);
                      return (photos: [photo], original: true);
                    })))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), 'draft');
    await tester.tap(find.byKey(const Key('moment-comment-gallery')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    await tester.pumpAndSettle();
    expect(find.text('draft'), findsOneWidget);
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    await tester.pumpAndSettle();
    expect(originals, 1);
    final begin = requests.singleWhere((r) => r.url.path.endsWith('/uploads'));
    expect(jsonDecode(begin.body)['mime_type'], 'image/gif');
    expect(jsonDecode(begin.body)['file_name'], 'image.gif');
    final put = requests.singleWhere((r) => r.method == 'PUT');
    expect(put.bodyBytes, bytes);
    expect(put.headers['content-type'], 'image/gif');
    final comments =
        requests.where((r) => r.url.path.endsWith('/comments')).toList();
    expect(comments, hasLength(2));
    expect(comments.first.headers['idempotency-key'],
        comments.last.headers['idempotency-key']);
    expect(jsonDecode(comments.last.body)['image_upload_ids'], ['up1']);
    expect(find.byKey(const Key('moment-comment-input')), findsNothing);
  });
  testWidgets('cancelled gallery preserves text and sends no request',
      (tester) async {
    var requests = 0;
    final api = await momentsApi((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                child: const Text('open'),
                onPressed: () => showMomentCommentComposer(context,
                    api: api,
                    momentId: 'm1',
                    galleryPicker: (_, __) async => null)))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), 'draft');
    await tester.tap(find.byKey(const Key('moment-comment-gallery')));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.text('draft'), findsOneWidget);
  });
  testWidgets('disposed gallery callback cannot upload or update the next page',
      (tester) async {
    var requests = 0;
    final api = await momentsApi((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    final selected = Completer<({List<GalleryPhoto> photos, bool original})?>();
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                child: const Text('open'),
                onPressed: () => showMomentCommentComposer(context,
                    api: api,
                    momentId: 'm1',
                    galleryPicker: (_, __) => selected.future)))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-comment-gallery')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    final photo = GalleryPhoto(
        id: 'stale',
        thumbnail: Uint8List(0),
        originalBytes: () async =>
            throw StateError('must not read stale selection'),
        compressedBytes: () async =>
            throw StateError('must not read stale selection'));
    selected.complete((photos: [photo], original: false));
    await tester.pump();
    expect(requests, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('account switch prevents a draft being sent with the new session',
      (tester) async {
    var requests = 0;
    final api = await momentsApi((_) async {
      requests++;
      return http.Response('{}', 500);
    });
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                child: const Text('open'),
                onPressed: () => showMomentCommentComposer(context,
                    api: api, momentId: 'm1')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moment-comment-input')), 'draft');
    await api.sessionStore
        .saveSession(accessToken: 'different', refreshToken: 'different');
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-comment-submit')));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.text('draft'), findsOneWidget);
    expect(find.text('登录状态已变化，请重新打开评论'), findsOneWidget);
  });
  testWidgets(
      'comment uses the complete chat emoji catalog and cursor insertion',
      (tester) async {
    final api = await momentsApi((_) async => http.Response('{}', 200));
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                child: const Text('open'),
                onPressed: () => showMomentCommentComposer(context,
                    api: api, momentId: 'm1')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('moment-comment-input')), 'ab');
    final input = tester.widget<CupertinoTextField>(
        find.byKey(const Key('moment-comment-input')));
    input.controller!.selection = const TextSelection.collapsed(offset: 1);
    await tester.tap(find.byIcon(CupertinoIcons.smiley));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(ChatEmojiPanel), findsOneWidget);
    await tester.tap(find.byKey(const Key('fluent-emoji-grinning')));
    await tester.pump();
    expect(input.controller!.text, 'a😄b');
    expect(input.controller!.selection.baseOffset, 3);
    await tester.pumpWidget(const SizedBox());
  });
}
