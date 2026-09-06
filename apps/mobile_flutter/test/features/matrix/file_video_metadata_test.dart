import 'dart:convert';
import 'dart:io';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/media_message_service.dart';

class _Picker extends FileSelectorPlatform {
  _Picker(this.path, this.mime);
  final String path;
  final String? mime;
  @override
  Future<XFile?> openFile(
          {List<XTypeGroup>? acceptedTypeGroups,
          String? initialDirectory,
          String? confirmButtonText}) async =>
      XFile(path, mimeType: mime);
}

class _Matrix implements MatrixE2eeClient {
  Map<String, dynamic>? content;
  String? mime;
  Uint8List? sentBytes;
  @override
  Future<String> sendEncryptedMedia(
      String roomId, Uint8List plaintext, String mimeType,
      {Map<String, dynamic>? extraContent,
      String? filename,
      Uint8List? thumbnailBytes,
      int? thumbnailWidth,
      int? thumbnailHeight}) async {
    content = extraContent;
    mime = mimeType;
    sentBytes = plaintext;
    return 'test-event';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('video_compress');
  final original = FileSelectorPlatform.instance;
  late Directory dir;
  late File video;
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.record/messages'),
            (call) async => null);
    final root = Directory(
        '../../docs/verification/artifacts/2026-09-05/group-qr-video');
    await root.create(recursive: true);
    dir = await root.createTemp('metadata-');
    video = await File('${dir.path}/clip.mp4').writeAsBytes([1, 2, 3]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (call) async => jsonEncode({
                  'path': video.path,
                  'duration': 12500.0,
                  'width': 1920,
                  'height': 1080
                }));
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.record/messages'), null);
    FileSelectorPlatform.instance = original;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await dir.delete(recursive: true);
  });
  for (final mime in ['video/mp4', 'application/octet-stream']) {
    test('文件入口视频保留时长和媒体类型：$mime', () async {
      FileSelectorPlatform.instance = _Picker(video.path, mime);
      final matrix = _Matrix();
      await MediaMessageService(matrix).sendFile('test-room');
      expect(matrix.mime, 'video/mp4');
      expect(matrix.content?['info']?['duration'], 12500);
    });
  }
  test('文件入口加密发送较小的压缩产物，而不是原文件', () async {
    final compressed = await File('${dir.path}/compressed.mp4').writeAsBytes([9]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cancelCompression') return true;
      if (call.method == 'getByteThumbnail') return null;
      return jsonEncode({'path': compressed.path, 'duration': 12500.0,
        'width': 640, 'height': 480});
    });
    FileSelectorPlatform.instance = _Picker(video.path, 'video/mp4');
    final matrix = _Matrix();
    await MediaMessageService(matrix).sendFile('test-room');
    expect(matrix.sentBytes, [9]);
    expect(matrix.content?['info']?['duration'], 12500);
  });
  test('读取视频元数据失败仍加密发送原文件，不伪造时长', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel,
            (call) async => throw PlatformException(code: 'unsupported'));
    FileSelectorPlatform.instance = _Picker(video.path, 'video/mp4');
    final matrix = _Matrix();
    await MediaMessageService(matrix).sendFile('test-room');
    expect(matrix.mime, 'video/mp4');
    expect(matrix.content, isNull);
  });
}
