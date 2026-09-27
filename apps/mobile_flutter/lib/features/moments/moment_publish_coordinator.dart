import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as paths;

import '../../core/business_api_client.dart';
import '../../core/performance_trace.dart';
import '../matrix/gif_image_policy.dart';
import '../matrix/video_poster_extractor.dart';
import '../matrix/video_transcode.dart';
import '../matrix/media_cache.dart';
import '../../ui/moments/moment_media_cache.dart';
import 'moment_image_preprocessor.dart';
import 'moment_draft_store.dart';

/// Posters use a separate, bounded rendition; original videos stay in the sandbox.
Future<Uint8List?> prepareMomentVideoPoster(File video,
    {Uint8List? source}) async {
  try {
    final poster = source != null && source.isNotEmpty
        ? source
        : await extractVideoPoster(video.path,
            positionsMs: const [200, 500, 1000, 2000]);
    if (poster == null || poster.isEmpty || poster.length > 512 * 1024) {
      return null;
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(poster);
    late ({int width, int height}) target;
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        target = targetDimensions(descriptor.width, descriptor.height, 480);
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
    final small = await FlutterImageCompress.compressWithList(poster,
        minWidth: target.width, minHeight: target.height, quality: 80);
    return small.isNotEmpty && small.length <= 512 * 1024 ? small : null;
  } catch (_) {
    return null;
  }
}

enum MomentPublishState { queued, uploading, failed, succeeded, cancelled }

final class MomentPublishJob {
  MomentPublishJob(this.id, Map<String, dynamic> payload, this.media,
      {this.state = MomentPublishState.queued})
      : payload = Map.unmodifiable(payload.map((key, value) =>
            MapEntry(key, value is List ? List.unmodifiable(value) : value)));
  final String id;
  final Map<String, dynamic> payload;
  final List<Map<String, dynamic>> media;
  MomentPublishState state;
  String? message;
  Map<String, dynamic>? published;
  Map<String, dynamic>? expectedDraft;
  int? draftRevision;
}

/// Sources are copied into the sandbox before admission. No gallery handles or
/// credentials are persisted. Video originals are copied as files, not bytes.
final class MomentPublishMedia {
  const MomentPublishMedia(this.file, {this.video = false, this.poster});
  final XFile file;
  final bool video;
  final Uint8List? poster;
}

/// One account owns one sequential worker. Navigation never owns the worker.
final class MomentPublishCoordinator extends ChangeNotifier {
  MomentPublishCoordinator._(this.api, this.session, this.root)
      : _mediaGeneration = MediaCache.accountGeneration(session.accountId);
  final BusinessApiClient api;
  final MomentPublishSession session;
  final Directory root;
  final int _mediaGeneration;
  final _jobs = <MomentPublishJob>[];
  final _preprocessors = <String, MomentImagePreprocessor>{};
  bool _revoked = false, _working = false, _admitting = false;
  Future<void> _writes = Future<void>.value();
  int publishedRevision = 0;
  static const maximumPendingJobs = 4;
  static const maximumSourceBytes = 1024 * 1024 * 1024;
  List<MomentPublishJob> get jobs => List.unmodifiable(_jobs);
  Future<void> flush() => _writes;
  String get accountId => session.accountId;
  bool get active =>
      !_revoked &&
      session.active &&
      _mediaGeneration == MediaCache.accountGeneration(accountId);

  static Future<MomentPublishCoordinator> open(BusinessApiClient api,
      {Directory? directory}) async {
    final session = await api.captureMomentPublishSession();
    final docs = directory ?? await getApplicationDocumentsDirectory();
    final account = sha256.convert(utf8.encode(session.accountId)).toString();
    final root = await Directory(paths.normalize(
            paths.join(docs.absolute.path, 'moments-publish', 'v1', account)))
        .create(recursive: true);
    final queue = MomentPublishCoordinator._(api, session, root);
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory ||
          !RegExp(r'^[a-f0-9-]{36}$').hasMatch(
              entity.uri.pathSegments.where((v) => v.isNotEmpty).last)) {
        continue;
      }
      try {
        final decoded =
            jsonDecode(await File('${entity.path}/job.json').readAsString());
        if (decoded is! Map || decoded['account'] != session.accountId) {
          continue;
        }
        final id = decoded['id'];
        if (id is! String ||
            !RegExp(r'^[a-f0-9-]{36}$').hasMatch(id) ||
            !paths.equals(entity.path, '${root.path}/$id')) {
          continue;
        }
        if (decoded['state'] == 'succeeded' ||
            decoded['state'] == 'cancelled') {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
          continue;
        }
        final media = (decoded['media'] as List)
            .map((m) => Map<String, dynamic>.from(m as Map))
            .toList();
        if (media.length > 9 ||
            media.any((m) => !RegExp(r'^media-[0-8](?:\.ready)?$')
                .hasMatch('${m['file']}'))) {
          continue;
        }
        queue._jobs.add(MomentPublishJob(
            id, Map<String, dynamic>.from(decoded['payload'] as Map), media,
            state: decoded['state'] == 'failed'
                ? MomentPublishState.failed
                : MomentPublishState.queued));
      } catch (_) {
        /* Invalid metadata never authorizes a request or a file path. */
      }
    }
    queue.resume();
    return queue;
  }

  Future<MomentPublishJob> enqueue(
      Map<String, dynamic> payload, List<MomentPublishMedia> sources,
      {MomentImagePreprocessor? preprocessor,
      Map<String, dynamic>? expectedDraft}) async {
    _guard();
    if (_admitting ||
        _jobs
                .where((j) =>
                    j.state != MomentPublishState.succeeded &&
                    j.state != MomentPublishState.cancelled)
                .length >=
            maximumPendingJobs) {
      throw const MomentImageException('已有动态正在发送，请稍后再试');
    }
    if (sources.length +
            (payload['image_urls'] as List? ?? []).length +
            (payload['video_urls'] as List? ?? []).length >
        9) {
      throw const MomentImageException('最多只能发布9个图片或视频');
    }
    // Freeze the invocation before sandbox IO yields to hydration or another editor.
    final frozen =
        Map<String, dynamic>.from(jsonDecode(jsonEncode(payload)) as Map);
    final frozenDraft = expectedDraft == null
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(jsonEncode(expectedDraft)) as Map);
    final draftRevision = MomentDraftStores.editingRevision;
    _admitting = true;
    final id = api.newIdempotencyKey();
    final directory = Directory('${root.path}/$id');
    try {
      var retained = 0;
      await for (final item in root.list(recursive: true, followLinks: false)) {
        if (item is File) retained += await item.length();
      }
      final sizes = <int>[];
      for (final source in sources) {
        final size = await source.file.length();
        if (size <= 0 || (!source.video && size > 20 * 1024 * 1024)) {
          throw const MomentImageException('图片大小不能超过20MB，且文件不能为空');
        }
        retained += size;
        if (retained > maximumSourceBytes) {
          throw const MomentImageException('待发送素材过多，请等待现有动态发送完成');
        }
        sizes.add(size);
      }
      await directory.create();
      final media = <Map<String, dynamic>>[];
      for (var i = 0; i < sources.length; i++) {
        _guard();
        final source = sources[i];
        final path = '${directory.path}/media-$i';
        await source.file.saveTo(path);
        _guard();
        if (await File(path).length() != sizes[i]) {
          throw const MomentImageException('素材保存失败，请重新选择');
        }
        final poster = source.poster;
        if (poster != null &&
            poster.isNotEmpty &&
            poster.length <= 512 * 1024) {
          await File('$path.poster-source').writeAsBytes(poster, flush: true);
        }
        media.add({
          'file': 'media-$i',
          'video': source.video,
          'mime': source.file.mimeType,
          'prepared': false
        });
      }
      final job = MomentPublishJob(id, frozen, media);
      job.draftRevision = draftRevision;
      job.expectedDraft = frozenDraft;
      await _persist(job);
      _guard();
      if (preprocessor != null) _preprocessors[id] = preprocessor;
      _jobs.add(job);
      notifyListeners();
      resume();
      return job;
    } catch (_) {
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    } finally {
      _admitting = false;
    }
  }

  void _guard() {
    if (!active) throw const MomentImageException('账号已切换，发送任务已暂停');
  }

  Future<void> _persist(MomentPublishJob job) {
    final write = _writes.then((_) async {
      final path = '${root.path}/${job.id}/job.json';
      final file = File('$path.tmp');
      await file.writeAsString(
          jsonEncode({
            'account': accountId,
            'id': job.id,
            'payload': job.payload,
            if (job.expectedDraft != null) 'expected_draft': job.expectedDraft,
            'media': job.media,
            'state': job.state.name
          }),
          flush: true);
      await file.rename(path);
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return write;
  }

  void resume() {
    if (_working || !active) return;
    _working = true;
    unawaited(_work().whenComplete(() {
      _working = false;
      if (active && _jobs.any((j) => j.state == MomentPublishState.queued)) {
        resume();
      }
    }));
  }

  Future<void> _work() async {
    for (final job in _jobs.toList()) {
      if (!active) return;
      if (job.state != MomentPublishState.queued) continue;
      job.state = MomentPublishState.uploading;
      notifyListeners();
      final trace = PerformanceTraceRecorder.instance
          .start(PerformanceOperationType.messageSend);
      try {
        final imageUrls =
            List<String>.from(job.payload['image_urls'] as List? ?? []);
        final videoUrls =
            List<String>.from(job.payload['video_urls'] as List? ?? []);
        final posterIds = List<String?>.from(
            job.payload['video_poster_media_ids'] as List? ??
                List<String?>.filled(videoUrls.length, null));
        for (var i = 0; i < job.media.length; i++) {
          _guardJob(job);
          final media = job.media[i];
          final ready = await _prepare(job, i, trace);
          _guardJob(job);
          trace.mark(PerformanceStage.videoUploadStarted);
          final result = await trace.runChildOperations(() =>
              _upload(job, media, ready, '$i', media['mime'] as String, false));
          trace.mark(PerformanceStage.videoUploadDone);
          _guardJob(job);
          if (media['video'] == true) {
            videoUrls
                .add((result['media_ref'] ?? result['media_url']) as String);
            try {
              final cacheKey = result['media_cache_key'] as String?;
              if (cacheKey != null) {
                await MomentMediaCache.storeUploadedVideo(
                    result['media_url'] as String, await ready.readAsBytes(),
                    cacheKey: cacheKey,
                    accountKey: 'matrix:$accountId',
                    trustedOrigin: api.baseUri.origin,
                    expectedAccountGeneration: _mediaGeneration,
                    mimeType: media['mime'] as String);
              }
            } catch (_) {/* Cache pressure must not fail an accepted upload. */}
            final poster = File('${root.path}/${job.id}/media-$i.poster');
            if (await poster.exists()) {
              Map<String, dynamic>? posterResult;
              try {
                posterResult = await _upload(
                    job, media, poster, 'poster-$i', 'image/jpeg', true);
              } on BusinessApiException catch (error) {
                if (error.statusCode != 404) rethrow;
              }
              posterIds.add(posterResult?['id'] as String?);
              try {
                await MomentMediaCache.storeVideoPoster(
                    result['media_url'] as String, await poster.readAsBytes(),
                    cacheKey: result['media_cache_key'] as String?,
                    accountKey: 'matrix:$accountId',
                    trustedOrigin: api.baseUri.origin,
                    expectedAccountGeneration: _mediaGeneration);
              } catch (_) {}
            } else {
              posterIds.add(null);
            }
          } else {
            imageUrls
                .add((result['media_ref'] ?? result['media_url']) as String);
          }
        }
        // A previous video may have completed before a long later transcode.
        // Renew capabilities immediately before publishing without re-uploading.
        var imageIndex = (job.payload['image_urls'] as List? ?? []).length;
        var videoIndex = (job.payload['video_urls'] as List? ?? []).length;
        for (var i = 0; i < job.media.length; i++) {
          final media = job.media[i];
          final result = await _upload(
              job,
              media,
              File('${root.path}/${job.id}/${media['file']}'),
              '$i',
              media['mime'] as String,
              false);
          if (media['video'] == true) {
            videoUrls[videoIndex++] =
                (result['media_ref'] ?? result['media_url']) as String;
          } else {
            imageUrls[imageIndex++] =
                (result['media_ref'] ?? result['media_url']) as String;
          }
        }
        _guardJob(job);
        final body = {
          ...job.payload,
          'image_urls': imageUrls,
          if (videoUrls.isNotEmpty) 'video_urls': videoUrls,
          if (posterIds.any((p) => p != null))
            'video_poster_media_ids': posterIds
        };
        job.published = await trace.runChildOperations(
            () => api.postMomentTask(session, '/moments', body, job.id));
        _guardJob(job);
        job.state = MomentPublishState.succeeded;
        try {
          await _persist(job);
        } catch (_) {/* Server success remains authoritative. */}
        publishedRevision++;
        notifyListeners();
        // Draft cleanup is best effort and cannot turn a published post into a failure.
        try {
          if (job.draftRevision != null &&
              job.draftRevision == MomentDraftStores.editingRevision) {
            final cleared = await api.clearMomentTaskDraft(session,
                job.expectedDraft ?? job.payload, '${job.id}:draft-cleanup');
            if (cleared &&
                job.draftRevision == MomentDraftStores.editingRevision &&
                await api.isMomentPublishSessionCurrent(session) &&
                MomentDraftStores.shared?.read()?.scope ==
                    'matrix:$accountId') {
              await MomentDraftStores.shared?.clear();
            }
          }
        } catch (_) {}
        try {
          await Directory('${root.path}/${job.id}').delete(recursive: true);
        } catch (_) {}
        _preprocessors.remove(job.id);
        trace.finish();
      } catch (error) {
        trace.finish(result: PerformanceResult.failed);
        if (job.state != MomentPublishState.cancelled &&
            job.state != MomentPublishState.succeeded) {
          job.state = MomentPublishState.failed;
          job.message = error is MomentImageException
              ? error.message
              : error is BusinessApiException
                  ? error.message
                  : '发送失败，内容已保留，请重试';
          try {
            await _persist(job);
          } catch (_) {}
        }
        notifyListeners();
      } finally {
        trace.dispose();
      }
    }
    while (_jobs
            .where((j) =>
                j.state == MomentPublishState.succeeded ||
                j.state == MomentPublishState.cancelled)
            .length >
        8) {
      _jobs.remove(_jobs.firstWhere((j) =>
          j.state == MomentPublishState.succeeded ||
          j.state == MomentPublishState.cancelled));
    }
  }

  void _guardJob(MomentPublishJob job) {
    _guard();
    if (job.state == MomentPublishState.cancelled) {
      throw const MomentImageException('发送已取消');
    }
  }

  Future<File> _prepare(
      MomentPublishJob job, int i, PerformanceTrace trace) async {
    final media = job.media[i];
    final directory = '${root.path}/${job.id}';
    final source = File('$directory/${media['file']}');
    if (media['prepared'] == true) return source;
    final output = File('$directory/media-$i.ready');
    trace.mark(PerformanceStage.videoPrepareStarted);
    trace.setMedia(
        type: media['video'] == true
            ? PerformanceMediaType.video
            : PerformanceMediaType.image);
    Uint8List bytes;
    if (media['video'] == true) {
      final rendition = await transcodeForChat(source, performanceTrace: trace);
      try {
        validateGroupVideoSize(await rendition.file.length());
        await rendition.file.copy(output.path);
        media['mime'] = 'video/mp4';
        final posterSource = File('$directory/media-$i.poster-source');
        try {
          final poster = await posterSource.exists()
              ? await posterSource.readAsBytes()
              : null;
          final small =
              await prepareMomentVideoPoster(rendition.file, source: poster);
          if (small != null) {
            await File('$directory/media-$i.poster')
                .writeAsBytes(small, flush: true);
          }
        } catch (_) {/* A missing thumbnail cannot discard a valid video. */}
      } finally {
        await rendition.dispose();
      }
    } else {
      if (await source.length() > 20 * 1024 * 1024) {
        throw const MomentImageException('图片大小不能超过20MB');
      }
      bytes = await source.readAsBytes();
      final gif = isGifBytes(bytes);
      if (gif) validateGifStructureForSend(bytes);
      final processed = gif
          ? bytes
          : await (_preprocessors[job.id] ?? MomentImagePreprocessor())
              .process(bytes);
      if (processed.isEmpty || processed.length > 20 * 1024 * 1024) {
        throw const MomentImageException('图片大小不能超过20MB');
      }
      await output.writeAsBytes(processed, flush: true);
      media['mime'] = gif ? 'image/gif' : 'image/jpeg';
    }
    _guardJob(job);
    media['file'] = 'media-$i.ready';
    media['prepared'] = true;
    trace.mark(PerformanceStage.videoPrepareDone);
    await _persist(job);
    // Replace only our copied source, never the user's album file.
    try {
      await source.delete();
    } catch (_) {}
    return output;
  }

  Future<Map<String, dynamic>> _upload(
      MomentPublishJob job,
      Map<String, dynamic> media,
      File file,
      String key,
      String mime,
      bool poster) async {
    final generationKey = poster ? 'poster_generation' : 'generation';
    final generation = media[generationKey] as int? ?? 0;
    try {
      return await _uploadAttempt(
          job, media, file, '$key:$generation', mime, poster);
    } on BusinessApiException catch (error) {
      if (error.code == 'MOMENT_MEDIA_EXPIRED' ||
          error.code == 'MEDIA_UPLOAD_EXPIRED') {
        media[generationKey] = generation + 1;
        media.remove(poster ? 'poster_upload' : 'upload');
        media.remove(poster ? 'poster_put' : 'put');
        media.remove(poster ? 'poster_result' : 'result');
        await _persist(job);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _uploadAttempt(
      MomentPublishJob job,
      Map<String, dynamic> media,
      File file,
      String key,
      String mime,
      bool poster) async {
    _guardJob(job);
    final completedKey = poster ? 'poster_result' : 'result';
    if (media[completedKey] case final Map saved) {
      final renewed = await api.postMomentTask(
          session,
          '/moments/media/uploads/${saved['id']}/complete',
          {},
          '${job.id}:complete:$key');
      _guardJob(job);
      if (renewed['status'] != 'COMPLETED' || renewed['media_url'] is! String) {
        throw const MomentImageException('媒体尚未准备好，请重试');
      }
      return {
        ...Map<String, dynamic>.from(saved),
        'media_url': renewed['media_url'],
        if (renewed['media_ref'] is String) 'media_ref': renewed['media_ref'],
      };
    }
    final idKey = poster ? 'poster_upload' : 'upload';
    if (media[idKey] == null) {
      final byteSize = await file.length();
      _guardJob(job);
      final begun = await api.postMomentTask(
          session,
          poster ? '/moments/video-posters/uploads' : '/moments/media/uploads',
          {
            'file_name': poster
                ? 'poster.jpg'
                : mime == 'video/mp4'
                    ? 'video.mp4'
                    : mime == 'image/gif'
                        ? 'image.gif'
                        : 'image.jpg',
            'mime_type': mime,
            'byte_size': byteSize
          },
          '${job.id}:begin:$key');
      _guardJob(job);
      media[idKey] = begun['id'] as String;
      await _persist(job);
    }
    final id = media[idKey] as String;
    final putKey = poster ? 'poster_put' : 'put';
    if (media[putKey] != true) {
      final bytes = await file.readAsBytes();
      if (bytes.length > (poster ? 512 * 1024 : 20 * 1024 * 1024)) {
        throw const MomentImageException('媒体大小超过限制');
      }
      _guardJob(job);
      try {
        await api.putMomentTask(session, id, bytes, mime);
      } on BusinessApiException catch (error) {
        if (error.code != 'MOMENT_MEDIA_COMPLETED') rethrow;
      }
      _guardJob(job);
      media[putKey] = true;
      await _persist(job);
    }
    _guardJob(job);
    final completed = await api.postMomentTask(session,
        '/moments/media/uploads/$id/complete', {}, '${job.id}:complete:$key');
    _guardJob(job);
    if (completed['status'] != 'COMPLETED' ||
        completed['media_url'] is! String) {
      throw const MomentImageException('媒体尚未准备好，请重试');
    }
    media[completedKey] = {
      'id': id,
      'media_url': completed['media_url'],
      if (completed['media_ref'] is String) 'media_ref': completed['media_ref'],
      if (completed['media_cache_key'] != null)
        'media_cache_key': completed['media_cache_key']
    };
    await _persist(job);
    return Map<String, dynamic>.from(media[completedKey] as Map);
  }

  Future<void> retry(String id) async {
    _guard();
    final job = _jobs.firstWhere((j) => j.id == id);
    if (job.state != MomentPublishState.failed) return;
    job.state = MomentPublishState.queued;
    job.message = null;
    await _persist(job);
    notifyListeners();
    resume();
  }

  Future<void> cancel(String id) async {
    final job = _jobs.firstWhere((j) => j.id == id);
    if (job.state == MomentPublishState.succeeded) return;
    job.state = MomentPublishState.cancelled;
    notifyListeners();
    // In-flight HTTP may finish; its guard prevents every subsequent operation.
    await _writes;
    final directory = Directory('${root.path}/$id');
    if (await directory.exists()) await directory.delete(recursive: true);
    _preprocessors.remove(id);
  }

  void revoke() {
    _revoked = true;
    notifyListeners();
  }
}

abstract final class MomentPublishQueues {
  static final _queues =
      <BusinessApiClient, Future<MomentPublishCoordinator>>{};
  static Future<MomentPublishCoordinator> open(BusinessApiClient api) async {
    final existing = _queues[api];
    if (existing != null) {
      final queue = await existing;
      if (queue.active &&
          await api.isMomentPublishSessionCurrent(queue.session)) {
        return queue;
      }
      queue.revoke();
      if (identical(_queues[api], existing)) _queues.remove(api);
    }
    return _queues.putIfAbsent(
        api,
        () => MomentPublishCoordinator.open(api).catchError((Object error) {
              _queues.remove(api);
              throw error;
            }));
  }

  static Future<void> revoke(BusinessApiClient api) async {
    final queue = _queues.remove(api);
    if (queue != null) {
      try {
        (await queue).revoke();
      } catch (_) {}
    }
  }
}
