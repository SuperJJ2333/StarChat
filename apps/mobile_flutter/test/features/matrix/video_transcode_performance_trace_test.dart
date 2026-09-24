import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/video_transcode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late File source;
  late int encoderCalls;

  setUp(() async {
    final parent = Directory(
      '../../docs/verification/artifacts/2026-09-25/video-performance',
    );
    await parent.create(recursive: true);
    temp = await parent.createTemp('transcode-');
    source = File('${temp.path}/private-selected-video.mov');
    await source.writeAsBytes([1, 2, 3]);
    encoderCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('video_compress'),
            (call) async {
      if (call.method == 'getMediaInfo') {
        return jsonEncode({'path': source.path, 'duration': 1000});
      }
      if (call.method != 'compressVideo') return null;
      encoderCalls++;
      final output = File('${temp.path}/private-output.mp4');
      await output.writeAsBytes([4, 5]);
      return jsonEncode({
        'path': output.path,
        'duration': 1000,
        'isCancel': false,
      });
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('video_compress'), null);
    await temp.delete(recursive: true);
  });

  test('actual encoder work marks queued and completed transcode stages',
      () async {
    var clockUs = 0;
    final records = <PerformanceRecord>[];
    final trace = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => clockUs += 100,
      onRecord: records.add,
    ).start(PerformanceOperationType.videoPrepare);

    final rendition = await transcodeForChat(source, performanceTrace: trace);
    trace.finish();

    expect(encoderCalls, 1);
    expect(rendition.usedCompressed, isTrue);
    expect(records, hasLength(1));
    final stages = records.single.stagesUs;
    expect(
        stages.keys,
        containsAll([
          PerformanceStage.queueEntered,
          PerformanceStage.queueExited,
          PerformanceStage.videoTranscodeStarted,
          PerformanceStage.videoValidated,
          PerformanceStage.videoTranscodeDone,
        ]));
    expect(stages[PerformanceStage.queueEntered],
        lessThan(stages[PerformanceStage.queueExited]!));
    expect(stages[PerformanceStage.videoTranscodeStarted],
        lessThan(stages[PerformanceStage.videoTranscodeDone]!));
    final encoded = jsonEncode(records.single.toJson());
    expect(encoded, isNot(contains('private-selected-video')));
    expect(encoded, isNot(contains('private-output')));
    await rendition.dispose();
  });

  test('rejected empty source never claims encoder completion', () async {
    await source.writeAsBytes(const []);
    final records = <PerformanceRecord>[];
    final trace = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    ).start(PerformanceOperationType.videoPrepare);

    await expectLater(
      transcodeForChat(source, performanceTrace: trace),
      throwsA(isA<VideoCompressionException>()),
    );
    trace.finish(result: PerformanceResult.failed);

    expect(encoderCalls, 0);
    expect(
        records.single.stagesUs.keys, contains(PerformanceStage.queueExited));
    expect(
        records.single.stagesUs
            .containsKey(PerformanceStage.videoTranscodeStarted),
        isFalse);
    expect(
        records.single.stagesUs
            .containsKey(PerformanceStage.videoTranscodeDone),
        isFalse);
  });
}
