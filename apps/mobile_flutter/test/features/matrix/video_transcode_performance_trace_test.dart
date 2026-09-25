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

  test('native first-pass failure records both measured profiles', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('video_compress'),
            (call) async {
      if (call.method == 'getMediaInfo') {
        return jsonEncode({'path': source.path, 'duration': 1000});
      }
      if (call.method != 'compressVideo') return null;
      encoderCalls++;
      if (encoderCalls == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        throw PlatformException(
            code: 'video_transcode_failed',
            message: 'private-selected-video.mov / sensitive native detail');
      }
      final output = File('${temp.path}/private-output.mp4');
      await output.writeAsBytes([4, 5]);
      return jsonEncode(
          {'path': output.path, 'duration': 1000, 'isCancel': false});
    });
    final records = <PerformanceRecord>[];
    final trace = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    ).start(PerformanceOperationType.videoPrepare);

    final rendition = await transcodeForChat(source, performanceTrace: trace);
    trace.finish();

    expect(encoderCalls, 2);
    expect(rendition.usedCompressed, isTrue);
    final attempts = records.single.videoTranscodeAttempts;
    expect(attempts, hasLength(2));
    expect(attempts.first.profile, PerformanceVideoTranscodeProfile.normal);
    expect(
        attempts.first.outcome, PerformanceVideoTranscodeOutcome.nativeFailure);
    expect(attempts.first.durationMs, greaterThanOrEqualTo(20));
    expect(attempts.last.profile, PerformanceVideoTranscodeProfile.aggressive);
    expect(attempts.last.outcome, PerformanceVideoTranscodeOutcome.success);
    expect(records.single.toLocalDiagnosticJson()['video_transcode_attempts'],
        isNotNull);
    expect(
        records.single.toJson(), isNot(contains('video_transcode_attempts')));
    final encoded = jsonEncode(records.single.toLocalDiagnosticJson());
    expect(encoded, isNot(contains('private-selected-video')));
    expect(encoded, isNot(contains('sensitive native detail')));
    await rendition.dispose();
  });

  test('two typed native failures retain original and do not claim success',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('video_compress'),
            (call) async {
      if (call.method == 'getMediaInfo') {
        return jsonEncode({'path': source.path, 'duration': 1000});
      }
      if (call.method != 'compressVideo') return null;
      encoderCalls++;
      throw PlatformException(
          code: encoderCalls == 1
              ? 'video_transcode_failed'
              : 'video_transcode_cancelled',
          message: 'private-selected-video.mov / sensitive native detail');
    });
    final records = <PerformanceRecord>[];
    final trace = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    ).start(PerformanceOperationType.videoPrepare);

    await expectLater(transcodeForChat(source, performanceTrace: trace),
        throwsA(isA<VideoCompressionException>()));
    trace.finish(result: PerformanceResult.failed);

    expect(encoderCalls, 2);
    expect(await source.exists(), isTrue);
    expect(records.single.stagesUs,
        isNot(contains(PerformanceStage.videoTranscodeDone)));
    expect(
        records.single.videoTranscodeAttempts.map((attempt) => attempt.outcome),
        [
          PerformanceVideoTranscodeOutcome.nativeFailure,
          PerformanceVideoTranscodeOutcome.cancelled,
        ]);
    final encoded = jsonEncode(records.single.toLocalDiagnosticJson());
    expect(encoded, isNot(contains('private-selected-video')));
    expect(encoded, isNot(contains('sensitive native detail')));
  });

  test(
      'non-finite output duration does not misreport or leak a valid rendition',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('video_compress'),
            (call) async {
      if (call.method == 'getMediaInfo') {
        return jsonEncode({'path': source.path, 'duration': null});
      }
      if (call.method != 'compressVideo') return null;
      encoderCalls++;
      if (encoderCalls > 1) {
        throw PlatformException(code: 'video_transcode_failed');
      }
      final output = File('${temp.path}/nonfinite-output.mp4');
      await output.writeAsBytes([4, 5]);
      return jsonEncode(
          {'path': output.path, 'duration': 'NaN', 'isCancel': false});
    });
    final records = <PerformanceRecord>[];
    final trace = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    ).start(PerformanceOperationType.videoPrepare);

    final rendition = await transcodeForChat(source, performanceTrace: trace);
    trace.finish();

    expect(encoderCalls, 1);
    expect(rendition.durationMs, isNull);
    expect(records.single.videoTranscodeAttempts.single.outcome,
        PerformanceVideoTranscodeOutcome.success);
    expect(await rendition.file.exists(), isTrue);
    await rendition.dispose();
    expect(await rendition.file.exists(), isFalse);
    expect(await source.exists(), isTrue);
  });
}
