import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  test('unconfirmed frame attribution does not claim zero or UI bottleneck',
      () {
    final record = PerformanceRecord(
      operationId: '00000000-0000-4000-8000-000000000004',
      operation: PerformanceOperationType.conversationOpen,
      totalUs: 400000,
      stagesUs: const {},
      result: PerformanceResult.success,
      lifecycle: PerformanceLifecycle.foreground,
      frames: const PerformanceFrameCounts(slow: 5),
      frameAttributionComplete: false,
    );

    final json = record.toJson();
    expect(json['frame_attribution_complete'], false);
    expect(json.containsKey('slow_frame_count'), false);
    expect(json.containsKey('slow_build_count'), false);
    expect(json.containsKey('slow_raster_count'), false);
    expect(PerformanceBottleneckClassifier.classify(record),
        PerformanceBottleneck.unknown);
  });

  test('late frame attribution preserves frozen business measurements', () {
    final record = PerformanceRecord(
      operationId: '00000000-0000-4000-8000-000000000005',
      operation: PerformanceOperationType.conversationOpen,
      totalUs: 3700000,
      stagesUs: const {
        PerformanceStage.userAction: 0,
        PerformanceStage.localTimelineReady: 100000,
        PerformanceStage.remoteSyncReady: 3600000,
      },
      result: PerformanceResult.slow,
      lifecycle: PerformanceLifecycle.foreground,
      frames: const PerformanceFrameCounts(),
      frameAttributionComplete: false,
      openingSource: PerformanceOpeningSource.localRoom,
      appNetworkState: PerformanceAppNetworkState.weak,
      matrixState: PerformanceMatrixState.connecting,
      transportAvailable: true,
      serviceReachable: true,
      networkError: PerformanceNetworkError.readTimeout,
      endpointCategory: PerformanceEndpointCategory.auth,
      httpMethod: PerformanceHttpMethod.post,
      statusCode: 200,
      retryCount: 2,
      schedulerQueue: 4,
      rttMs: 220,
      packetsLost: 8,
      packetsReceived: 92,
      usesTurn: true,
      relayProtocol: PerformanceRelayProtocol.tcp,
    );

    final attributed = record.withFrameAttribution(
      const PerformanceFrameCounts(total: 7, slow: 3, slowBuild: 2),
      complete: true,
    );
    expect(attributed.operationId, record.operationId);
    expect(attributed.totalUs, record.totalUs);
    expect(attributed.stagesUs, record.stagesUs);
    expect(attributed.toJson(), {
      ...record.toJson(),
      'frame_attribution_complete': true,
      'slow_frame_count': 3,
      'slow_build_count': 2,
      'slow_raster_count': 0,
    });
  });
}
