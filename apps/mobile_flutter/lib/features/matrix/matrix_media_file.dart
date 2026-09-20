import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:matrix/matrix.dart';

/// 构造发送用 MatrixFile，并把 `extraContent['info']` 内联进文件对象。
///
/// BUG 根因（视频消息无封面）：SDK `sendFileEvent` 以
/// `...extraContent` 结尾做浅合并——extraContent 携带 `info` 键会整体
/// 覆盖 SDK 已构建好的 info（内含 thumbnail_file/thumbnail_info/mimetype/
/// size），视频封面随发送丢失。SDK 的 [MatrixVideoFile]/[MatrixAudioFile]
/// 自带 w/h/duration 字段，经 `...file.info` 正确合并——所以时长/宽高
/// 必须走文件对象，绝不经 extraContent 传 `info`。
({MatrixFile file, Map<String, dynamic>? extraContent}) buildMediaFileForSend({
  required Uint8List bytes,
  required String name,
  required String mimeType,
  Map<String, dynamic>? extraContent,
}) {
  final remaining = Map<String, dynamic>.of(extraContent ?? {});
  final rawInfo = remaining.remove('info');
  final info = rawInfo is Map ? rawInfo : const <String, dynamic>{};
  int? intKey(String key) => info[key] is int ? info[key] as int : null;

  final MatrixFile file;
  if (mimeType.startsWith('video/')) {
    file = MatrixVideoFile(
      bytes: bytes,
      name: name,
      mimeType: mimeType,
      width: intKey('w'),
      height: intKey('h'),
      duration: intKey('duration'),
    );
  } else if (mimeType.startsWith('audio/')) {
    file = MatrixAudioFile(
      bytes: bytes,
      name: name,
      mimeType: mimeType,
      duration: intKey('duration'),
    );
  } else if (mimeType.startsWith('image/')) {
    file = MatrixImageFile(
      bytes: bytes,
      name: name,
      mimeType: mimeType,
      width: intKey('w'),
      height: intKey('h'),
    );
  } else {
    file = MatrixFile(bytes: bytes, name: name, mimeType: mimeType);
  }
  return (file: file, extraContent: remaining.isEmpty ? null : remaining);
}

/// BUG-28：补齐图片信封的顶层宽高（info.w/h）。
///
/// 编辑器路径自带缩略图时发送聚合点会跳过缩略图生成，事件顶层可能缺
/// w/h——同一张图两次连续发送会落入不同布局。这里在发送聚合点用解码
/// 尺寸兜底，保证无论缩略图有无，事件 info.w/h 恒存在；调用方声明的
/// 尺寸是权威，已有值时不做任何解码。
Future<MatrixFile> ensureImageDimensionsForSend(MatrixFile file) async {
  if (file is! MatrixImageFile) return file;
  if (file.width != null && file.height != null) return file;
  final bytes = file.bytes;
  if (bytes.isEmpty) return file;
  final ui.Codec codec;
  try {
    codec = await ui.instantiateImageCodec(bytes);
  } catch (_) {
    // 解不出尺寸时保持原样（展示层另有 thumbnail_info 回退）。
    return file;
  }
  final frame = await codec.getNextFrame();
  final width = frame.image.width;
  final height = frame.image.height;
  frame.image.dispose();
  codec.dispose();
  return MatrixImageFile(
    bytes: bytes,
    name: file.name,
    mimeType: file.mimeType,
    width: width,
    height: height,
  );
}
