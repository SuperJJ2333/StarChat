import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';

import 'matrix_e2ee_client.dart';

/// 普通文件发送的大小上限（M01）：Matrix 文件走 homeserver 上传，
/// 客户端在 readAsBytes **之前**拒绝超限文件，避免整文件载入内存。
const maxFileSendBytes = 100 * 1024 * 1024;

/// 附件发送并发预算（M01）：同时在途的加密上传任务上限。
const mediaSendConcurrency = 3;

/// 附件超限异常（UI 呈现明确文案，不静默失败）。
final class MediaTooLargeException implements Exception {
  const MediaTooLargeException(this.limitBytes);
  final int limitBytes;

  @override
  String toString() => '文件超过发送上限 ${limitBytes ~/ (1024 * 1024)}MB';
}

/// 有界并发槽：超出上限的发送任务排队等待（不并发堆积内存）。
final class _BoundedSendSlots {
  _BoundedSendSlots(this.capacity) : _available = capacity;

  final int capacity;
  int _available;
  final _waiters = <Completer<void>>[];

  Future<void> acquire() async {
    if (_available > 0) {
      _available--;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  void release() {
    final waiter = _waiters.isEmpty ? null : _waiters.removeAt(0);
    if (waiter != null) {
      waiter.complete();
      return; // 槽直接移交给等待者。
    }
    _available++;
  }
}

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
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
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
  final _sendSlots = _BoundedSendSlots(mediaSendConcurrency);

  /// M01：读取前统一预检——存在、可读、未超限。
  /// 超限在 readAsBytes **之前**拒绝（低内存设备不被大文件撑爆）。
  @visibleForTesting
  static Future<void> ensureWithinSendLimit(File file,
      {int limitBytes = maxFileSendBytes}) async {
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      throw StateError('文件不存在或已被移除');
    }
    if (stat.size > limitBytes) {
      throw MediaTooLargeException(limitBytes);
    }
  }

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
    final local = File(file.path);
    // 读取前预检（大小/存在性），再进入有界并发槽上传。
    await ensureWithinSendLimit(local);
    final bytes = await local.readAsBytes();
    await _sendSlots.acquire();
    try {
      return await matrix.sendEncryptedMedia(
          roomId, bytes, file.mimeType ?? mimeFromFileName(file.name),
          filename: file.name);
    } finally {
      _sendSlots.release();
    }
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
    final local = File(path);
    // 语音消息同样走读取前预检（防异常大录音）+ 有界并发。
    await ensureWithinSendLimit(local);
    final bytes = await local.readAsBytes();
    await _sendSlots.acquire();
    try {
      return await matrix.sendEncryptedMedia(roomId, bytes, mimeType,
          extraContent: duration == null
              ? null
              : {
                  'info': {'duration': duration.inMilliseconds},
                });
    } finally {
      _sendSlots.release();
    }
  }

  Future<void> dispose() => _recorder.dispose();
}
