import 'dart:async';
import 'dart:io';

import 'package:video_compress/video_compress.dart';

/// Maximum plaintext video payload, measured again after encoding.
const maxOriginalVideoBytes = 20 * 1024 * 1024;

final class GroupVideoTooLargeException implements Exception {
  const GroupVideoTooLargeException(
      {this.estimated = false, this.compressed = false});
  final bool estimated;
  final bool compressed;
  @override
  String toString() => estimated
      ? '视频时长过长，预计压缩后仍超过20MB，请裁剪后重试'
      : compressed
          ? '视频压缩后仍超过20MB，请裁剪或选择较短的视频'
          : '视频大小不能超过20MB';
}

final class VideoCompressionException implements Exception {
  const VideoCompressionException();
  @override
  String toString() => '视频压缩失败，请重新选择或使用其他视频';
}

void validateGroupVideoSize(int size) {
  if (size > maxOriginalVideoBytes) throw const GroupVideoTooLargeException();
}

Future<void> validateGroupVideoFile(File file) async =>
    validateGroupVideoSize(await file.length());

// Kept for source compatibility; output size is now the retry criterion.
const videoCompressionTargetRatio = 0.5;
const videoCompressionRetryThresholdBytes = 2 * 1024 * 1024;
bool shouldRetryVideoAtLowerQuality({
  required int originalBytes,
  required int compressedBytes,
}) =>
    compressedBytes > maxOriginalVideoBytes;

/// H.264 + AAC profiles. Duration affects the aggressive bitrate budget only;
/// encoder rate control is approximate and never replaces measuring the file.
final class ChatVideoProfile {
  const ChatVideoProfile(this.maxDimension, this.videoBitrate, this.frameRate,
      this.audioBitrate, this.audioSampleRate);
  final int maxDimension;
  final int videoBitrate;
  final int frameRate;
  final int audioBitrate;
  final int audioSampleRate;
  static const normal = ChatVideoProfile(640, 1200000, 24, 64000, 44100);
  static const minimumVideoBitrate = 160000;
  static const aggressiveAudioBitrate = 32000;

  static ChatVideoProfile aggressive(int? durationMs) {
    final budget = durationMs != null && durationMs > 0
        ? (maxOriginalVideoBytes * 8 * 1000 * 0.9 / durationMs).floor() -
            aggressiveAudioBitrate
        : 400000;
    return ChatVideoProfile(320, budget.clamp(minimumVideoBitrate, 400000), 12,
        aggressiveAudioBitrate, 22050);
  }
}

bool videoCannotFitEstimate(
    {required int originalBytes, required int? durationMs}) {
  if (originalBytes <= maxOriginalVideoBytes ||
      durationMs == null ||
      durationMs <= 0) {
    return false;
  }
  // Conservative floor for the supported readable video/audio quality. This is
  // a preflight policy, not a promise about an encoder's final byte count.
  return durationMs /
          1000 *
          (ChatVideoProfile.minimumVideoBitrate +
              ChatVideoProfile.aggressiveAudioBitrate) /
          8 >
      maxOriginalVideoBytes;
}

/// 人类可读体积（用于回退提示等场景）。
String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return '${mb >= 10 ? mb.round() : double.parse(mb.toStringAsFixed(1))}M';
  }
  final kb = (bytes / 1024).ceil();
  return '${kb < 1 ? 1 : kb}K';
}

/// 视频压缩产物解析结果：
/// [usedCompressed] 为 false 表示压缩版不可用，已回退原始视频（需明确提示）。
final class VideoRendition {
  const VideoRendition({
    required this.file,
    required this.usedCompressed,
    this.compressionRatio,
    this.fallbackNotice,
    this.durationMs,
  });

  final File file;
  final bool usedCompressed;

  /// 压缩产物/原件体积比（<1 为正收益）；回退原图时为 null。
  final double? compressionRatio;

  /// 回退原图时的用户提示文案（明确告知，不静默）。
  final String? fallbackNotice;

  /// 转码元数据携带的视频时长（毫秒，来自压缩器）；未知为 null
  /// （相册路径的时长来自媒体库，不经此字段）。
  final int? durationMs;

  /// Call after bytes/poster have been consumed. Originals are never owned.
  Future<void> dispose() async {
    if (usedCompressed && await file.exists()) await file.delete();
  }
}

// 视频封面帧提取已迁移至 video_poster_extractor.dart：
// 多时间点（200/500/1000/2000ms）+ 近黑帧跳过，替代旧单点 200ms
// 抽帧（片头黑帧导致接收端整卡黑块）。

/// Both gallery and camera use this serialized two-pass pipeline. The plugin
/// has a process-wide encoder, so preview and send work cannot run it together.
Future<void> _videoEncodingQueue = Future<void>.value();
Future<VideoRendition> transcodeForChat(File origin,
    {void Function(double progress)? onProgress}) {
  final operation = _videoEncodingQueue
      .then((_) => _transcodeForChat(origin, onProgress: onProgress));
  _videoEncodingQueue =
      operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  return operation;
}

Future<VideoRendition> _transcodeForChat(File origin,
    {void Function(double progress)? onProgress}) async {
  final originSize = await origin.length();
  if (originSize <= 0) throw const VideoCompressionException();
  int? durationMs;
  try {
    final info = await VideoCompress.getMediaInfo(origin.path)
        .timeout(const Duration(seconds: 15));
    if (info.duration != null &&
        info.duration!.isFinite &&
        info.duration! > 0) {
      durationMs = info.duration!.round();
    }
  } catch (_) {
    /* Unknown metadata must not reject a potentially valid video. */
  }
  if (videoCannotFitEstimate(
      originalBytes: originSize, durationMs: durationMs)) {
    throw const GroupVideoTooLargeException(estimated: true);
  }
  final generated = <File>[];
  File? accepted;
  var hadOversize = false;
  final subscription = VideoCompress.compressProgress$.subscribe((value) {
    final normalized = value > 1 ? value / 100 : value;
    if (normalized >= 0 && normalized <= 1) onProgress?.call(normalized);
  });
  try {
    for (final profile in [
      ChatVideoProfile.normal,
      ChatVideoProfile.aggressive(durationMs)
    ]) {
      File? output;
      try {
        final info = await VideoCompress.compressVideo(origin.path,
            quality: VideoQuality.Res640x480Quality,
            deleteOrigin: false,
            includeAudio: true,
            frameRate: profile.frameRate,
            maxDimension: profile.maxDimension,
            videoBitrate: profile.videoBitrate,
            audioBitrate: profile.audioBitrate,
            audioSampleRate: profile.audioSampleRate,
            audioChannels: 1);
        output = info?.file;
        if (output != null && output.absolute.path != origin.absolute.path) {
          generated.add(output);
        }
        if (info?.isCancel == true ||
            output == null ||
            output.absolute.path == origin.absolute.path ||
            !await output.exists()) {
          continue;
        }
        final size = await output.length();
        if (size > maxOriginalVideoBytes) {
          hadOversize = true;
          await output.delete();
          continue;
        }
        if (size <= 0) continue;
        accepted = output;
        return VideoRendition(
            file: output,
            usedCompressed: true,
            compressionRatio: size / originSize,
            durationMs: durationMs ?? info?.duration?.round());
      } catch (_) {
        // Native failure is retried with lower settings; no original bypass.
      }
    }
    if (hadOversize) throw const GroupVideoTooLargeException(compressed: true);
    throw const VideoCompressionException();
  } finally {
    subscription.unsubscribe();
    for (final file in generated) {
      if (file.path != accepted?.path && await file.exists()) {
        await file.delete();
      }
    }
  }
}
