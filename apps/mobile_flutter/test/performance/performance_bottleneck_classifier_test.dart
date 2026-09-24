import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  test('a long Matrix sync poll alone does not prove a bottleneck', () {
    final record = PerformanceRecord(
      operationId: '00000000-0000-4000-8000-000000000001',
      operation: PerformanceOperationType.matrixSync,
      totalUs: 35050000,
      stagesUs: const {
        PerformanceStage.syncResponseReceived: 35000000,
        PerformanceStage.syncProcessingDone: 35040000,
      },
      result: PerformanceResult.slow,
      lifecycle: PerformanceLifecycle.foreground,
      frames: const PerformanceFrameCounts(),
    );
    expect(PerformanceBottleneckClassifier.classify(record),
        PerformanceBottleneck.unknown);
  });

  test('slow local timeline is Matrix room restoration, not fabricated SQL',
      () {
    final record = PerformanceRecord(
      operationId: '00000000-0000-4000-8000-000000000002',
      operation: PerformanceOperationType.conversationOpen,
      totalUs: 1500000,
      stagesUs: const {
        PerformanceStage.timelineLocalStarted: 100000,
        PerformanceStage.localTimelineReady: 1400000,
      },
      result: PerformanceResult.slow,
      lifecycle: PerformanceLifecycle.foreground,
      frames: const PerformanceFrameCounts(),
    );
    expect(PerformanceBottleneckClassifier.classify(record),
        PerformanceBottleneck.matrixRoom);
  });

  test('slow disk cache is a media-cache bottleneck', () {
    final record = PerformanceRecord(
      operationId: '00000000-0000-4000-8000-000000000003',
      operation: PerformanceOperationType.mediaLoad,
      totalUs: 1300000,
      stagesUs: const {
        PerformanceStage.cacheLoadStarted: 0,
        PerformanceStage.cacheLoadDone: 1250000,
      },
      result: PerformanceResult.slow,
      lifecycle: PerformanceLifecycle.foreground,
      frames: const PerformanceFrameCounts(),
      cacheSource: PerformanceCacheSource.disk,
    );
    expect(PerformanceBottleneckClassifier.classify(record),
        PerformanceBottleneck.mediaCache);
  });
  late int nowUs;
  late PerformanceTraceRecorder recorder;

  setUp(() {
    nowUs = 0;
    recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
    );
  });

  test('classifies measured navigation plus slow frames as client UI', () {
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    trace.mark(PerformanceStage.routePushStarted);
    nowUs = 910000;
    trace.mark(PerformanceStage.firstFrameRendered);
    nowUs = 1200000;
    expect(PerformanceBottleneckClassifier.classify(trace.finish()),
        PerformanceBottleneck.clientUi);
  });

  test('classifies sync wait with weak transport separately from processing',
      () {
    final trace = recorder.start(PerformanceOperationType.conversationOpen,
        appNetworkState: PerformanceAppNetworkState.weak,
        matrixState: PerformanceMatrixState.connecting,
        transportAvailable: false);
    trace.mark(PerformanceStage.localTimelineReady);
    nowUs = 1900000;
    trace.mark(PerformanceStage.remoteSyncReady);
    nowUs = 2000000;
    expect(PerformanceBottleneckClassifier.classify(trace.finish()),
        PerformanceBottleneck.networkTransport);

    nowUs = 0;
    final processing = recorder.start(PerformanceOperationType.matrixSync);
    processing.mark(PerformanceStage.syncResponseReceived);
    nowUs = 1800000;
    processing.mark(PerformanceStage.syncProcessingDone);
    nowUs = 1900000;
    expect(PerformanceBottleneckClassifier.classify(processing.finish()),
        PerformanceBottleneck.matrixSync);
  });

  test('Matrix service failure alone does not prove device transport failure',
      () {
    final stalled = recorder.start(PerformanceOperationType.conversationOpen,
        appNetworkState: PerformanceAppNetworkState.offline,
        matrixState: PerformanceMatrixState.disconnected,
        transportAvailable: true,
        serviceReachable: false);
    stalled.mark(PerformanceStage.localTimelineReady);
    nowUs = 1900000;
    stalled.mark(PerformanceStage.remoteSyncReady);
    expect(PerformanceBottleneckClassifier.classify(stalled.finish()),
        PerformanceBottleneck.matrixSync);

    nowUs = 0;
    final typedFailure = recorder.start(
        PerformanceOperationType.conversationOpen,
        appNetworkState: PerformanceAppNetworkState.weak);
    typedFailure.mark(PerformanceStage.localTimelineReady);
    nowUs = 1900000;
    typedFailure.mark(PerformanceStage.remoteSyncReady);
    expect(
        PerformanceBottleneckClassifier.classify(typedFailure.finish(
            networkError: PerformanceNetworkError.readTimeout)),
        PerformanceBottleneck.networkTransport);
  });

  test('classifies measured local database operation', () {
    final trace = recorder.start(PerformanceOperationType.search);
    trace.mark(PerformanceStage.databaseSearchStarted);
    nowUs = 400000;
    trace.mark(PerformanceStage.databaseSearchDone);
    expect(PerformanceBottleneckClassifier.classify(trace.finish()),
        PerformanceBottleneck.localDatabase);
  });

  test('classifies media queue separately from network download', () {
    final trace = recorder.start(PerformanceOperationType.mediaLoad);
    trace.mark(PerformanceStage.queueEntered);
    nowUs = 1700000;
    trace.mark(PerformanceStage.queueExited);
    nowUs = 2000000;
    trace.mark(PerformanceStage.downloadDone);
    expect(PerformanceBottleneckClassifier.classify(trace.finish()),
        PerformanceBottleneck.mediaScheduler);
  });

  test('classifies real WebRTC quality data and unknown honestly', () {
    final call = recorder.start(PerformanceOperationType.callActive);
    call.setCallQuality(
        rttMs: 240,
        jitterMs: 66,
        packetsLost: 7,
        packetsReceived: 93,
        usesTurn: true,
        relayProtocol: PerformanceRelayProtocol.tcp);
    nowUs = 100000;
    expect(PerformanceBottleneckClassifier.classify(call.finish()),
        PerformanceBottleneck.turn);
    final unknown = recorder.start(PerformanceOperationType.conversationOpen);
    nowUs = 3000000;
    expect(PerformanceBottleneckClassifier.classify(unknown.finish()),
        PerformanceBottleneck.unknown);
  });

  test('classifies observed room attach, decode, transcode and call setup', () {
    final room = recorder.start(PerformanceOperationType.conversationOpen);
    room.mark(PerformanceStage.roomAttachStarted);
    nowUs = 1200000;
    room.mark(PerformanceStage.roomAttachDone);
    expect(PerformanceBottleneckClassifier.classify(room.finish()),
        PerformanceBottleneck.matrixRoom);

    nowUs = 0;
    final decode = recorder.start(PerformanceOperationType.mediaLoad);
    decode.mark(PerformanceStage.decodeStarted);
    nowUs = 1300000;
    decode.mark(PerformanceStage.decodeDone);
    expect(PerformanceBottleneckClassifier.classify(decode.finish()),
        PerformanceBottleneck.mediaDecode);

    nowUs = 0;
    final transcode = recorder.start(PerformanceOperationType.videoPrepare);
    transcode.mark(PerformanceStage.videoTranscodeStarted);
    nowUs = 3200000;
    transcode.mark(PerformanceStage.videoTranscodeDone);
    expect(PerformanceBottleneckClassifier.classify(transcode.finish()),
        PerformanceBottleneck.mediaTranscode);

    nowUs = 0;
    final setup = recorder.start(PerformanceOperationType.callSetup);
    setup.mark(PerformanceStage.signalingReady);
    nowUs = 3200000;
    setup.mark(PerformanceStage.iceConnected);
    expect(PerformanceBottleneckClassifier.classify(setup.finish()),
        PerformanceBottleneck.webRtc);
  });

  test('API status does not turn total client latency into server latency',
      () {
    final api = recorder.start(PerformanceOperationType.apiRequest);
    nowUs = 1200000;
    expect(
        PerformanceBottleneckClassifier.classify(api.finish(statusCode: 503)),
        PerformanceBottleneck.businessApi);

    nowUs = 0;
    final download = recorder.start(PerformanceOperationType.mediaLoad);
    download.mark(PerformanceStage.downloadStarted);
    nowUs = 2100000;
    download.mark(PerformanceStage.downloadDone);
    expect(PerformanceBottleneckClassifier.classify(download.finish()),
        PerformanceBottleneck.mediaNetwork);

    nowUs = 0;
    final send = recorder.start(PerformanceOperationType.messageSend);
    send.mark(PerformanceStage.matrixSendStart);
    nowUs = 1500000;
    send.mark(PerformanceStage.matrixSendFinish);
    expect(PerformanceBottleneckClassifier.classify(send.finish()),
        PerformanceBottleneck.messageSend);
  });

  test('classifies a measured API transport failure by its typed evidence', () {
    final failed = recorder.start(PerformanceOperationType.apiRequest);
    nowUs = 2000000;
    expect(
        PerformanceBottleneckClassifier.classify(failed.finish(
            result: PerformanceResult.failed,
            networkError: PerformanceNetworkError.socketFailure)),
        PerformanceBottleneck.networkTransport);

    nowUs = 0;
    final unproven = recorder.start(PerformanceOperationType.apiRequest);
    nowUs = 2000000;
    expect(
        PerformanceBottleneckClassifier.classify(
            unproven.finish(result: PerformanceResult.failed)),
        PerformanceBottleneck.unknown);
  });

  test('slow frame count does not turn a Matrix wait into UI duration', () {
    var frames = const PerformanceFrameCounts();
    final frameRecorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      frameCounts: () => frames,
    );
    final waiting = frameRecorder.start(
      PerformanceOperationType.conversationOpen,
      appNetworkState: PerformanceAppNetworkState.weak,
      transportAvailable: false,
    );
    waiting.mark(PerformanceStage.localTimelineReady);
    nowUs = 29000000;
    waiting.mark(PerformanceStage.remoteSyncReady);
    frames = const PerformanceFrameCounts(total: 300, slow: 4);
    nowUs = 30000000;
    expect(PerformanceBottleneckClassifier.classify(waiting.finish()),
        PerformanceBottleneck.networkTransport);

    nowUs = 0;
    frames = const PerformanceFrameCounts();
    final uiOnly =
        frameRecorder.start(PerformanceOperationType.conversationOpen);
    frames = const PerformanceFrameCounts(total: 20, slow: 4);
    nowUs = 1000000;
    expect(PerformanceBottleneckClassifier.classify(uiOnly.finish()),
        PerformanceBottleneck.clientUi);
  });
}
