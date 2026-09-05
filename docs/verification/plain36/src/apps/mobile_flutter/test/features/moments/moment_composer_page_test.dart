import 'dart:convert';
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

Uint8List pngBytes() => Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00,
  0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
  0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
  0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00,
  0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
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
    await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
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
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pumpAndSettle();

    expect(find.text('保留的内容'), findsOneWidget);
    expect(find.text('暂时无法发表'), findsOneWidget);
    expect(find.byType(MomentComposerPage), findsOneWidget);
  });

  testWidgets('selected images upload before publish and use remote URLs',
      (tester) async {
    final preprocessor = MomentImagePreprocessor.functional((bytes) async {
      return Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]);
    });
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
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
    final image = XFile.fromData(pngBytes(), name: 'photo.png', mimeType: 'image/png');

    await tester.pumpWidget(CupertinoApp(
      home: MomentComposerPage(
        api: api,
        initialImages: [image],
        imagePreprocessor: preprocessor,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    // 发布涉及真实解码/压缩/三次上传交互，逐步 pump 到全部微任务完成。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));

    expect(published?['image_urls'], ['https://media.example.test/photo.png']);
  });
  testWidgets('missing draft is treated as an empty composer', (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/moments/draft')) {
          return http.Response(
            jsonEncode({'error': {'code': 'MOMENT_DRAFT_NOT_FOUND', 'message': '草稿不存在'}}),
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
