import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';

import 'matrix_e2ee_client.dart';

/// Selects local media and hands it directly to Matrix SDK. In encrypted rooms
/// Matrix performs attachment encryption and sends only ciphertext to Synapse.
/// Plaintext is never sent to the business API.
final class MediaMessageService {
  MediaMessageService(this.matrix);
  final MatrixE2eeClient matrix;
  final ImagePicker _imagePicker = ImagePicker();
  final AudioRecorder _recorder = AudioRecorder();

  Future<String> sendImage(String roomId) async {
    final image = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (image == null) throw StateError('Image selection cancelled');
    return _send(roomId, image.path, image.mimeType ?? 'image/jpeg');
  }

  Future<String> sendFile(String roomId) async {
    final file = await openFile();
    if (file == null) throw StateError('File selection cancelled');
    final bytes = await file.readAsBytes();
    return matrix.sendEncryptedMedia(roomId, bytes, file.mimeType ?? 'application/octet-stream');
  }

  Future<void> startVoiceRecording(String path) async {
    if (!await _recorder.hasPermission()) throw StateError('Microphone permission denied');
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
  }

  Future<String> stopVoiceRecording(String roomId) async {
    final path = await _recorder.stop();
    if (path == null) throw StateError('No active voice recording');
    return _send(roomId, path, 'audio/aac');
  }

  Future<String> _send(String roomId, String path, String mimeType) async {
    final bytes = await File(path).readAsBytes();
    return matrix.sendEncryptedMedia(roomId, bytes, mimeType);
  }

  Future<void> dispose() => _recorder.dispose();
}
