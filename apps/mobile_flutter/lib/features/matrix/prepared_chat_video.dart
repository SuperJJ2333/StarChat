import 'dart:io';
import 'dart:typed_data';

import '../../core/performance_trace.dart';
import 'video_poster_extractor.dart';
import 'video_transcode.dart';

/// In-memory validated payload: retries never refer to a deleted camera file.
final class PreparedChatVideo {
  const PreparedChatVideo(this.bytes, this.poster, this.durationMs);
  final Uint8List bytes;
  final Uint8List? poster;
  final int? durationMs;
}

/// Only call with an app-owned camera capture, never a user's gallery original.
/// A failed rendition deliberately keeps the original so the account-owned
/// outgoing job can retry; a successful standalone preparation releases it.
Future<PreparedChatVideo> prepareCapturedChatVideo(File capture,
    {void Function(double)? onProgress,
    PerformanceTrace? performanceTrace}) async {
  final prepared = await prepareLocalChatVideo(capture,
      deleteSourceWhenDone: false,
      onProgress: onProgress,
      performanceTrace: performanceTrace);
  if (await capture.exists()) await capture.delete();
  return prepared;
}

/// Serializes compression through [transcodeForChat] and keeps only the
/// bounded compressed bytes. The account-owned outgoing source calls this
/// after admission, so no widget or room lease owns the asynchronous work.
Future<PreparedChatVideo> prepareLocalChatVideo(File source,
    {required bool deleteSourceWhenDone,
    void Function(double)? onProgress,
    PerformanceTrace? performanceTrace}) async {
  VideoRendition? rendition;
  try {
    rendition = await transcodeForChat(source,
        onProgress: onProgress, performanceTrace: performanceTrace);
    final bytes = await rendition.file.readAsBytes();
    validateGroupVideoSize(bytes.length);
    final poster = await extractVideoPoster(rendition.file.path);
    performanceTrace?.mark(PerformanceStage.videoThumbnailDone);
    return PreparedChatVideo(bytes, poster, rendition.durationMs);
  } finally {
    try {
      await rendition?.dispose();
    } finally {
      if (deleteSourceWhenDone && await source.exists()) await source.delete();
    }
  }
}
