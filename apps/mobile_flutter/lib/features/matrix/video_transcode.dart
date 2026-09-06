import 'dart:async';
import 'dart:io';

import 'package:video_compress/video_compress.dart';

/// 原图模式下单个视频的大小上限：超过则拦截发送并提示
/// （压缩发送不受该限制，压缩本身即为减轻服务器负担）。
const maxOriginalVideoBytes = 20 * 1024 * 1024;

/// 视频压缩策略常量：
/// - 目标减量 ≥50%（体积降为原件一半以下），以 480p 可接受画质为前提；
/// - 未达 50% 且原件较大（>2MB）时允许降档重试一次，仍取更小者；
/// - 移动网络下浏览/上传体积以压缩产物为准，显著降低带宽与存储负担。
const videoCompressionTargetRatio = 0.5;
const videoCompressionRetryThresholdBytes = 2 * 1024 * 1024;

/// 视频压缩策略决策（纯逻辑，可测）：
/// 首次压缩产物未达 ≥50% 减量、且原件较大时，降档再压一次。
bool shouldRetryVideoAtLowerQuality({
  required int originalBytes,
  required int compressedBytes,
}) {
  if (originalBytes <= 0) return false;
  final reductionAchieved =
      compressedBytes < originalBytes * videoCompressionTargetRatio;
  if (reductionAchieved) return false;
  return originalBytes > videoCompressionRetryThresholdBytes;
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
}

// 视频封面帧提取已迁移至 video_poster_extractor.dart：
// 多时间点（200/500/1000/2000ms）+ 近黑帧跳过，替代旧单点 200ms
// 抽帧（片头黑帧导致接收端整卡黑块）。

/// 聊天视频压缩（相册发送与"拍摄"录像共用的同一策略，需求 2）：
///
/// - 首选 640×480（H.264/AAC MP4），目标体积减量 ≥50%（画质可接受前提）；
/// - 未达 ≥50% 且原件 >2MB 时自动降档 `LowQuality` 再压一次，取更小者；
/// - 压缩不可用回退原文件，[VideoRendition.fallbackNotice] 携带明确提示，
///   不静默回退；
/// - [onProgress] 订阅插件转码进度（0~1），供界面展示百分比，避免无反馈。
Future<VideoRendition> transcodeForChat(
  File origin, {
  void Function(double progress)? onProgress,
}) async {
  final originSize = await origin.length();
  final progressSubscription = onProgress == null
      ? null
      : VideoCompress.compressProgress$.subscribe((value) {
          final normalized = value > 1 ? value / 100 : value;
          if (normalized >= 0 && normalized <= 1) onProgress(normalized);
        });
  try {
    File? compressed;
    double? durationMs;
    try {
      final info = await VideoCompress.compressVideo(
        origin.path,
        quality: VideoQuality.Res640x480Quality,
        frameRate: 24,
      );
      compressed = info?.file;
      durationMs = info?.duration;
    } catch (_) {
      compressed = null;
    } finally {
      await _cancelCompressionQuietly();
    }

    if (compressed != null) {
      final firstPassSize = await compressed.length();
      if (shouldRetryVideoAtLowerQuality(
        originalBytes: originSize,
        compressedBytes: firstPassSize,
      )) {
        File? lower;
        double? lowerDurationMs;
        try {
          final info = await VideoCompress.compressVideo(
            origin.path,
            quality: VideoQuality.LowQuality,
            frameRate: 24,
          );
          lower = info?.file;
          lowerDurationMs = info?.duration;
        } catch (_) {
          lower = null;
        } finally {
          await _cancelCompressionQuietly();
        }
        if (lower != null && await lower.length() < firstPassSize) {
          compressed = lower;
          durationMs = lowerDurationMs ?? durationMs;
        }
      }
    }

    // 取压缩产物与原件中更小者：压缩产物更大说明重编码无收益。
    if (compressed != null && await compressed.length() < originSize) {
      final size = await compressed.length();
      return VideoRendition(
        file: compressed,
        usedCompressed: true,
        compressionRatio: size / originSize,
        durationMs: durationMs?.round(),
      );
    }
    return VideoRendition(
      file: origin,
      usedCompressed: false,
      fallbackNotice: '压缩版不可用，将发送原始视频（${formatBytes(originSize)}）',
      durationMs: durationMs?.round(),
    );
  } finally {
    progressSubscription?.unsubscribe();
  }
}

/// 尽力而为的取消：平台通道不可用（如测试环境）时不让异常穿透
/// （cancelCompression 返回 Future，异常为异步抛出，须在 async 内捕获）。
Future<void> _cancelCompressionQuietly() async {
  try {
    await VideoCompress.cancelCompression();
  } catch (_) {
    // 忽略：取消失败不影响压缩结果判定。
  }
}
