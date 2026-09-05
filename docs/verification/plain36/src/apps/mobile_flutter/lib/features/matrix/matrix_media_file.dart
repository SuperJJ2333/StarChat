import 'dart:typed_data';

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
  } else {
    file = MatrixFile(bytes: bytes, name: name, mimeType: mimeType);
  }
  return (file: file, extraContent: remaining.isEmpty ? null : remaining);
}
