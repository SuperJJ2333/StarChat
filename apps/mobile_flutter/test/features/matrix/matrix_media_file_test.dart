import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_media_file.dart';
import 'package:matrix/matrix.dart';

void main() {
  test('视频 extraContent.info.duration 转写进文件对象（不再覆盖 SDK info）',
      () async {
    final built = buildMediaFileForSend(
      bytes: Uint8List.fromList([1, 2, 3]),
      name: 'video.mp4',
      mimeType: 'video/mp4',
      extraContent: const {
        'info': {'duration': 5000},
      },
    );
    // 关键断言：info 不再经由 extraContent 传递（SDK 会以 ...extraContent
    // 浅合并整体覆盖 info → thumbnail_file 丢失 → 视频消息无封面）。
    expect(built.extraContent, isNull);
    expect(built.file, isA<MatrixVideoFile>());
    final video = built.file as MatrixVideoFile;
    expect(video.duration, 5000);
    expect(video.msgType, 'm.video');
    // SDK 的 info getter：duration 与 mimetype/size 共存（深合并语义）。
    expect(video.info['duration'], 5000);
    expect(video.info['mimetype'], 'video/mp4');
    expect(video.info['size'], 3);
  });

  test('视频 w/h/duration 全量转写', () {
    final built = buildMediaFileForSend(
      bytes: Uint8List.fromList([9]),
      name: 'v.mov',
      mimeType: 'video/quicktime',
      extraContent: const {
        'info': {'w': 1920, 'h': 1080, 'duration': 12345},
      },
    );
    final video = built.file as MatrixVideoFile;
    expect(video.width, 1920);
    expect(video.height, 1080);
    expect(video.duration, 12345);
    expect(built.extraContent, isNull);
  });

  test('音频 duration 转写（MatrixAudioFile）', () {
    final built = buildMediaFileForSend(
      bytes: Uint8List.fromList([1]),
      name: 'voice.ogg',
      mimeType: 'audio/ogg',
      extraContent: const {
        'info': {'duration': 2400},
      },
    );
    final audio = built.file as MatrixAudioFile;
    expect(audio.duration, 2400);
    expect(audio.msgType, 'm.audio');
    expect(built.extraContent, isNull);
  });

  test('info 以外的 extraContent 键原样保留', () {
    final built = buildMediaFileForSend(
      bytes: Uint8List.fromList([1]),
      name: 'v.mp4',
      mimeType: 'video/mp4',
      extraContent: const {
        'info': {'duration': 100},
        'm.relates_to': {'m.in_reply_to': {'event_id': '\$e1'}},
      },
    );
    expect(built.extraContent, containsPair('m.relates_to', anything));
    expect(built.extraContent!.containsKey('info'), isFalse);
  });

  test('无 extraContent：普通文件保持原行为', () {
    final built = buildMediaFileForSend(
      bytes: Uint8List.fromList([1, 2]),
      name: 'photo.jpg',
      mimeType: 'image/jpeg',
    );
    expect(built.file, isA<MatrixFile>());
    expect(built.file.msgType, 'm.image');
    expect(built.extraContent, isNull);
  });

  test('info 非法结构（非 Map）不崩溃：当无处理', () {
    final built = buildMediaFileForSend(
      bytes: Uint8List.fromList([1]),
      name: 'v.mp4',
      mimeType: 'video/mp4',
      extraContent: const {'info': 'bad'},
    );
    final video = built.file as MatrixVideoFile;
    expect(video.duration, isNull);
    expect(built.extraContent, isNull, reason: '非法 info 不回传（防覆盖）');
  });
}
