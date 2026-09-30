import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/media/image_compression_policy.dart';
import 'package:liuhetong_mobile/features/moments/moment_publish_coordinator.dart';

import '../media/media_test_fixtures.dart';
import 'package:liuhetong_mobile/features/moments/moment_image_preprocessor.dart';

final class _Store implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const reference = 'media://moments/a/legacy.gif';
  const payload = {
    'text': 'legacy',
    'visibility': 'SELF',
    'image_urls': <String>[],
    'video_urls': <String>[]
  };
  late Uint8List large;
  setUpAll(() => large = largeMediaTestGif());

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 500 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  Future<
          ({
            BusinessApiClient api,
            Directory docs,
            File source,
            SecureSessionStore sessions
          })>
      seed(Future<http.Response> Function(http.Request) transport,
          {Map<String, dynamic> phase = const {},
          Uint8List? bytes,
          String mime = 'image/gif'}) async {
    final sessions = SecureSessionStore(_Store());
    await sessions.saveSession(
        accessToken: 'a',
        refreshToken: 'a-refresh',
        matrixUserId: '@a:example.test');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: sessions,
        client: MockClient(transport));
    final artifacts = await Directory(
            '../../docs/verification/artifacts/2026-10-01/unified-media/legacy-ready-tests')
        .create(recursive: true);
    final docs = await artifacts.createTemp('case-');
    final empty = await MomentPublishCoordinator.open(api, directory: docs);
    final root = empty.root;
    empty.revoke();
    final folder = await Directory('${root.path}/$id').create();
    final source = await File('${folder.path}/media-0.ready')
        .writeAsBytes(bytes ?? large, flush: true);
    await File('${folder.path}/job.json').writeAsString(
        jsonEncode({
          'account': '@a:example.test',
          'id': id,
          'payload': payload,
          'state': 'failed',
          'media': [
            {
              'file': 'media-0.ready',
              'prepared': true,
              'video': false,
              'mime': mime,
              ...phase
            }
          ]
        }),
        flush: true);
    return (api: api, docs: docs, source: source, sessions: sessions);
  }

  test(
      'unstarted legacy ready GIF is capped before begin and survives restore retry',
      () async {
    final declarations = <Map<String, dynamic>>[];
    final keys = <String?>[], bodies = <String>[];
    Uint8List? uploaded;
    var publishes = 0;
    final input = await seed((request) async {
      if (request.url.path.endsWith('/uploads')) {
        declarations.add(jsonDecode(request.body) as Map<String, dynamic>);
        keys.add(request.headers['Idempotency-Key']);
        return http.Response('{"id":"upload-legacy"}', 201);
      }
      if (request.method == 'PUT') {
        uploaded = request.bodyBytes;
        return http.Response('', 204);
      }
      if (request.url.path.endsWith('/complete')) {
        return http.Response(
            jsonEncode({
              'status': 'COMPLETED',
              'media_url': reference,
              'media_ref': reference
            }),
            200);
      }
      bodies.add(request.body);
      keys.add(request.headers['Idempotency-Key']);
      return ++publishes == 1
          ? http.Response(
              '{"error":{"code":"TRY_AGAIN","message":"retry"}}', 503)
          : http.Response('{"id":"post"}', 201);
    });
    expect(large.length, greaterThan(maxUnifiedImageBytes));
    final queue =
        await MomentPublishCoordinator.open(input.api, directory: input.docs);
    await queue.retry(id);
    await waitFor(() => queue.jobs.single.state == MomentPublishState.failed);
    expect(declarations.single['byte_size'],
        lessThanOrEqualTo(maxUnifiedImageBytes));
    expect(declarations.single['mime_type'], 'image/gif');
    expect(declarations.single['file_name'], 'image.gif');
    expect(uploaded, isNotNull);
    expect(uploaded!.length, declarations.single['byte_size']);
    expect(img.decodeGif(uploaded!)!.numFrames, 8);
    final media = queue.jobs.single.media.single;
    final ready = File('${queue.root.path}/$id/${media['file']}');
    expect(await ready.exists(), isTrue,
        reason: 'source==ready must not delete replacement');
    expect(await ready.readAsBytes(), uploaded);
    expect(await input.source.exists(), isFalse);
    await queue.flush();
    queue.revoke();
    final restored =
        await MomentPublishCoordinator.open(input.api, directory: input.docs);
    expect(restored.jobs.single.id, id);
    expect(restored.jobs.single.media.single['file'], media['file']);
    await restored.retry(id);
    await waitFor(
        () => restored.jobs.single.state == MomentPublishState.succeeded);
    expect(declarations, hasLength(1));
    expect(keys, ['$id:begin:0:0', id, id]);
    expect(bodies, hasLength(2));
    expect(bodies[1], bodies[0],
        reason: 'uncertain publish payload must remain stable');
    restored.revoke();
  });

  test(
      'prepared compliant image repairs MIME before begin without replacing ready bytes',
      () async {
    final gif = mediaTestGif();
    Map<String, dynamic>? declaration;
    final input = await seed((request) async {
      if (request.url.path.endsWith('/uploads')) {
        declaration = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{"id":"upload"}', 201);
      }
      if (request.method == 'PUT') return http.Response('', 204);
      if (request.url.path.endsWith('/complete')) {
        return http.Response(
            jsonEncode({'status': 'COMPLETED', 'media_url': reference}), 200);
      }
      return http.Response(
          '{"error":{"code":"TRY_AGAIN","message":"retry"}}', 503);
    }, bytes: gif, mime: 'image/jpeg');
    final queue =
        await MomentPublishCoordinator.open(input.api, directory: input.docs);
    await queue.retry(id);
    await waitFor(() => queue.jobs.single.state == MomentPublishState.failed);
    expect(declaration, {
      'file_name': 'image.gif',
      'mime_type': 'image/gif',
      'byte_size': gif.length
    });
    expect(queue.jobs.single.media.single['file'], 'media-0.ready');
    expect(await input.source.readAsBytes(), gif);
    queue.revoke();
  });

  test(
      'begun unconfirmed legacy large upload requires cancel and reselect before requests',
      () async {
    var requests = 0;
    final input = await seed((_) async {
      requests++;
      return http.Response('', 204);
    }, phase: {'upload': 'old-upload'});
    final queue =
        await MomentPublishCoordinator.open(input.api, directory: input.docs);
    await queue.retry(id);
    await waitFor(() => queue.jobs.single.state == MomentPublishState.failed);
    expect(requests, 0);
    expect(queue.jobs.single.message, contains('取消'));
    expect(queue.jobs.single.message, contains('重新选择'));
    expect(queue.jobs.single.media.single['upload'], 'old-upload');
    expect(await input.source.readAsBytes(), large);
    await queue.retry(id);
    await waitFor(() => queue.jobs.single.state == MomentPublishState.failed);
    expect(requests, 0);
    queue.revoke();
  });

  for (final phase in ['put', 'result']) {
    test(
        'confirmed legacy $phase replays immutable reference and stable publish payload',
        () async {
      var puts = 0, begins = 0, publishes = 0;
      final bodies = <String>[], keys = <String?>[];
      final input = await seed((request) async {
        if (request.url.path.endsWith('/uploads')) begins++;
        if (request.method == 'PUT') puts++;
        if (request.url.path.endsWith('/complete')) {
          keys.add(request.headers['Idempotency-Key']);
          return http.Response(
              jsonEncode({
                'status': 'COMPLETED',
                'media_url': reference,
                'media_ref': reference
              }),
              200);
        }
        bodies.add(request.body);
        keys.add(request.headers['Idempotency-Key']);
        return ++publishes == 1
            ? http.Response(
                '{"error":{"code":"TRY_AGAIN","message":"retry"}}', 503)
            : http.Response('{"id":"post"}', 201);
      }, phase: {
        'upload': 'old-upload',
        'put': true,
        if (phase == 'result')
          'result': {
            'id': 'old-upload',
            'media_url': reference,
            'media_ref': reference
          }
      });
      final queue =
          await MomentPublishCoordinator.open(input.api, directory: input.docs);
      await queue.retry(id);
      await waitFor(() => queue.jobs.single.state == MomentPublishState.failed);
      expect(await input.source.readAsBytes(), large);
      expect(queue.jobs.single.media.single['file'], 'media-0.ready');
      await queue.flush();
      queue.revoke();
      final restored =
          await MomentPublishCoordinator.open(input.api, directory: input.docs);
      await restored.retry(id);
      await waitFor(
          () => restored.jobs.single.state == MomentPublishState.succeeded);
      expect(puts, 0);
      expect(begins, 0);
      expect(bodies[1], bodies[0]);
      expect(jsonDecode(bodies.first)['image_urls'], [reference]);
      expect(keys.where((key) => key == id), [id, id]);
      expect(keys.where((key) => key != id).toSet(), {'$id:complete:0:0'});
      restored.revoke();
    });
  }

  for (final replacement in ['revoke', 'direct-store']) {
    test('account $replacement during image processing preserves copied source',
        () async {
      final processing = Completer<void>(), release = Completer<void>();
      var requests = 0;
      final input = await seed((_) async {
        requests++;
        return http.Response('', 204);
      });
      final queue =
          await MomentPublishCoordinator.open(input.api, directory: input.docs);
      final bytes = mediaTestPng();
      final job = await queue.enqueue(payload, [
        MomentPublishMedia(XFile.fromData(bytes, mimeType: 'image/png'))
      ], preprocessor: MomentImagePreprocessor.functional((value) async {
        processing.complete();
        await release.future;
        return value;
      }));
      await processing.future;
      if (replacement == 'revoke') await input.api.clearLocalSession();
      await input.sessions.saveSession(
          accessToken: 'b',
          refreshToken: 'b-refresh',
          matrixUserId: '@b:example.test');
      release.complete();
      await waitFor(() => job.state == MomentPublishState.failed);
      expect(requests, 0);
      expect(job.media.single['prepared'], false,
          reason:
              'replacement account must not persist processed media for the old job');
      expect(await File('${queue.root.path}/${job.id}/media-0').readAsBytes(),
          bytes);
      expect(await File('${queue.root.path}/${job.id}/media-0.ready').exists(),
          false);
      queue.revoke();
    });
  }
  test(
      'expired confirmed legacy large session keeps immutable phase and requires reselect',
      () async {
    var begins = 0, puts = 0;
    final input = await seed((request) async {
      if (request.url.path.endsWith('/uploads')) begins++;
      if (request.method == 'PUT') puts++;
      return http.Response(
          '{"error":{"code":"MOMENT_MEDIA_EXPIRED","message":"expired"}}', 409);
    }, phase: {'upload': 'old-upload', 'put': true});
    final queue =
        await MomentPublishCoordinator.open(input.api, directory: input.docs);
    await queue.retry(id);
    await waitFor(() => queue.jobs.single.state == MomentPublishState.failed);
    expect(queue.jobs.single.message, contains('取消'));
    expect(queue.jobs.single.message, contains('重新选择'));
    expect(queue.jobs.single.media.single['upload'], 'old-upload');
    expect(queue.jobs.single.media.single['put'], true);
    expect(await input.source.readAsBytes(), large);
    await queue.retry(id);
    await waitFor(() => queue.jobs.single.state == MomentPublishState.failed);
    expect(begins, 0);
    expect(puts, 0);
    queue.revoke();
  });
}
