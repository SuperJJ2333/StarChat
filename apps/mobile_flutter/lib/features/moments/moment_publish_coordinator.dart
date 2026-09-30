import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as paths;

import '../../core/business_api_client.dart';
import '../../core/chat_diagnostics.dart';
import '../../core/performance_trace.dart';
import '../media/media_asset_gateway.dart';
import '../matrix/video_poster_extractor.dart';
import '../matrix/video_transcode.dart';
import '../matrix/media_cache.dart';
import '../../ui/moments/moment_media_cache.dart';
import 'moment_image_preprocessor.dart';
import 'moment_draft_store.dart';

typedef MomentPosterExtractor = Future<Uint8List?> Function(
    File file, List<int> positionsMs);

/// Only closed failure types reach diagnostics; exception text stays local.
ChatDiagnosticError momentDiagnosticReason(Object error) => switch (error) {
      TimeoutException() => ChatDiagnosticError.timeout,
      SocketException() ||
      HandshakeException() ||
      http.ClientException() =>
        ChatDiagnosticError.network,
      GroupVideoTooLargeException() => ChatDiagnosticError.size,
      VideoCompressionException() ||
      FormatException() =>
        ChatDiagnosticError.format,
      MomentImageException(message: '媒体大小超过限制') => ChatDiagnosticError.size,
      MomentImageException(message: '视频封面生成失败，内容已保留，请重试') =>
        ChatDiagnosticError.format,
      MomentImageException(message: '媒体尚未准备好，请重试') =>
        ChatDiagnosticError.rejected,
      BusinessApiException(statusCode: 408 || 504) =>
        ChatDiagnosticError.timeout,
      BusinessApiException(statusCode: 413) => ChatDiagnosticError.size,
      BusinessApiException() => ChatDiagnosticError.rejected,
      _ => ChatDiagnosticError.unknown,
    };

void recordMomentFailure(
    ChatDiagnosticStage stage, ChatDiagnosticError reason, Duration elapsed,
    {int? status}) {
  ChatDiagnostics.instance
      .record(stage: stage, error: reason, elapsed: elapsed, status: status);
}

String _momentFailureMessage(ChatDiagnosticStage stage) => switch (stage) {
      ChatDiagnosticStage.momentPrepare => '视频准备失败，内容已保留，请重试',
      ChatDiagnosticStage.momentVideoBegin ||
      ChatDiagnosticStage.momentVideoPut ||
      ChatDiagnosticStage.momentVideoComplete =>
        '视频上传失败，内容已保留，请重试',
      ChatDiagnosticStage.momentPosterExtract => '视频封面生成失败，内容已保留，请重试',
      ChatDiagnosticStage.momentPosterBegin ||
      ChatDiagnosticStage.momentPosterPut ||
      ChatDiagnosticStage.momentPosterComplete =>
        '视频封面暂不可用，请稍后重试',
      _ => '发送失败，内容已保留，请重试',
    };

// Includes local poster bytes and task-journal writes, not only frame decoding.
ChatDiagnosticStage _momentLocalStage(bool poster) => poster
    ? ChatDiagnosticStage.momentPosterExtract
    : ChatDiagnosticStage.momentPrepare;

PerformanceSizeBucket _momentSizeBucket(int bytes) => switch (bytes) {
      <= 0 => PerformanceSizeBucket.zero,
      <= 64 * 1024 => PerformanceSizeBucket.tiny,
      <= 1024 * 1024 => PerformanceSizeBucket.small,
      <= 10 * 1024 * 1024 => PerformanceSizeBucket.medium,
      <= 100 * 1024 * 1024 => PerformanceSizeBucket.large,
      _ => PerformanceSizeBucket.huge,
    };

/// Posters use a separate, bounded rendition; original videos stay in the sandbox.
Future<Uint8List?> prepareMomentVideoPoster(File video,
    {Uint8List? source, MomentPosterExtractor? extract}) async {
  Future<Uint8List?> attempt(List<int> positions) async {
    try {
      return extract == null
          ? extractVideoPoster(video.path, positionsMs: positions)
          : extract(video, positions);
    } catch (_) {
      return null;
    }
  }

  final frame = await attempt(const [0, 200, 500, 1000, 2000]);
  if (frame != null && frame.isNotEmpty) {
    final encoded = await _encodeMomentPoster(frame);
    if (encoded != null) return encoded;
    // The first frame can have a valid header but fail during full encoding.
    final later = await attempt(const [200, 500, 1000, 2000]);
    if (later != null && later.isNotEmpty) {
      final encodedLater = await _encodeMomentPoster(later);
      if (encodedLater != null) return encodedLater;
    }
  }
  return source == null || source.isEmpty ? null : _encodeMomentPoster(source);
}

Future<Uint8List?> _encodeMomentPoster(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        if (descriptor.width * descriptor.height > 16 * 1024 * 1024) {
          return null;
        }
        final target =
            targetDimensions(descriptor.width, descriptor.height, 480);
        final small = await FlutterImageCompress.compressWithList(bytes,
            minWidth: target.width,
            minHeight: target.height,
            quality: 80,
            format: CompressFormat.jpeg);
        if (small.isEmpty || small.length > maxMomentImageBytes) return null;
        final asset = await MediaAssetGateway.inspect(small,
            mimeType: 'image/jpeg', filename: 'poster.jpg');
        return asset.mimeType == 'image/jpeg' ? asset.bytes : null;
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  } catch (_) {
    return null;
  }
}

enum MomentPublishState { queued, uploading, failed, succeeded, cancelled }

void _requirePairedVideoPosters(Map<String, dynamic> payload) {
  final videos = payload['video_urls'] as List? ?? const [];
  if (videos.isEmpty) return;
  final posters = payload['video_poster_media_ids'] as List? ?? const [];
  if (posters.length != videos.length ||
      posters.any((id) => id is! String || id.isEmpty)) {
    throw const MomentImageException('视频封面暂不可用，请稍后重试');
  }
}

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
  final _preparations = <String, Future<void>>{};
  final _cancellations = <String, Future<void>>{};
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
            media.any((m) => !RegExp(r'^media-[0-8](?:\.ready(?:-v2)?)?$')
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
    _requirePairedVideoPosters(payload);
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
    if (job.state == MomentPublishState.cancelled) return Future.value();
    final write = _writes.then((_) async {
      // A late HTTP failure/continuation cannot recreate a cancelled journal.
      if (job.state == MomentPublishState.cancelled) return;
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
      final diagnosticSession = ChatDiagnostics.instance;
      final diagnosticGeneration = diagnosticSession.sessionGeneration;
      ChatDiagnosticStage? failureStage;
      Object? originalFailure;
      final stageWatch = Stopwatch();
      void enterStage(ChatDiagnosticStage? stage) {
        failureStage = stage;
        stageWatch
          ..reset()
          ..start();
      }

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
          final isVideo = media['video'] == true;
          enterStage(isVideo ? ChatDiagnosticStage.momentPrepare : null);
          final ready = await _prepare(job, i, trace,
              onStage: isVideo ? enterStage : null);
          _guardJob(job);
          trace.mark(PerformanceStage.videoUploadStarted);
          final result = await trace.runChildOperations(() => _upload(
              job, media, ready, '$i', media['mime'] as String, false,
              onStage: isVideo ? enterStage : null));
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
            enterStage(ChatDiagnosticStage.momentPosterExtract);
            if (!await poster.exists()) {
              throw const MomentImageException('视频封面生成失败，内容已保留，请重试');
            }
            final Map<String, dynamic> posterResult;
            try {
              posterResult = await _upload(
                  job, media, poster, 'poster-$i', 'image/jpeg', true,
                  onStage: enterStage);
            } on Exception catch (error) {
              if (error is BusinessApiException &&
                  (error.statusCode == 401 || error.statusCode == 403)) {
                rethrow;
              }
              originalFailure = error;
              _guardJob(job);
              if (failureStage == ChatDiagnosticStage.momentPosterExtract) {
                throw const MomentImageException('视频封面生成失败，内容已保留，请重试');
              }
              throw const MomentImageException('视频封面暂不可用，请稍后重试');
            }
            final posterId = posterResult['id'];
            if (posterId is! String || posterId.isEmpty) {
              throw const MomentImageException('视频封面暂不可用，请稍后重试');
            }
            posterIds.add(posterId);
            try {
              await MomentMediaCache.storeVideoPoster(
                  result['media_url'] as String, await poster.readAsBytes(),
                  cacheKey: result['media_cache_key'] as String?,
                  accountKey: 'matrix:$accountId',
                  trustedOrigin: api.baseUri.origin,
                  expectedAccountGeneration: _mediaGeneration);
            } catch (_) {}
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
          final isVideo = media['video'] == true;
          enterStage(isVideo ? ChatDiagnosticStage.momentVideoComplete : null);
          final result = await _upload(
              job,
              media,
              File('${root.path}/${job.id}/${media['file']}'),
              '$i',
              media['mime'] as String,
              false,
              onStage: isVideo ? enterStage : null);
          if (media['video'] == true) {
            videoUrls[videoIndex++] =
                (result['media_ref'] ?? result['media_url']) as String;
          } else {
            imageUrls[imageIndex++] =
                (result['media_ref'] ?? result['media_url']) as String;
          }
        }
        _guardJob(job);
        enterStage(
            videoUrls.isNotEmpty ? ChatDiagnosticStage.momentPublish : null);
        final body = {
          ...job.payload,
          'image_urls': imageUrls,
          if (videoUrls.isNotEmpty) 'video_urls': videoUrls,
          if (posterIds.any((p) => p != null))
            'video_poster_media_ids': posterIds
        };
        _requirePairedVideoPosters(body);
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
        final stage = failureStage;
        final cause = originalFailure ?? error;
        if (stage != null &&
            job.state != MomentPublishState.cancelled &&
            active &&
            identical(ChatDiagnostics.instance, diagnosticSession) &&
            diagnosticSession.sessionGeneration == diagnosticGeneration) {
          recordMomentFailure(
              stage, momentDiagnosticReason(cause), stageWatch.elapsed,
              status: cause is BusinessApiException ? cause.statusCode : null);
        }
        if (job.state != MomentPublishState.cancelled &&
            job.state != MomentPublishState.succeeded) {
          job.state = MomentPublishState.failed;
          job.message = error is MomentImageException
              ? error.message
              : error is GroupVideoTooLargeException
                  ? '视频大小不能超过20MB'
                  : error is VideoCompressionException
                      ? '视频压缩失败，请重新选择或使用其他视频'
                      : stage != null && error is! BusinessApiException
                          ? _momentFailureMessage(stage)
                          : stage != null &&
                                  error is BusinessApiException &&
                                  error.statusCode != 401 &&
                                  error.statusCode != 403
                              ? _momentFailureMessage(stage)
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

  static const _legacyImageReselect =
      MomentImageException('旧图片上传无法按当前体积或格式要求继续，内容已保留，请取消该任务并重新选择图片');

  Future<void> _guardPreparedJob(MomentPublishJob job) async {
    _guardJob(job);
    if (!await api.isMomentPublishSessionCurrent(session)) {
      throw const MomentImageException('账号已切换，发送任务已暂停');
    }
    _guardJob(job);
  }

  Future<File> _prepare(MomentPublishJob job, int i, PerformanceTrace trace,
      {void Function(ChatDiagnosticStage)? onStage}) async {
    final finished = Completer<void>();
    _preparations[job.id] = finished.future;
    try {
      return await _prepareSource(job, i, trace, onStage: onStage);
    } finally {
      _preparations.remove(job.id);
      finished.complete();
    }
  }

  Future<File> _prepareSource(
      MomentPublishJob job, int i, PerformanceTrace trace,
      {void Function(ChatDiagnosticStage)? onStage}) async {
    final media = job.media[i];
    final directory = '${root.path}/${job.id}';
    final source = File('$directory/${media['file']}');
    _guardJob(job);
    Uint8List? preparedBytes;
    if (media['prepared'] == true) {
      if (media['video'] == true ||
          media['result'] is Map ||
          media['put'] == true) {
        // Historical confirmed media is an immutable reference, not new intake.
        return source;
      }
      if (await source.length() > 20 * 1024 * 1024) {
        if (media['upload'] != null) throw _legacyImageReselect;
        throw const MomentImageException('图片大小不能超过20MB');
      }
      await _guardPreparedJob(job);
      final bytes = await MediaAssetGateway.readOriginal(source.readAsBytes);
      preparedBytes = bytes;
      await _guardPreparedJob(job);
      final MediaAsset asset;
      try {
        asset = await MediaAssetGateway.inspect(bytes,
            mimeType: media['mime'] as String, filename: 'moment.jpg');
      } on FormatException {
        if (media['upload'] != null) throw _legacyImageReselect;
        rethrow;
      }
      await _guardPreparedJob(job);
      if (media['upload'] != null) {
        // An interrupted PUT may have reached the server. Its begin declaration
        // and idempotency identity cannot be changed or silently restarted.
        if (bytes.length > maxMomentImageBytes ||
            asset.mimeType != media['mime']) {
          throw _legacyImageReselect;
        }
        return source;
      }
      if (bytes.length <= maxMomentImageBytes) {
        media['mime'] = asset.mimeType;
        await _persist(job);
        await _guardPreparedJob(job);
        return source;
      }
    }
    // Old prepared input may itself be media-i.ready. Persist a distinct
    // replacement before releasing the obsolete copied source.
    final outputName = paths.basename(source.path) == 'media-$i.ready'
        ? 'media-$i.ready-v2'
        : 'media-$i.ready';
    final output = File('$directory/$outputName');
    trace.mark(PerformanceStage.videoPrepareStarted);
    trace.setMedia(
        type: media['video'] == true
            ? PerformanceMediaType.video
            : PerformanceMediaType.image);
    Uint8List bytes;
    if (media['video'] == true) {
      final rendition = await transcodeForChat(source, performanceTrace: trace);
      try {
        _guardJob(job);
        final encodedSize = await rendition.file.length();
        trace.setMedia(size: _momentSizeBucket(encodedSize));
        validateGroupVideoSize(encodedSize);
        await rendition.file.copy(output.path);
        media['mime'] = 'video/mp4';
        final posterSource = File('$directory/media-$i.poster-source');
        Uint8List? poster;
        try {
          poster = await posterSource.exists()
              ? await posterSource.readAsBytes()
              : null;
        } catch (_) {
          // Extraction from this video remains available without the preview.
        }
        onStage?.call(ChatDiagnosticStage.momentPosterExtract);
        final small =
            await prepareMomentVideoPoster(rendition.file, source: poster);
        _guardJob(job);
        if (small == null) {
          throw const MomentImageException('视频封面生成失败，内容已保留，请重试');
        }
        try {
          await File('$directory/media-$i.poster')
              .writeAsBytes(small, flush: true);
        } on FileSystemException {
          throw const MomentImageException('视频封面生成失败，内容已保留，请重试');
        }
      } finally {
        await rendition.dispose();
      }
    } else {
      if (await source.length() > 20 * 1024 * 1024) {
        throw const MomentImageException('图片大小不能超过20MB');
      }
      bytes = preparedBytes ??
          await MediaAssetGateway.readOriginal(source.readAsBytes);
      final processed =
          await (_preprocessors[job.id] ?? MomentImagePreprocessor())
              .process(bytes);
      await _guardPreparedJob(job);
      if (processed.isEmpty || processed.length > maxMomentImageBytes) {
        throw const MomentImageException('图片压缩后仍超过体积上限，请重试');
      }
      trace.setMedia(size: _momentSizeBucket(processed.length));
      final asset = await MediaAssetGateway.inspect(processed,
          mimeType: 'image/jpeg', filename: 'moment.jpg');
      await _guardPreparedJob(job);
      await output.writeAsBytes(processed, flush: true);
      await _guardPreparedJob(job);
      media['mime'] = asset.mimeType;
    }
    _guardJob(job);
    media['file'] = outputName;
    media['prepared'] = true;
    trace.mark(PerformanceStage.videoPrepareDone);
    await _persist(job);
    if (media['video'] != true) await _guardPreparedJob(job);
    // Replace only our copied source, never the user's album file.
    try {
      if (!paths.equals(source.path, output.path)) await source.delete();
    } catch (_) {}
    return output;
  }

  Future<Map<String, dynamic>> _upload(
      MomentPublishJob job,
      Map<String, dynamic> media,
      File file,
      String key,
      String mime,
      bool poster,
      {void Function(ChatDiagnosticStage)? onStage}) async {
    final generationKey = poster ? 'poster_generation' : 'generation';
    final generation = media[generationKey] as int? ?? 0;
    try {
      return await _uploadAttempt(
          job, media, file, '$key:$generation', mime, poster,
          onStage: onStage);
    } on BusinessApiException catch (error) {
      if (error.code == 'MOMENT_MEDIA_EXPIRED' ||
          error.code == 'MEDIA_UPLOAD_EXPIRED') {
        // Oversized historical references cannot become a new ingestion after
        // expiry. Keep their old declaration/reference for explicit user action.
        if (mime.startsWith('image/') &&
            await file.length() > maxMomentImageBytes) {
          _guardJob(job);
          throw _legacyImageReselect;
        }
        media[generationKey] = generation + 1;
        media.remove(poster ? 'poster_upload' : 'upload');
        media.remove(poster ? 'poster_put' : 'put');
        media.remove(poster ? 'poster_result' : 'result');
        try {
          await _persist(job);
        } catch (_) {
          onStage?.call(_momentLocalStage(poster));
          rethrow;
        }
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
      bool poster,
      {void Function(ChatDiagnosticStage)? onStage}) async {
    _guardJob(job);
    final completedKey = poster ? 'poster_result' : 'result';
    if (media[completedKey] case final Map saved) {
      onStage?.call(poster
          ? ChatDiagnosticStage.momentPosterComplete
          : ChatDiagnosticStage.momentVideoComplete);
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
    onStage?.call(_momentLocalStage(poster));
    if (media[idKey] == null) {
      final byteSize = await file.length();
      _guardJob(job);
      if (mime.startsWith('image/') && byteSize > maxMomentImageBytes) {
        throw _legacyImageReselect;
      }
      onStage?.call(poster
          ? ChatDiagnosticStage.momentPosterBegin
          : ChatDiagnosticStage.momentVideoBegin);
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
                        : mime == 'image/png'
                            ? 'image.png'
                            : mime == 'image/webp'
                                ? 'image.webp'
                                : 'image.jpg',
            'mime_type': mime,
            'byte_size': byteSize
          },
          '${job.id}:begin:$key');
      _guardJob(job);
      onStage?.call(_momentLocalStage(poster));
      media[idKey] = begun['id'] as String;
      await _persist(job);
    }
    final id = media[idKey] as String;
    final putKey = poster ? 'poster_put' : 'put';
    if (media[putKey] != true) {
      final bytes = await file.readAsBytes();
      if (bytes.length >
          (mime.startsWith('image/')
              ? maxMomentImageBytes
              : 20 * 1024 * 1024)) {
        throw const MomentImageException('媒体大小超过限制');
      }
      _guardJob(job);
      onStage?.call(poster
          ? ChatDiagnosticStage.momentPosterPut
          : ChatDiagnosticStage.momentVideoPut);
      try {
        await api.putMomentTask(session, id, bytes, mime);
      } on BusinessApiException catch (error) {
        if (error.code != 'MOMENT_MEDIA_COMPLETED') rethrow;
      }
      _guardJob(job);
      media[putKey] = true;
      onStage?.call(_momentLocalStage(poster));
      await _persist(job);
    }
    _guardJob(job);
    onStage?.call(poster
        ? ChatDiagnosticStage.momentPosterComplete
        : ChatDiagnosticStage.momentVideoComplete);
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
    onStage?.call(_momentLocalStage(poster));
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

  Future<void> cancel(String id) {
    final pending = _cancellations[id];
    if (pending != null) return pending;
    final job = _jobs.firstWhere((j) => j.id == id);
    if (job.state == MomentPublishState.succeeded) return Future.value();
    final finished = Completer<void>();
    _cancellations[id] = finished.future;
    job.state = MomentPublishState.cancelled;
    notifyListeners();
    unawaited(_releaseCancelledSource(id).then((_) {
      _cancellations.remove(id);
      finished.complete();
    }, onError: (Object error, StackTrace stack) {
      _cancellations.remove(id);
      finished.completeError(error, stack);
    }));
    return finished.future;
  }

  Future<void> _releaseCancelledSource(String id) async {
    // Source preparation owns ready/poster files as well as its journal. It
    // must settle before directory deletion. HTTP can finish independently;
    // cancellation guards stop its continuation without waiting for the wire.
    await _preparations[id];
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
