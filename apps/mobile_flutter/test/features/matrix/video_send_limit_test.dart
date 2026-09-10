import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/video_transcode.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:liuhetong_mobile/features/matrix/gallery_media_payload.dart';
import 'package:liuhetong_mobile/features/matrix/prepared_chat_video.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late File source;
  late List<Map<dynamic, dynamic>> attempts;
  late List<int> sizes;
  late List<File> outputs;
  int? durationMs;
  var failedPasses = 0;
  setUp(() async {
    temp = await Directory(
            '../../docs/verification/artifacts/2026-09-10/chat-reliability-2084/video')
        .createTemp('limit-');
    source = File('${temp.path}/album.mov');
    await source.writeAsBytes([1]);
    final handle = await source.open(mode: FileMode.append);
    await handle.truncate(100 * 1024 * 1024);
    await handle.close();
    attempts = [];
    outputs = [];
    sizes = [25 * 1024 * 1024, 10 * 1024 * 1024];
    durationMs = 120000;
    failedPasses = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('video_compress'),
            (call) async {
      if (call.method == 'getMediaInfo') {
        return jsonEncode({'path': source.path, 'duration': durationMs});
      }
      if (call.method != 'compressVideo') return null;
      attempts.add(Map<dynamic, dynamic>.from(call.arguments as Map));
      if (attempts.length <= failedPasses) return null;
      final file = File('${temp.path}/output-${attempts.length}.mp4');
      await file.writeAsBytes([1]);
      final handle = await file.open(mode: FileMode.append);
      await handle.truncate(sizes[attempts.length - 1]);
      await handle.close();
      outputs.add(file);
      return jsonEncode(
          {'path': file.path, 'duration': 120000, 'isCancel': false});
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('video_compress'), null);
    await temp.delete(recursive: true);
  });

  test('25MB output retries even when already 75 percent smaller', () async {
    final result = await transcodeForChat(source);
    expect(attempts, hasLength(2));
    expect(
        await result.file.length(), lessThanOrEqualTo(maxOriginalVideoBytes));
    expect(attempts.last['frameRate'],
        lessThan(attempts.first['frameRate'] as int));
    for (final setting in [
      'videoBitrate',
      'maxDimension',
      'audioBitrate',
      'audioSampleRate'
    ]) {
      expect(attempts.last[setting], lessThan(attempts.first[setting] as int));
    }
    expect(attempts.last['includeAudio'], isTrue);
    expect(attempts.last['deleteOrigin'], isFalse);
    expect(await outputs.first.exists(), isFalse);
    expect(await source.exists(), isTrue);
  });

  test('normal result exactly 20MiB passes without retry and is disposable',
      () async {
    sizes = [maxOriginalVideoBytes];
    final result = await transcodeForChat(source);
    expect(attempts, hasLength(1));
    await result.dispose();
    expect(await result.file.exists(), isFalse);
    expect(await source.exists(), isTrue);
  });

  test(
      'long oversized source rejected before encoding with actionable estimate',
      () async {
    durationMs = 30 * 60 * 1000;
    await expectLater(
        transcodeForChat(source),
        throwsA(predicate((error) =>
            error is GroupVideoTooLargeException &&
            error.estimated &&
            error.toString().contains('裁剪'))));
    expect(attempts, isEmpty);
    expect(await source.exists(), isTrue);
  });

  test('unknown metadata still attempts actual compression', () async {
    durationMs = null;
    final result = await transcodeForChat(source);
    expect(attempts, hasLength(2));
    expect(
        await result.file.length(), lessThanOrEqualTo(maxOriginalVideoBytes));
  });

  test('failed first encoder still retries with aggressive profile', () async {
    failedPasses = 1;
    final result = await transcodeForChat(source);
    expect(attempts, hasLength(2));
    expect(
        await result.file.length(), lessThanOrEqualTo(maxOriginalVideoBytes));
  });

  test('both encoders failing cannot send original even if source is small',
      () async {
    await source.writeAsBytes([1]);
    failedPasses = 2;
    await expectLater(
        transcodeForChat(source), throwsA(isA<VideoCompressionException>()));
    expect(attempts, hasLength(2));
    expect(await source.exists(), isTrue);
  });

  test('low duration estimate never authorizes oversize bytes', () async {
    durationMs = 1000;
    sizes = [maxOriginalVideoBytes + 1, maxOriginalVideoBytes + 1];
    await expectLater(
        transcodeForChat(source), throwsA(isA<GroupVideoTooLargeException>()));
    expect(attempts, hasLength(2));
  });

  test('original rendition disposal preserves album file', () async {
    await VideoRendition(file: source, usedCompressed: false).dispose();
    expect(await source.exists(), isTrue);
  });

  test(
      'camera preparation releases source and outputs before retryable sending',
      () async {
    final prepared = await prepareCapturedChatVideo(source);
    expect(await source.exists(), isFalse);
    for (final file in outputs) {
      expect(await file.exists(), isFalse);
    }
    final timeline = RoomTimelineController(_VideoTimeline());
    var sends = 0;
    await timeline.sendText('[视频消息]', kind: RoomMessageKind.video,
        send: (tx) async {
      sends++;
      expect(prepared.bytes.length, 10 * 1024 * 1024);
      if (sends == 1) throw const SocketException('offline');
      return 'event';
    });
    expect(timeline.messages.single.deliveryState, RoomDeliveryState.failed);
    await timeline.retry(timeline.messages.single.stableId);
    expect(sends, 2);
    expect(timeline.messages.single.deliveryState, RoomDeliveryState.sent);
    timeline.dispose();
  });

  test('camera compression rejection also removes app-owned capture', () async {
    sizes = [maxOriginalVideoBytes + 1, maxOriginalVideoBytes + 1];
    await expectLater(prepareCapturedChatVideo(source),
        throwsA(isA<GroupVideoTooLargeException>()));
    expect(await source.exists(), isFalse);
    for (final file in outputs) {
      expect(await file.exists(), isFalse);
    }
  });

  test('both passes over 20MB reject and remove generated files', () async {
    sizes = [40 * 1024 * 1024, 21 * 1024 * 1024];
    await expectLater(
        transcodeForChat(source), throwsA(isA<GroupVideoTooLargeException>()));
    for (final file in outputs) {
      expect(await file.exists(), isFalse);
    }
    expect(await source.exists(), isTrue);
  });

  test('gallery original toggle cannot bypass automatic compression', () async {
    var originalReads = 0;
    var compressedReads = 0;
    final photo = GalleryPhoto(
        id: 'movie',
        thumbnail: Uint8List(0),
        isVideo: true,
        mimeType: 'video/quicktime',
        originalSizeBytes: () async => 100 * 1024 * 1024,
        originalBytes: () async {
          originalReads++;
          return Uint8List(30);
        },
        compressedBytes: () async {
          compressedReads++;
          return Uint8List(10);
        });
    final result =
        await prepareGalleryMedia(photo, original: true, isGroup: true);
    expect(originalReads, 0);
    expect(compressedReads, 1);
    expect(result.mimeType, 'video/mp4');
    expect(result.fileName, 'video.mp4');
  });
}

class _VideoTimeline implements RoomTimelineAdapter {
  @override
  List<RoomMessageViewModel> snapshot() => [];
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
