import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';

import 'matrix_e2ee_client.dart';

/// 按文件扩展名推断 MIME（file_selector 在部分安卓机型上返回 null），
/// 覆盖常见音视频/图片/文档类型；未识别回退 application/octet-stream。
String mimeFromFileName(String fileName) {
  final extension =
      fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
  const table = {
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'mkv': 'video/x-matroska',
    'avi': 'video/x-msvideo',
    'webm': 'video/webm',
    '3gp': 'video/3gpp',
    'm4v': 'video/x-m4v',
    'gif': 'image/gif',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'wav': 'audio/wav',
    'amr': 'audio/amr',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'doc': 'application/msword',
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx':
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'zip': 'application/zip',
  };
  return table[extension] ?? 'application/octet-stream';
}

/// Selects local media and hands it directly to Matrix SDK. In encrypted rooms
/// Matrix performs attachment encryption and sends only ciphertext to Synapse.
/// Plaintext is never sent to the business API.
final class MediaMessageService {
  MediaMessageService(this.matrix);
  final MatrixE2eeClient matrix;
  final ImagePicker _imagePicker = ImagePicker();
  final AudioRecorder _recorder = AudioRecorder();

  /// 「拍摄」入口：拍摄到临时文件并返回路径（取消返回 null），
  /// 由调用方立即自动加密发送。
  Future<String?> captureToFile() async {
    final image = await _imagePicker.pickImage(
      source: ImageSource.camera,
      maxWidth: 2160,
      imageQuality: 92,
    );
    if (image == null) return null;
    return image.path;
  }

  /// 「拍摄」长按：调起**系统相机录像界面**（需求 2），
  /// 拍摄完成返回视频临时文件路径（取消返回 null）。
  /// 后续压缩/确认发送由调用方处理。
  Future<String?> captureVideoToFile() async {
    final video = await _imagePicker.pickVideo(source: ImageSource.camera);
    if (video == null) return null;
    return video.path;
  }

  /// 「拍摄」自动发送的暂存缩略图：优先解码 200px 小图先展示，
  /// 失败返回 null（不阻塞原图发送）。
  Future<Uint8List?> captureThumbnail(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 200,
        targetHeight: 200,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<String> sendFile(String roomId) async {
    final file = await openFile();
    if (file == null) throw StateError('File selection cancelled');
    final bytes = await file.readAsBytes();
    return matrix.sendEncryptedMedia(
        roomId, bytes, file.mimeType ?? mimeFromFileName(file.name),
        filename: file.name);
  }

  Future<void> startVoiceRecording(String path) async {
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission denied');
    }
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path);
  }

  Future<String> stopVoiceRecording(String roomId) async {
    final path = await _recorder.stop();
    if (path == null) throw StateError('No active voice recording');
    return _send(roomId, path, 'audio/aac');
  }

  Future<String> stopVoiceRecordingForPreview() async {
    final path = await _recorder.stop();
    if (path == null) throw StateError('No active voice recording');
    return path;
  }

  /// 语音发送携带真实录音时长（毫秒），接收端据此显示秒数。
  Future<String> sendVoicePreview(String roomId, String path,
          {Duration? duration}) =>
      _send(roomId, path, 'audio/aac', duration: duration);

  Future<void> cancelVoiceRecording() async {
    final path = await _recorder.stop();
    if (path != null) await deleteVoiceFile(path);
  }

  /// 删除本地录音文件（转文字成功后清理原音频）。
  Future<void> deleteVoiceFile(String path) async {
    await File(path).delete().catchError((_) => File(path));
  }

  Future<String> _send(String roomId, String path, String mimeType,
      {Duration? duration}) async {
    final bytes = await File(path).readAsBytes();
    return matrix.sendEncryptedMedia(roomId, bytes, mimeType,
        extraContent: duration == null
            ? null
            : {
                'info': {'duration': duration.inMilliseconds},
              });
  }

  Future<void> dispose() => _recorder.dispose();
}
