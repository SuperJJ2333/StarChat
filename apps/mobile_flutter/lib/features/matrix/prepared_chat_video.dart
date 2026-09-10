import 'dart:io';
import 'dart:typed_data';

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
Future<PreparedChatVideo> prepareCapturedChatVideo(File capture,
    {void Function(double)? onProgress}) async {
  VideoRendition? rendition;
  try {
    rendition = await transcodeForChat(capture, onProgress: onProgress);
    final bytes = await rendition.file.readAsBytes();
    validateGroupVideoSize(bytes.length);
    final poster = await extractVideoPoster(rendition.file.path);
    return PreparedChatVideo(bytes, poster, rendition.durationMs);
  } finally {
    try {
      await rendition?.dispose();
    } finally {
      if (await capture.exists()) await capture.delete();
    }
  }
}
