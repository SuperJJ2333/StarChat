import 'dart:io';
import 'package:file_selector/file_selector.dart';
import '../../core/outbox/media_outbox_store.dart';
import 'matrix_e2ee_client.dart';
import 'media_message_service.dart';

/// Production and recovery use this same account-owned, route-independent
/// sender. A prepared payload preserves m.file/video semantics across restart.
Future<String> sendPersistedMedia(
    MatrixSdkE2eeClient matrix, MediaOutboxTask task, File source,
    {required bool Function() current}) async {
  void check() {
    if (!current()) throw const MediaOutboxException('owner-unavailable');
  }

  check();
  final lease = await matrix.openRoomLease(task.roomId);
  MediaMessageService? media;
  try {
    check();
    if (task.prepared) {
      return await lease.sendStoredMedia(source,
          mimeType: task.mimeType,
          filename: task.filename,
          txid: task.txid,
          asFile: task.asFile,
          durationMs: task.durationMs,
          width: task.width,
          height: task.height);
    }
    media = MediaMessageService(lease);
    if (task.durationMs != null && task.mimeType.startsWith('audio/')) {
      return await media.sendVoicePreview(task.roomId, source.path,
          duration: Duration(milliseconds: task.durationMs!), txid: task.txid);
    }
    return await media.sendSelectedFile(task.roomId,
        XFile(source.path, name: task.filename, mimeType: task.mimeType),
        txid: task.txid);
  } finally {
    await media?.dispose();
    await lease.cancel();
  }
}
