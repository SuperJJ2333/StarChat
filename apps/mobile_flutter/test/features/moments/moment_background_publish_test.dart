import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_composer_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_image_preprocessor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  testWidgets('accepted publish exits composer while upload continues',
      (tester) async {
    final paths = PathProviderPlatform.instance;
    final scratch = await tester.runAsync(() async {
      final parent = await Directory(
              '../../docs/verification/artifacts/2026-09-28/ios-media-room-followup/moments/widget')
          .absolute
          .create(recursive: true);
      return parent.createTemp('publish-');
    });
    PathProviderPlatform.instance = _Paths(scratch!.path);
    addTearDown(() {
      PathProviderPlatform.instance = paths;
    });
    final uploading = Completer<http.Response>();
    var uploadStarted = false;
    var published = false;
    final session = SecureSessionStore(_MemoryStore());
    await session.saveSession(
        accessToken: 'test-access',
        refreshToken: 'test-refresh',
        matrixUserId: '@pending:example.test');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: session,
        client: MockClient((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/draft')) {
            return http.Response('{}', 200);
          }
          if (request.url.path.endsWith('/uploads')) {
            return http.Response('{"id":"upload"}', 201);
          }
          if (request.method == 'PUT') {
            uploadStarted = true;
            return uploading.future;
          }
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                '{"status":"COMPLETED","media_url":"media://moments/u/image.jpg"}',
                200);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/moments')) {
            published = true;
            return http.Response('{"id":"published"}', 201);
          }
          return http.Response('', 204);
        }));
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                child: const Text('feed'),
                onPressed: () => Navigator.push(
                    context,
                    CupertinoPageRoute<bool>(
                        builder: (_) => MomentComposerPage(
                              api: api,
                              initialImages: [
                                XFile.fromData(
                                    base64Decode(
                                        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg=='),
                                    mimeType: 'image/png')
                              ],
                              imagePreprocessor:
                                  MomentImagePreprocessor.functional(
                                      (bytes) async => bytes),
                            )))))));
    await tester.tap(find.text('feed'));
    await tester.pumpAndSettle();
    await tester.runAsync(
        () => tester.tap(find.byKey(const Key('moment-compose-publish'))));
    for (var i = 0; i < 200 && !uploadStarted; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(uploadStarted, isTrue);
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.byType(MomentComposerPage), findsNothing,
        reason:
            'an accepted background task must not retain the publishing page');
    expect(published, isFalse);
    uploading.complete(http.Response('', 204));
    for (var i = 0; i < 200 && !published; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pumpAndSettle();
    expect(published, isTrue,
        reason: 'disposing composer must not cancel its accepted task');
  });
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;
  @override
  Future<String> getApplicationSupportPath() async => path;
}
