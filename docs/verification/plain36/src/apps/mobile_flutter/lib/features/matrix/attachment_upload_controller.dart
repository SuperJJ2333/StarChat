import 'package:flutter/foundation.dart';

enum AttachmentUploadStatus { idle, validating, uploading, succeeded, failed }

final class AttachmentUploadState {
  const AttachmentUploadState(this.status, {this.progress = 0, this.message});
  final AttachmentUploadStatus status;
  final double progress;
  final String? message;
}

final class AttachmentUploadController extends ChangeNotifier {
  AttachmentUploadState state =
      const AttachmentUploadState(AttachmentUploadStatus.idle);
  Future<bool> validate(
      {required String name, required String mime, required int bytes}) async {
    state = const AttachmentUploadState(AttachmentUploadStatus.validating);
    notifyListeners();
    final image = mime.startsWith('image/');
    final allowed = image
        ? {'image/jpeg', 'image/png', 'image/webp'}.contains(mime)
        : {
            'application/pdf',
            'application/zip',
            'text/plain',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
          }.contains(mime);
    final max = image ? 20 * 1024 * 1024 : 100 * 1024 * 1024;
    if (!allowed || bytes > max) {
      state = const AttachmentUploadState(AttachmentUploadStatus.failed,
          message: '文件类型或大小不符合要求');
      notifyListeners();
      return false;
    }
    return true;
  }

  void progress(double value) {
    state = AttachmentUploadState(AttachmentUploadStatus.uploading,
        progress: value.clamp(0, 1));
    notifyListeners();
  }

  void succeed() {
    state = const AttachmentUploadState(AttachmentUploadStatus.succeeded,
        progress: 1);
    notifyListeners();
  }

  void fail() {
    state = const AttachmentUploadState(AttachmentUploadStatus.failed,
        message: '上传失败，请重试');
    notifyListeners();
  }
}
