import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_image_compress/flutter_image_compress.dart';

/// 聊天图片缩略图参数（需求三.1：最长边 ≤800px、体积 ≤100KB）。
const chatImageThumbnailMaxEdge = 800;
const chatImageThumbnailMaxBytes = 100 * 1024;

/// 生成的聊天缩略图：字节 + 实际宽高（写入事件的 thumbnail_info）。
final class ChatThumbnail {
  const ChatThumbnail({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

/// 生成聊天图片消息发送附带的缩略图（JPEG，密文上传由调用方处理）。
///
/// 策略：最长边压到 ≤[chatImageThumbnailMaxEdge]，JPEG 质量自 75 逐级
/// 降至 40；仍超 100KB 则继续降尺寸（600 → 480）。生成失败返回 null，
/// 消息退化为“仅原图附件”（接收端自动回退全量加载，行为兼容旧消息）。
Future<ChatThumbnail?> buildChatImageThumbnail(Uint8List bytes) async {
  try {
    final dims = await decodeImageDimensions(bytes);
    if (dims == null) return null;
    final target = chatThumbnailTargetSize(dims.$1, dims.$2);
    for (final quality in const [75, 60, 50, 40]) {
      final result = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: target.$1,
        minHeight: target.$2,
        quality: quality,
        format: CompressFormat.jpeg,
      );
      if (result.lengthInBytes <= chatImageThumbnailMaxBytes) {
        return ChatThumbnail(
            bytes: result, width: target.$1, height: target.$2);
      }
    }
    // 质量触底仍超限：降尺寸收尾（极端大图/噪点图）。
    for (final edge in const [600, 480]) {
      final shrunk = chatThumbnailTargetSize(dims.$1, dims.$2, maxEdge: edge);
      final result = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: shrunk.$1,
        minHeight: shrunk.$2,
        quality: 40,
        format: CompressFormat.jpeg,
      );
      if (result.lengthInBytes <= chatImageThumbnailMaxBytes) {
        return ChatThumbnail(
            bytes: result, width: shrunk.$1, height: shrunk.$2);
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// 按最长边约束计算缩略图目标尺寸（纯逻辑，只缩不放，至少 1px）。
/// [maxEdge] 缺省为 [chatImageThumbnailMaxEdge]。
(int, int) chatThumbnailTargetSize(int width, int height,
    {int maxEdge = chatImageThumbnailMaxEdge}) {
  final longest = width > height ? width : height;
  if (longest <= maxEdge) {
    return (width < 1 ? 1 : width, height < 1 ? 1 : height);
  }
  final scale = maxEdge / longest;
  return (
    (width * scale).floor().clamp(1, maxEdge),
    (height * scale).floor().clamp(1, maxEdge),
  );
}

/// 解码图片实际像素尺寸（供视频海报帧等场景计算 thumbnail_info）。
Future<(int, int)?> decodeImageDimensions(Uint8List bytes) async {
  ui.Codec? codec;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final dims = (frame.image.width, frame.image.height);
    frame.image.dispose();
    return dims;
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
  }
}
