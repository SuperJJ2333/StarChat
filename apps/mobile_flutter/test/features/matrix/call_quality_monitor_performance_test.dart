import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/call_quality_monitor.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

void main() {
  test('connected call records typed measured quality with one active trace',
      () async {
    var nowUs = 0;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      onRecord: records.add,
    );
    final monitor = CallQualityMonitor(
      performanceRecorder: recorder,
      getStats: () async => [
        StatsReport('pair', 'candidate-pair', 0, {
          'state': 'succeeded',
          'nominated': 'true',
          'localCandidateId': 'local',
          'remoteCandidateId': 'remote',
          'currentRoundTripTime': '0.240',
        }),
        StatsReport('local', 'local-candidate', 0, {
          'candidateType': 'relay',
          'protocol': 'tcp',
          'relayProtocol': 'tcp',
          'address': '203.0.113.7',
          'usernameFragment': 'private-turn-user',
        }),
        StatsReport('remote', 'remote-candidate', 0, {
          'candidateType': 'srflx',
          'protocol': 'udp',
        }),
        StatsReport('inbound', 'inbound-rtp', 0, {
          'jitter': '0.066',
          'packetsLost': '7',
          'packetsReceived': '93',
        }),
      ],
    );
    monitor.start();
    await Future<void>.delayed(Duration.zero);
    expect(records, isEmpty, reason: 'active call completes only on stop');
    nowUs = 2000000;
    await monitor.stop();

    expect(records, hasLength(1));
    final record = records.single;
    expect(record.operation, PerformanceOperationType.callActive);
    expect(record.totalMs, 2000);
    expect(record.rttMs, 240);
    expect(record.jitterMs, 66);
    expect(record.packetLossPercent, 7);
    expect(record.usesTurn, isTrue);
    expect(record.relayProtocol, PerformanceRelayProtocol.tcp);
    expect(record.candidateProtocol, PerformanceRelayProtocol.tcp);
    expect(record.toJson().toString(), isNot(contains('203.0.113.7')));
    expect(record.toJson().toString(), isNot(contains('private-turn-user')));
    await monitor.stop();
    expect(records, hasLength(1));
  });

  test('missing stats remain null in active-call trace', () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final monitor = CallQualityMonitor(
      performanceRecorder: recorder,
      getStats: () async => [
        StatsReport('pair', 'candidate-pair', 0, {
          'state': 'succeeded',
          'nominated': 'true',
        }),
        StatsReport('inbound', 'inbound-rtp', 0, {
          'packetsReceived': '100',
        }),
      ],
    );
    monitor.start();
    await Future<void>.delayed(Duration.zero);
    await monitor.stop();

    expect(records, hasLength(1));
    expect(records.single.packetLossPercent, isNull);
    expect(records.single.usesTurn, isNull);
    expect(records.single.relayProtocol, isNull);
  });

  test('partial counters from different polls never form a loss percentage',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    var polls = 0;
    var monitorSamples = 0;
    final gotTwoPolls = Completer<void>();
    final monitor = CallQualityMonitor(
      performanceRecorder: recorder,
      interval: Duration.zero,
      onSample: (_) {
        if (monitorSamples++ == 1) gotTwoPolls.complete();
      },
      getStats: () async {
        polls++;
        return [
          StatsReport('pair', 'candidate-pair', 0, {
            'state': 'succeeded',
            'nominated': 'true',
          }),
          StatsReport('inbound', 'inbound-rtp', 0,
              polls == 1 ? {'packetsReceived': '100'} : {'packetsLost': '1'}),
        ];
      },
    );
    monitor.start();
    await gotTwoPolls.future.timeout(const Duration(seconds: 2));
    await monitor.stop();

    expect(records, hasLength(1));
    expect(records.single.packetLossPercent, isNull);
  });

  test('malformed getStats strings cannot enter candidate or codec diagnostics',
      () {
    const secret = '203.0.113.4 turn-user-secret';
    final sample = parseCallQualityReports([
      StatsReport('pair', 'candidate-pair', 0, {
        'state': 'succeeded',
        'nominated': 'true',
        'localCandidateId': 'local',
        'remoteCandidateId': 'remote',
        'relayProtocol': secret,
      }),
      StatsReport('local', 'local-candidate', 0, {
        'candidateType': secret,
        'protocol': secret,
      }),
      StatsReport('remote', 'remote-candidate', 0, {
        'candidateType': 'relay',
        'protocol': 'tcp',
      }),
      StatsReport('codec', 'codec', 0, {'mimeType': secret}),
      StatsReport('inbound', 'inbound-rtp', 0, {'codecId': 'codec'}),
    ]);

    expect(sample, isNotNull);
    expect(sample!.localCandidateType, isNull);
    expect(sample.localCandidateProtocol, isNull);
    expect(sample.relayProtocol, isNull);
    expect(sample.codecs, isEmpty);
    expect(sample.candidateProtocolText, 'remote=tcp');
    expect(sample.usesTurn, isTrue);
  });

  test('sanitized codec values cannot be replaced after parsing', () {
    final sample = parseCallQualityReports([
      StatsReport('pair', 'candidate-pair', 0, {
        'state': 'succeeded',
        'nominated': 'true',
      }),
      StatsReport('codec', 'codec', 0, {'mimeType': 'audio/opus'}),
      StatsReport('inbound', 'inbound-rtp', 0, {'codecId': 'codec'}),
    ]);

    expect(sample!.codecs, ['audio/opus']);
    expect(() => sample.codecs.add('turn-user-secret'), throwsUnsupportedError);
  });

  test('packet loss is unsupported when either counter is absent', () async {
    final monitor = CallQualityMonitor(
        getStats: () async => [
              StatsReport('pair', 'candidate-pair', 0, {
                'state': 'succeeded',
                'nominated': 'true',
              }),
              StatsReport('inbound', 'inbound-rtp', 0, {
                'packetsReceived': '100',
              }),
            ]);
    monitor.start();
    await Future<void>.delayed(Duration.zero);
    await monitor.stop();

    expect(monitor.samples.single.packetsReceived, 100);
    expect(monitor.samples.single.packetsLost, isNull);
    expect(monitor.summary(), isNot(contains('%')));
  });

  test('packet loss percent uses one complete measured counter pair', () {
    final sample = parseCallQualityReports([
      StatsReport('pair', 'candidate-pair', 0, {
        'state': 'succeeded',
        'nominated': 'true',
      }),
      StatsReport('inbound', 'inbound-rtp', 0, {
        'packetsReceived': '100',
        'packetsLost': '7',
      }),
    ]);

    expect(sample!.packetLossPercent, closeTo(6.54, 0.01));
  });

  test('partial counters from separate inbound streams cannot form packet loss',
      () {
    final sample = parseCallQualityReports([
      StatsReport('pair', 'candidate-pair', 0, {
        'state': 'succeeded',
        'nominated': 'true',
      }),
      StatsReport('audio', 'inbound-rtp', 0, {
        'packetsReceived': '100',
      }),
      StatsReport('video', 'inbound-rtp', 0, {
        'packetsLost': '10',
      }),
    ]);

    expect(sample, isNotNull);
    expect(sample!.packetLossPercent, isNull);
  });

  test('successful unselected candidate pair cannot claim a TURN path', () {
    final sample = parseCallQualityReports([
      StatsReport('pair', 'candidate-pair', 0, {
        'state': 'succeeded',
        'localCandidateId': 'local',
        'remoteCandidateId': 'remote',
        'currentRoundTripTime': '0.2',
      }),
      StatsReport('local', 'local-candidate', 0, {
        'candidateType': 'relay',
        'protocol': 'tcp',
      }),
      StatsReport('remote', 'remote-candidate', 0, {
        'candidateType': 'srflx',
      }),
    ]);

    expect(sample, isNotNull);
    expect(sample!.localCandidateType, isNull);
    expect(sample.remoteCandidateType, isNull);
    expect(sample.rttMs, isNull);
    expect(sample.candidateProtocolText, '-');
  });

  test('RTP quality survives absent selected pair without claiming ICE path',
      () {
    final sample = parseCallQualityReports([
      StatsReport('unselected', 'candidate-pair', 0, {
        'state': 'succeeded',
        'localCandidateId': 'local',
        'currentRoundTripTime': '0.9',
      }),
      StatsReport('local', 'local-candidate', 0, {
        'candidateType': 'relay',
        'protocol': 'tcp',
      }),
      StatsReport('remote-inbound', 'remote-inbound-rtp', 0, {
        'roundTripTime': '0.240',
      }),
      StatsReport('inbound', 'inbound-rtp', 0, {
        'jitter': '0.066',
        'packetsLost': '7',
        'packetsReceived': '93',
      }),
    ]);

    expect(sample, isNotNull);
    expect(sample!.rttMs, 240);
    expect(sample.jitterMs, 66);
    expect(sample.packetLossPercent, 7);
    expect(sample.localCandidateType, isNull);
    expect(sample.remoteCandidateType, isNull);
    expect(sample.iceState, isNull);
    expect(sample.relayProtocol, isNull);
  });

  test('active call without selected pair reports quality but not TURN path',
      () async {
    final records = <PerformanceRecord>[];
    final monitor = CallQualityMonitor(
      performanceRecorder: PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        onRecord: records.add,
      ),
      getStats: () async => [
        StatsReport('remote-inbound', 'remote-inbound-rtp', 0, {
          'roundTripTime': '0.240',
        }),
        StatsReport('inbound', 'inbound-rtp', 0, {
          'jitter': '0.066',
          'packetsLost': '7',
          'packetsReceived': '93',
        }),
      ],
    );
    monitor.start();
    await Future<void>.delayed(Duration.zero);
    await monitor.stop();

    expect(records.single.rttMs, 240);
    expect(records.single.jitterMs, 66);
    expect(records.single.packetLossPercent, 7);
    expect(records.single.usesTurn, isNull);
    expect(monitor.summary(), contains('turn=unknown path=-'));
  });

  test('getStats failure has no detail log while diagnostics are disabled',
      () async {
    final previous = debugPrint;
    final lines = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);
    final monitor = CallQualityMonitor(
      performanceRecorder:
          PerformanceTraceRecorder(metrics: PerformanceMetrics(enabled: false)),
      getStats: () async => throw StateError('getStats unavailable'),
    );
    monitor.start();
    await Future<void>.delayed(Duration.zero);
    await monitor.stop();

    expect(lines, isEmpty);
  });

  test('call quality summary uses the unified call tag', () async {
    final monitor = CallQualityMonitor(
      getStats: () async => [
        StatsReport('pair', 'candidate-pair', 0, {
          'state': 'succeeded',
          'nominated': 'true',
        }),
      ],
    );
    monitor.start();
    await Future<void>.delayed(Duration.zero);
    await monitor.stop();

    expect(monitor.summary(), startsWith('[chatflow/call]'));
  });

  test('call quality sample buffer stays bounded during a long call', () async {
    final reached = Completer<void>();
    var count = 0;
    final monitor = CallQualityMonitor(
      getStats: () async => [
        StatsReport('pair', 'candidate-pair', 0, {
          'state': 'succeeded',
          'nominated': 'true',
        }),
      ],
      interval: Duration.zero,
      onSample: (_) {
        if (++count == 132) reached.complete();
      },
    );
    monitor.start();
    await reached.future.timeout(const Duration(seconds: 2));
    await monitor.stop();

    expect(count, greaterThanOrEqualTo(132));
    expect(monitor.samples.length, lessThanOrEqualTo(128));
  });

  test('a slow getStats poll never starts overlapping polls', () async {
    final held = Completer<List<StatsReport>>();
    var calls = 0;
    final monitor = CallQualityMonitor(
      getStats: () {
        calls++;
        return held.future;
      },
      interval: Duration.zero,
    );
    monitor.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, 1);
    await monitor.stop();
    held.complete(const []);
  });
}
