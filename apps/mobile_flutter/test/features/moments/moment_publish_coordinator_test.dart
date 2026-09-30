import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/video_transcode.dart';
import 'package:liuhetong_mobile/features/moments/moment_image_preprocessor.dart';
import 'package:liuhetong_mobile/features/moments/moment_draft_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_publish_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<Directory> directory() async {
    final root = await Directory(
            '../../docs/verification/artifacts/2026-09-29/android-2191-followup/poster-policy/queue-tests')
        .create(recursive: true);
    return root.createTemp('case-');
  }

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==');
  final processor = MomentImagePreprocessor.functional((bytes) async => bytes);
  const payload = {
    'text': 'test',
    'visibility': 'SELF',
    'image_urls': <String>[],
    'video_urls': <String>[]
  };
  Future<SecureSessionStore> session() async {
    final store = SecureSessionStore(_Store());
    await store.saveSession(
        accessToken: 'test-access',
        refreshToken: 'test-refresh',
        matrixUserId: '@a:example.test');
    return store;
  }

  test('failed publish retries stable key without uploading its media again',
      () async {
    var begins = 0, puts = 0, publishes = 0;
    final keys = <String?>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/uploads')) {
            begins++;
            return http.Response('{"id":"upload"}', 201);
          }
          if (request.method == 'PUT') {
            puts++;
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                '{"status":"COMPLETED","media_url":"media://moments/a/image.jpg"}',
                200);
          }
          if (request.method == 'POST') {
            keys.add(request.headers['Idempotency-Key']);
            return ++publishes == 1
                ? http.Response(
                    '{"error":{"code":"TRY_AGAIN","message":"retry"}}', 503)
                : http.Response('{"id":"post"}', 201);
          }
          return http.Response('', 204);
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: await directory());
    final job = await queue.enqueue(payload,
        [MomentPublishMedia(XFile.fromData(image, mimeType: 'image/png'))],
        preprocessor: processor);
    await waitFor(() => job.state == MomentPublishState.failed);
    await queue.retry(job.id);
    await waitFor(() => job.state == MomentPublishState.succeeded);
    expect(keys.where((key) => key == job.id), [job.id, job.id]);
    expect(begins, 1);
    expect(puts, 1);
    queue.revoke();
  });

  test('uncertain accepted PUT retries its upload ID and completes once',
      () async {
    var begins = 0, publishes = 0;
    final putIds = <String>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/uploads')) {
            begins++;
            return http.Response('{"id":"upload-1"}', 201);
          }
          if (request.method == 'PUT') {
            putIds.add(request.url.pathSegments[5]);
            if (putIds.length == 1) {
              // The server accepted the bytes, but its response was lost.
              throw http.ClientException('response lost');
            }
            return http.Response(
                '{"error":{"code":"MOMENT_MEDIA_COMPLETED","message":"already complete"}}',
                409);
          }
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                '{"status":"COMPLETED","media_url":"media://moments/a/image.jpg"}',
                200);
          }
          if (request.url.path.endsWith('/moments')) publishes++;
          return http.Response('{"id":"post"}', 201);
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: await directory());
    final job = await queue.enqueue(payload,
        [MomentPublishMedia(XFile.fromData(image, mimeType: 'image/png'))],
        preprocessor: processor);
    await waitFor(() => job.state == MomentPublishState.failed);
    expect(job.media.single['upload'], 'upload-1');

    await queue.retry(job.id);
    await waitFor(() => job.state == MomentPublishState.succeeded);
    expect(begins, 1);
    expect(putIds, ['upload-1', 'upload-1']);
    expect(publishes, 1);
    queue.revoke();
  });

  test('draft cleanup rejection cannot invert successful publication',
      () async {
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async => request.url.path
                .endsWith('/clear-if-unchanged')
            ? http.Response(
                '{"error":{"code":"CLEANUP_FAILURE","message":"retry"}}', 503)
            : http.Response('{"id":"post"}', 201)));
    final queue =
        await MomentPublishCoordinator.open(api, directory: await directory());
    final job = await queue.enqueue(payload, []);
    await waitFor(() => job.state == MomentPublishState.succeeded);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(job.state, MomentPublishState.succeeded);
    expect(queue.publishedRevision, 1);
    queue.revoke();
  });

  test('changed server draft preserves local draft after successful publish',
      () async {
    const original = {
      'text': 'saved',
      'video_urls': ['https://example.test/video?renewed']
    };
    final local = InMemoryMomentDraftStore(MomentDraftSnapshot(
        scope: 'matrix:@a:example.test',
        payload: original,
        savedAt: DateTime.now()));
    MomentDraftStores.shared = local;
    Map<String, dynamic>? compared;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/clear-if-unchanged')) {
            compared = Map<String, dynamic>.from(
                jsonDecode(request.body)['expected_payload'] as Map);
            return http.Response('{"cleared":false}', 200);
          }
          return http.Response('{"id":"post"}', 201);
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: await directory());
    final job = await queue.enqueue(payload, [], expectedDraft: original);
    await waitFor(() => compared != null);
    await queue.flush();
    expect(compared, original);
    expect(job.state, MomentPublishState.succeeded);
    expect(local.read()?.payload, original);
    queue.revoke();
    MomentDraftStores.reset();
  });

  test('confirmed captured draft is cleared without deleting a new editor',
      () async {
    final local = InMemoryMomentDraftStore(MomentDraftSnapshot(
        scope: 'matrix:@a:example.test',
        payload: payload,
        savedAt: DateTime.now()));
    MomentDraftStores.shared = local;
    final clearing = Completer<http.Response>();
    var started = false;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/clear-if-unchanged')) {
            started = true;
            return clearing.future;
          }
          return http.Response('{"id":"post"}', 201);
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: await directory());
    final job = await queue.enqueue(payload, [], expectedDraft: payload);
    await waitFor(() => started);
    MomentDraftStores.noteEditing();
    const changed = {'text': 'new editor'};
    await local.write(MomentDraftSnapshot(
        scope: 'matrix:@a:example.test',
        payload: changed,
        savedAt: DateTime.now()));
    clearing.complete(http.Response('{"cleared":true}', 200));
    await queue.flush();
    expect(job.state, MomentPublishState.succeeded);
    expect(local.read()?.payload, changed);
    queue.revoke();
    MomentDraftStores.reset();
  });

  test('admission freezes payload and cleanup revision before source copying',
      () async {
    addTearDown(MomentDraftStores.reset);
    final started = Completer<void>(), release = Completer<void>();
    final source = _HeldCopyFile(image, started, release);
    var cleanups = 0;
    Map<String, dynamic>? published;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/clear-if-unchanged')) {
            cleanups++;
            return http.Response('{"cleared":true}', 200);
          }
          if (request.url.path.endsWith('/uploads')) {
            return http.Response('{"id":"upload"}', 201);
          }
          if (request.method == 'PUT') return http.Response('', 204);
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                '{"status":"COMPLETED","media_ref":"media://moments/a/image.jpg","media_url":"media://moments/a/image.jpg"}',
                200);
          }
          published =
              Map<String, dynamic>.from(jsonDecode(request.body) as Map);
          return http.Response('{"id":"post"}', 201);
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: await directory());
    final originalRevision = MomentDraftStores.editingRevision;
    final mutable = <String, dynamic>{...payload};
    final admitting = queue.enqueue(mutable, [MomentPublishMedia(source)],
        preprocessor: processor, expectedDraft: payload);
    await started.future;
    MomentDraftStores.noteEditing();
    mutable['text'] = 'new editor text';
    final local = InMemoryMomentDraftStore(MomentDraftSnapshot(
        scope: 'matrix:@a:example.test',
        payload: const {'text': 'new editor draft'},
        savedAt: DateTime.now()));
    MomentDraftStores.shared = local;
    release.complete();
    final job = await admitting;
    await waitFor(() => job.state == MomentPublishState.succeeded);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(published?['text'], 'test');
    expect(job.draftRevision, originalRevision);
    expect(cleanups, 0);
    expect(local.read()?.payload['text'], 'new editor draft');
    queue.revoke();
  });

  test('captured lease rejects an account switched before request dispatch',
      () async {
    var requests = 0;
    final store = await session();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: store,
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 201);
        }));
    final lease = await api.captureMomentPublishSession();
    await store.saveSession(
        accessToken: 'other-access',
        refreshToken: 'other-refresh',
        matrixUserId: '@b:example.test');
    await expectLater(api.postMomentTask(lease, '/moments', payload, 'stable'),
        throwsA(isA<BusinessApiException>()));
    await expectLater(api.putMomentTaskDraft(lease, payload, 'draft'),
        throwsA(isA<BusinessApiException>()));
    expect(requests, 0);
  });

  test('captured lease rejects logout and same-account login epoch', () async {
    var requests = 0;
    final store = await session();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: store,
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 201);
        }));
    final lease = await api.captureMomentPublishSession();
    await api.clearLocalSession();
    await store.saveSession(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
        matrixUserId: '@a:example.test');
    await expectLater(api.postMomentTask(lease, '/moments', payload, 'stable'),
        throwsA(isA<BusinessApiException>()));
    expect(requests, 0);
  });

  test(
      'restored same-account failed task retains publication identity and prepared media',
      () async {
    final root = await directory();
    final store = await session();
    var fail = true;
    final keys = <String?>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: store,
        client: MockClient((request) async {
          keys.add(request.headers['Idempotency-Key']);
          return fail
              ? http.Response(
                  '{"error":{"code":"FAILED","message":"retry"}}', 503)
              : http.Response('{"id":"post"}', 201);
        }));
    final first = await MomentPublishCoordinator.open(api, directory: root);
    final job = await first.enqueue(payload, []);
    await waitFor(() => job.state == MomentPublishState.failed);
    await first.flush();
    first.revoke();
    fail = false;
    final second = await MomentPublishCoordinator.open(api, directory: root);
    expect(second.jobs.single.id, job.id);
    await second.retry(job.id);
    await waitFor(
        () => second.jobs.single.state == MomentPublishState.succeeded);
    expect(keys.where((k) => k == job.id).length, 2);
    second.revoke();
  });

  test('cancelled in-flight media task never calls publish', () async {
    final uploading = Completer<http.Response>();
    var uploadStarted = false, published = false;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/uploads')) {
            return http.Response('{"id":"upload"}', 201);
          }
          if (request.method == 'PUT') {
            uploadStarted = true;
            return uploading.future;
          }
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                '{"status":"COMPLETED","media_url":"media://moments/a/image.jpg"}',
                200);
          }
          if (request.method == 'POST') published = true;
          return http.Response('{"id":"post"}', 201);
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: await directory());
    final job = await queue.enqueue(payload,
        [MomentPublishMedia(XFile.fromData(image, mimeType: 'image/png'))],
        preprocessor: processor);
    await waitFor(() => uploadStarted);
    await queue.cancel(job.id);
    uploading.complete(http.Response('', 204));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(published, isFalse);
    expect(job.state, MomentPublishState.cancelled);
    queue.revoke();
  });

  test(
      'video original above 20MiB stays file-backed and uses shared chat encoder',
      () async {
    final root = await directory();
    final source = File('${root.path}/original.mp4');
    final handle = await source.open(mode: FileMode.write);
    await handle.truncate(21 * 1024 * 1024);
    await handle.close();
    var encoders = 0, uploadedBytes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('video_compress'),
            (call) async {
      if (call.method == 'getMediaInfo') {
        return jsonEncode({'path': source.path, 'duration': 1000});
      }
      if (call.method != 'compressVideo') return null;
      encoders++;
      final output =
          await File('${root.path}/compressed.mp4').writeAsBytes([1, 2, 3]);
      return jsonEncode(
          {'path': output.path, 'duration': 1000, 'isCancel': false});
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('video_compress'), null));
    final oldCompressor = FlutterImageCompressPlatform.instance;
    FlutterImageCompressPlatform.instance = _PosterCompressor(image);
    addTearDown(() => FlutterImageCompressPlatform.instance = oldCompressor);
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/video-posters/uploads')) {
            expect(jsonDecode(request.body)['byte_size'],
                lessThanOrEqualTo(512 * 1024));
            return http.Response('{"id":"poster"}', 201);
          }
          if (request.url.path.endsWith('/uploads')) {
            expect(jsonDecode(request.body)['byte_size'], 3);
            return http.Response('{"id":"video"}', 201);
          }
          if (request.method == 'PUT') {
            if (!request.url.path.contains('/poster/')) {
              uploadedBytes += request.bodyBytes.length;
            }
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/complete')) {
            return request.url.path.contains('/poster/')
                ? http.Response(
                    '{"status":"COMPLETED","media_url":"media://moments/a/poster.jpg"}',
                    200)
                : http.Response(
                    '{"status":"COMPLETED","media_url":"media://moments/a/video.mp4"}',
                    200);
          }
          return http.Response('{"id":"post"}', 201);
        }));
    final queue = await MomentPublishCoordinator.open(api, directory: root);
    final job = await queue.enqueue(payload, [
      MomentPublishMedia(XFile(source.path, mimeType: 'video/mp4'),
          video: true, poster: image)
    ]);
    await waitFor(() => job.state == MomentPublishState.succeeded);
    expect(encoders, 1);
    expect(uploadedBytes, 3);
    expect(await source.length(), 21 * 1024 * 1024);
    queue.revoke();
  });

  test(
      'static processed output above shared limit is rejected before any upload',
      () async {
    var requests = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: await directory());
    final job = await queue.enqueue(payload,
        [MomentPublishMedia(XFile.fromData(image, mimeType: 'image/png'))],
        preprocessor: MomentImagePreprocessor.functional(
            (_) async => Uint8List(20 * 1024 * 1024 + 1)));
    await waitFor(() => job.state == MomentPublishState.failed);
    expect(requests, 0);
    expect(job.message, contains('500KB'));
    queue.revoke();
  });
  test('expired upload starts a new stable session on explicit retry',
      () async {
    var begins = 0, completes = 0, publishes = 0;
    final beginKeys = <String?>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/uploads')) {
            beginKeys.add(request.headers['Idempotency-Key']);
            return http.Response(jsonEncode({'id': 'upload-${++begins}'}), 201);
          }
          if (request.method == 'PUT') {
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/complete')) {
            return ++completes == 1
                ? http.Response(
                    '{"error":{"code":"MOMENT_MEDIA_EXPIRED","message":"expired"}}',
                    409)
                : http.Response(
                    '{"status":"COMPLETED","media_url":"media://moments/a/image.jpg"}',
                    200);
          }
          if (request.url.path.endsWith('/moments')) {
            publishes++;
          }
          return http.Response('{"id":"post"}', 201);
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: await directory());
    final job = await queue.enqueue(payload,
        [MomentPublishMedia(XFile.fromData(image, mimeType: 'image/png'))],
        preprocessor: processor);
    await waitFor(() => job.state == MomentPublishState.failed);
    await queue.retry(job.id);
    await waitFor(() => job.state == MomentPublishState.succeeded);
    expect(begins, 2);
    expect(publishes, 1);
    expect(beginKeys.toSet(), hasLength(2));
    queue.revoke();
  });
  test(
      'video poster binds its completed id and publication uses durable reference',
      () async {
    final directoryRoot = await directory();
    Map<String, dynamic>? published;
    var beginCount = 0, videoCompletions = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('video_compress'),
        (call) async {
      if (call.method == 'getMediaInfo') {
        return jsonEncode({'path': call.arguments['path'], 'duration': 1000});
      }
      if (call.method != 'compressVideo') return null;
      final output = await File(call.arguments['path'] as String)
          .copy('${directoryRoot.path}/encoded.mp4');
      return jsonEncode(
          {'path': output.path, 'duration': 1000, 'isCancel': false});
    });
    final oldCompressor = FlutterImageCompressPlatform.instance;
    FlutterImageCompressPlatform.instance = _PosterCompressor(image);
    addTearDown(() {
      messenger.setMockMethodCallHandler(
          const MethodChannel('video_compress'), null);
      FlutterImageCompressPlatform.instance = oldCompressor;
    });
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/uploads')) {
            beginCount++;
            final poster = request.url.path.contains('/video-posters/');
            if (poster) {
              expect(jsonDecode(request.body)['byte_size'],
                  lessThanOrEqualTo(512 * 1024));
              expect(jsonDecode(request.body)['mime_type'], 'image/jpeg');
            }
            return http.Response(
                jsonEncode({'id': poster ? 'poster' : 'video'}), 201);
          }
          if (request.method == 'PUT') return http.Response('', 204);
          if (request.url.path.endsWith('/complete')) {
            final poster = request.url.path.contains('/poster/');
            if (!poster) videoCompletions++;
            return http.Response(
                jsonEncode({
                  'status': 'COMPLETED',
                  'media_url': 'https://example.test/signed-$videoCompletions',
                  'media_ref': poster
                      ? 'media://moments/a/poster.jpg'
                      : 'media://moments/a/video.mp4'
                }),
                200);
          }
          if (request.url.path.endsWith('/moments')) {
            published = jsonDecode(request.body);
          }
          return http.Response('{"id":"post"}', 201);
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: directoryRoot);
    final job = await queue.enqueue(payload, [
      MomentPublishMedia(
          XFile.fromData(Uint8List.fromList([1, 2, 3]), mimeType: 'video/mp4'),
          video: true,
          poster: image)
    ]);
    await waitFor(() => job.state == MomentPublishState.succeeded);
    expect(beginCount, 2);
    expect(videoCompletions, 2,
        reason: 'renew immediately before publishing after later work');
    expect(published?['video_urls'], ['media://moments/a/video.mp4']);
    expect(published?['video_poster_media_ids'], ['poster']);
    queue.revoke();
  });

  test('video without its own frame or preview cannot publish', () async {
    final directoryRoot = await directory();
    _mockVideoRendition(directoryRoot, image);
    var requests = 0, publishes = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async {
          requests++;
          if (request.url.path.endsWith('/uploads')) {
            return http.Response('{"id":"video-upload"}', 201);
          }
          if (request.method == 'PUT') return http.Response('', 204);
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                '{"status":"COMPLETED","media_url":"https://example.test/video","media_ref":"media://moments/a/video.mp4"}',
                200);
          }
          if (request.url.path.endsWith('/moments')) publishes++;
          return http.Response('{"id":"post"}', 201);
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: directoryRoot);
    final job = await queue.enqueue(payload, [
      MomentPublishMedia(
          XFile.fromData(Uint8List.fromList([1, 2, 3]), mimeType: 'video/mp4'),
          video: true),
      MomentPublishMedia(
          XFile.fromData(Uint8List.fromList([4, 5, 6]), mimeType: 'video/mp4'),
          video: true,
          poster: image),
    ]);

    await waitFor(() =>
        job.state == MomentPublishState.failed ||
        job.state == MomentPublishState.succeeded);
    expect(job.state, MomentPublishState.failed);
    expect(job.message, '视频封面生成失败，内容已保留，请重试');
    expect(requests, 0);
    expect(publishes, 0);
    expect(job.media.first['prepared'], false);
    expect(await File('${queue.root.path}/${job.id}/media-0').exists(), isTrue);
    queue.revoke();
  });

  test('remote draft video needs a paired poster before job admission',
      () async {
    var requests = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: await directory());
    await expectLater(
        queue.enqueue({
          ...payload,
          'video_urls': ['media://moments/a/draft.mp4'],
        }, []),
        throwsA(isA<MomentImageException>()
            .having((error) => error.message, 'message', '视频封面暂不可用，请稍后重试')));
    expect(requests, 0);
    expect(queue.jobs, isEmpty);
    queue.revoke();
  });

  test('restored legacy posterless job cannot reach publish', () async {
    var publishes = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: await session(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/moments')) publishes++;
          return http.Response('{"id":"post"}', 201);
        }));
    final directoryRoot = await directory();
    final first =
        await MomentPublishCoordinator.open(api, directory: directoryRoot);
    final root = first.root;
    first.revoke();
    const id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    final jobDirectory = await Directory('${root.path}/$id').create();
    await File('${jobDirectory.path}/job.json').writeAsString(jsonEncode({
      'account': '@a:example.test',
      'id': id,
      'payload': {
        ...payload,
        'video_urls': ['media://moments/a/old-draft.mp4']
      },
      'media': [],
      'state': 'queued',
    }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: directoryRoot);
    await waitFor(() => queue.jobs.single.state == MomentPublishState.failed);
    expect(publishes, 0);
    expect(queue.jobs.single.message, '视频封面暂不可用，请稍后重试');
    queue.revoke();
  });

  for (final stage in [
    'begin-404',
    'begin-503',
    'put',
    'complete',
    'not-ready'
  ]) {
    test('poster $stage failure retains video result and retries once',
        () async {
      final directoryRoot = await directory();
      _mockVideoRendition(directoryRoot, image);
      var failPoster = true;
      var videoBegins = 0, videoPuts = 0, publishes = 0;
      Map<String, dynamic>? published;
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://example.test'),
          sessionStore: await session(),
          client: MockClient((request) async {
            final path = request.url.path;
            if (path.endsWith('/video-posters/uploads')) {
              if (failPoster && stage.startsWith('begin')) {
                return http.Response(
                    '{"error":{"code":"POSTER_UNAVAILABLE","message":"unavailable"}}',
                    stage == 'begin-404' ? 404 : 503);
              }
              return http.Response('{"id":"poster-upload"}', 201);
            }
            if (path.endsWith('/media/uploads')) {
              videoBegins++;
              return http.Response('{"id":"video-upload"}', 201);
            }
            if (request.method == 'PUT') {
              if (path.contains('/poster-upload/')) {
                if (failPoster && stage == 'put') {
                  return http.Response(
                      '{"error":{"code":"POSTER_UNAVAILABLE","message":"unavailable"}}',
                      503);
                }
              } else {
                videoPuts++;
              }
              return http.Response('', 204);
            }
            if (path.endsWith('/complete')) {
              if (path.contains('/poster-upload/')) {
                if (failPoster && stage == 'complete') {
                  return http.Response(
                      '{"error":{"code":"POSTER_UNAVAILABLE","message":"unavailable"}}',
                      503);
                }
                if (failPoster && stage == 'not-ready') {
                  return http.Response(
                      '{"status":"PROCESSING","media_url":"https://example.test/poster"}',
                      200);
                }
                return http.Response(
                    '{"status":"COMPLETED","media_url":"https://example.test/poster","media_ref":"media://moments/a/poster.jpg"}',
                    200);
              }
              return http.Response(
                  '{"status":"COMPLETED","media_url":"https://example.test/video","media_ref":"media://moments/a/video.mp4"}',
                  200);
            }
            if (path.endsWith('/moments')) {
              publishes++;
              published = Map<String, dynamic>.from(jsonDecode(request.body));
            }
            return http.Response('{"id":"post"}', 201);
          }));
      final queue =
          await MomentPublishCoordinator.open(api, directory: directoryRoot);
      final job = await queue.enqueue(payload, [
        MomentPublishMedia(
            XFile.fromData(Uint8List.fromList([1, 2, 3]),
                mimeType: 'video/mp4'),
            video: true,
            poster: image)
      ]);

      await waitFor(() =>
          job.state == MomentPublishState.failed ||
          job.state == MomentPublishState.succeeded);
      expect(job.state, MomentPublishState.failed);
      expect(job.message, '视频封面暂不可用，请稍后重试');
      expect(job.media.single['result'], isNotNull);
      expect(publishes, 0);
      expect(await File('${queue.root.path}/${job.id}/media-0.ready').exists(),
          isTrue);

      failPoster = false;
      await queue.retry(job.id);
      await waitFor(() => job.state == MomentPublishState.succeeded);
      expect(videoBegins, 1);
      expect(videoPuts, 1);
      expect(publishes, 1);
      expect(published?['video_urls'], ['media://moments/a/video.mp4']);
      expect(published?['video_poster_media_ids'], ['poster-upload']);
      queue.revoke();
    });
  }

  test('Moment failure reasons map typed errors without error text', () {
    expect(momentDiagnosticReason(TimeoutException('private URL')),
        ChatDiagnosticError.timeout);
    expect(momentDiagnosticReason(const SocketException('private file path')),
        ChatDiagnosticError.network);
    expect(momentDiagnosticReason(const GroupVideoTooLargeException()),
        ChatDiagnosticError.size);
    expect(momentDiagnosticReason(const VideoCompressionException()),
        ChatDiagnosticError.format);
    expect(momentDiagnosticReason(const MomentImageException('媒体大小超过限制')),
        ChatDiagnosticError.size);
    expect(
        momentDiagnosticReason(
            const MomentImageException('视频封面生成失败，内容已保留，请重试')),
        ChatDiagnosticError.format);
    expect(
        momentDiagnosticReason(const BusinessApiException(
            statusCode: 503, code: 'PRIVATE', message: 'private response')),
        ChatDiagnosticError.rejected);
    expect(
        momentDiagnosticReason(const BusinessApiException(
            statusCode: 413, code: 'PRIVATE', message: 'private response')),
        ChatDiagnosticError.size);
  });

  for (final failedPhase in [
    'video-begin',
    'video-read',
    'video-put',
    'video-put-persist',
    'video-complete-persist',
    'poster-begin',
    'poster-read',
    'poster-put',
    'poster-complete',
  ]) {
    test('$failedPhase reports only its bounded failure stage', () async {
      final previousDiagnostics = ChatDiagnostics.instance;
      var diagnosticNow = DateTime.utc(2026);
      final batches = <Map<String, Object?>>[];
      final diagnostics = ChatDiagnostics(now: () => diagnosticNow);
      ChatDiagnostics.instance = diagnostics;
      addTearDown(() {
        diagnostics.stopSession();
        ChatDiagnostics.instance = previousDiagnostics;
      });
      diagnostics.startSession(
          version: '0.4.22+2191',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch.toJson());
            return 202;
          });
      final directoryRoot = await directory();
      _mockVideoRendition(directoryRoot, image);
      var publishes = 0;
      late MomentPublishCoordinator queue;
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://example.test'),
          sessionStore: await session(),
          client: MockClient((request) async {
            final path = request.url.path;
            if (path.endsWith('/video-posters/uploads')) {
              if (failedPhase == 'poster-begin') {
                throw TimeoutException('private begin URL');
              }
              if (failedPhase == 'poster-read') {
                final jobId =
                    request.headers['Idempotency-Key']!.split(':').first;
                await File('${queue.root.path}/$jobId/media-0.poster').delete();
              }
              return http.Response('{"id":"poster-upload"}', 201);
            }
            if (path.endsWith('/uploads')) {
              if (failedPhase == 'video-begin') {
                throw TimeoutException('private begin URL');
              }
              if (failedPhase == 'video-read') {
                final jobId =
                    request.headers['Idempotency-Key']!.split(':').first;
                await File('${queue.root.path}/$jobId/media-0.ready').delete();
              }
              return http.Response('{"id":"video-upload"}', 201);
            }
            if (request.method == 'PUT') {
              if (failedPhase == 'video-put-persist' &&
                  path.contains('/video-upload/')) {
                final jobId = queue.jobs.single.id;
                await Directory('${queue.root.path}/$jobId')
                    .rename('${queue.root.path}/saved-$jobId');
                return http.Response('', 204);
              }
              if (failedPhase == 'poster-put' &&
                  path.contains('/poster-upload/')) {
                return http.Response('', 503);
              }
              if (failedPhase == 'video-put' &&
                  path.contains('/video-upload/')) {
                throw const SocketException('private file path');
              }
              return http.Response('', 204);
            }
            if (path.endsWith('/complete')) {
              if (path.contains('/poster-upload/')) {
                return failedPhase == 'poster-complete'
                    ? http.Response(
                        '{"error":{"code":"PRIVATE","message":"private URL"}}',
                        503)
                    : http.Response(
                        '{"status":"COMPLETED","media_url":"https://example.test/poster"}',
                        200);
              }
              if (failedPhase == 'video-complete-persist') {
                final jobId = queue.jobs.single.id;
                await Directory('${queue.root.path}/$jobId')
                    .rename('${queue.root.path}/saved-$jobId');
              }
              return http.Response(
                  '{"status":"COMPLETED","media_url":"https://example.test/video"}',
                  200);
            }
            if (path.endsWith('/moments')) publishes++;
            return http.Response('{"id":"post"}', 201);
          }));
      queue =
          await MomentPublishCoordinator.open(api, directory: directoryRoot);
      final job = await queue.enqueue(payload, [
        MomentPublishMedia(
            XFile.fromData(Uint8List.fromList([1, 2, 3]),
                mimeType: 'video/mp4'),
            video: true,
            poster: image)
      ]);
      await waitFor(() => job.state == MomentPublishState.failed);
      diagnosticNow = diagnosticNow.add(const Duration(minutes: 1));
      await diagnostics.flush();
      final wire = jsonEncode(batches);
      final momentEvents = [
        for (final batch in batches)
          for (final event in batch['events'] as List)
            if ((event as Map)['stage'].toString().startsWith('moment_')) event
      ];
      expect(momentEvents, hasLength(1));
      final event = momentEvents.single;
      expect(
          event['stage'],
          switch (failedPhase) {
            'video-begin' => 'moment_video_begin',
            'video-read' => 'moment_prepare',
            'video-put' => 'moment_video_put',
            'video-put-persist' || 'video-complete-persist' => 'moment_prepare',
            'poster-begin' => 'moment_poster_begin',
            'poster-read' => 'moment_poster_extract',
            'poster-put' => 'moment_poster_put',
            _ => 'moment_poster_complete',
          });
      expect(
          event['error'],
          switch (failedPhase) {
            'video-begin' || 'poster-begin' => 'timeout',
            'video-read' ||
            'video-put-persist' ||
            'video-complete-persist' ||
            'poster-read' =>
              'unknown',
            'video-put' => 'network',
            _ => 'rejected',
          });
      expect(
          event['status'],
          failedPhase == 'video-put' ||
                  failedPhase == 'video-read' ||
                  failedPhase.endsWith('-persist') ||
                  failedPhase == 'poster-read' ||
                  failedPhase.endsWith('begin')
              ? null
              : 503);
      expect(event['elapsed_ms'], inInclusiveRange(0, 3600000));
      expect(wire, isNot(contains('private')));
      expect(wire, isNot(contains('video-upload')));
      expect(wire, isNot(contains('poster-upload')));
      expect(wire, isNot(contains('https://example.test/video')));
      expect(
          job.message,
          failedPhase == 'video-read' || failedPhase.endsWith('-persist')
              ? '视频准备失败，内容已保留，请重试'
              : failedPhase == 'poster-read'
                  ? '视频封面生成失败，内容已保留，请重试'
                  : failedPhase.startsWith('video-')
                      ? '视频上传失败，内容已保留，请重试'
                      : '视频封面暂不可用，请稍后重试');
      expect(publishes, 0);
      queue.revoke();
    });
  }

  test('account switch suppresses an old video publish diagnostic', () async {
    final previousDiagnostics = ChatDiagnostics.instance;
    var diagnosticNow = DateTime.utc(2026);
    final batches = <Map<String, Object?>>[];
    final diagnostics = ChatDiagnostics(now: () => diagnosticNow);
    ChatDiagnostics.instance = diagnostics;
    addTearDown(() {
      diagnostics.stopSession();
      ChatDiagnostics.instance = previousDiagnostics;
    });
    void startDiagnostics(String version) => diagnostics.startSession(
        version: version,
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, _) async {
          batches.add(batch.toJson());
          return 202;
        });
    startDiagnostics('0.4.22+2191');
    final store = await session();
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: store,
        client: MockClient((request) async {
          started.complete();
          return response.future;
        }));
    final queue =
        await MomentPublishCoordinator.open(api, directory: await directory());
    final job = await queue.enqueue({
      ...payload,
      'video_urls': ['media://moments/a/video.mp4'],
      'video_poster_media_ids': ['poster-upload']
    }, []);
    await started.future;
    await api.clearLocalSession();
    await store.saveSession(
        accessToken: 'other-access',
        refreshToken: 'other-refresh',
        matrixUserId: '@b:example.test');
    startDiagnostics('0.4.22+2192');
    response.complete(http.Response(
        '{"error":{"code":"PRIVATE","message":"private URL"}}', 503));
    await waitFor(() => job.state == MomentPublishState.failed);
    diagnosticNow = diagnosticNow.add(const Duration(minutes: 1));
    await diagnostics.flush();
    expect(jsonEncode(batches), isNot(contains('moment_publish')));
    queue.revoke();
  });
}

void _mockVideoRendition(Directory directoryRoot, Uint8List posterFrame) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('video_compress'),
      (call) async {
    if (call.method == 'getMediaInfo') {
      return jsonEncode({'path': call.arguments['path'], 'duration': 1000});
    }
    if (call.method != 'compressVideo') return null;
    final output = await File(call.arguments['path'] as String)
        .copy('${directoryRoot.path}/encoded.mp4');
    return jsonEncode(
        {'path': output.path, 'duration': 1000, 'isCancel': false});
  });
  final oldCompressor = FlutterImageCompressPlatform.instance;
  FlutterImageCompressPlatform.instance = _PosterCompressor(posterFrame);
  addTearDown(() {
    messenger.setMockMethodCallHandler(
        const MethodChannel('video_compress'), null);
    FlutterImageCompressPlatform.instance = oldCompressor;
  });
}

final class _Store implements SecureKeyValueStore {
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

final class _PosterCompressor extends FlutterImageCompressPlatform {
  _PosterCompressor(this.output);
  final Uint8List output;
  @override
  Future<Uint8List> compressWithList(Uint8List image,
      {int minWidth = 1920,
      int minHeight = 1080,
      int quality = 95,
      int rotate = 0,
      int inSampleSize = 1,
      bool autoCorrectionAngle = true,
      CompressFormat format = CompressFormat.jpeg,
      bool keepExif = false}) async {
    expect(minWidth, lessThanOrEqualTo(480));
    expect(minHeight, lessThanOrEqualTo(480));
    expect(format, CompressFormat.jpeg);
    return img.encodeJpg(img.decodeImage(output)!);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected compressor operation');
}

final class _HeldCopyFile extends XFile {
  _HeldCopyFile(this.bytes, this.started, this.release)
      : super('held-source', mimeType: 'image/png');
  final Uint8List bytes;
  final Completer<void> started, release;
  @override
  Future<int> length() async => bytes.length;
  @override
  Future<void> saveTo(String path) async {
    started.complete();
    await release.future;
    await File(path).writeAsBytes(bytes);
  }
}
