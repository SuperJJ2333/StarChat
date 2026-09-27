import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/call_quality_monitor.dart';

List<StatsReport> reports({required bool degraded}) => [
      StatsReport('pair', 'candidate-pair', 0, {
        'state': 'succeeded',
        'nominated': 'true',
        'currentRoundTripTime': degraded ? '0.24' : '0.02',
        'localCandidateId': 'local',
        'remoteCandidateId': 'remote',
      }),
      StatsReport('local', 'local-candidate', 0, {
        'candidateType': degraded ? 'relay' : 'host',
        'protocol': degraded ? 'tcp' : 'udp',
        if (degraded) 'relayProtocol': 'tcp',
      }),
      StatsReport('remote', 'remote-candidate', 0, {'candidateType': 'host'}),
      StatsReport('inbound', 'inbound-rtp', 0, {
        'jitter': degraded ? '0.066' : '0.001',
        'packetsLost': degraded ? '7' : '0',
        'packetsReceived': degraded ? '93' : '100',
      }),
    ];

void main() {
  test('empty getStats is not reported as a healthy quality window', () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    final polled = Completer<void>();
    final monitor = CallQualityMonitor(
      performanceRecorder: recorder,
      getStats: () async {
        if (!polled.isCompleted) polled.complete();
        return [];
      },
    );
    monitor.start();
    await polled.future;
    await Future<void>.delayed(Duration.zero);
    await monitor.stop();
    expect(records, isEmpty);
    recorder.clear();
  });
  test('quality recovery cannot erase the real degraded sample', () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    var polls = 0;
    final sampledTwice = Completer<void>();
    final monitor = CallQualityMonitor(
      performanceRecorder: recorder,
      interval: Duration.zero,
      getStats: () async => reports(degraded: polls++ == 0),
      onSample: (_) {
        if (polls >= 2 && !sampledTwice.isCompleted) sampledTwice.complete();
      },
    );
    monitor.start();
    await sampledTwice.future.timeout(const Duration(seconds: 2));
    await monitor.stop();
    final record = records.single;
    expect(record.rttMs, 240);
    expect(record.jitterMs, 66);
    expect(record.packetLossPercent, 7);
    expect(record.usesTurn, isTrue);
    expect(record.candidateProtocol, PerformanceRelayProtocol.tcp);
    recorder.clear();
  });

  test('a recovered direct sample never inherits an earlier TURN path',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    var polls = 0;
    var elapsedUs = 0;
    final sampledTwice = Completer<void>();
    final monitor = CallQualityMonitor(
      performanceRecorder: recorder,
      interval: Duration.zero,
      elapsedUs: () => elapsedUs,
      getStats: () async {
        if (polls > 0) elapsedUs += const Duration(seconds: 31).inMicroseconds;
        return reports(degraded: polls++ == 0);
      },
      onSample: (_) {
        if (polls >= 2 && !sampledTwice.isCompleted) sampledTwice.complete();
      },
    );
    monitor.start();
    await sampledTwice.future.timeout(const Duration(seconds: 2));
    await monitor.stop();
    expect(records, hasLength(2));
    expect(records.first.usesTurn, isTrue);
    expect(records.last.usesTurn, isFalse);
    expect(records.last.rttMs, 20);
    expect(records.last.candidateProtocol, PerformanceRelayProtocol.udp);
    expect(records.last.relayProtocol, isNull);
    expect(records.last.operationId, records.first.operationId);
    recorder.clear();
  });
}
