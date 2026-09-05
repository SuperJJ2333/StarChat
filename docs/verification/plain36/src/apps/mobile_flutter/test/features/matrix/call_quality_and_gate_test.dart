import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_quality_monitor.dart';
import 'package:liuhetong_mobile/features/matrix/incoming_call_gate.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

void main() {
  group('parseCallQualityReports（getStats 解析）', () {
    StatsReport report(String id, String type, Map<String, dynamic> values) =>
        StatsReport(id, type, 0, values);

    test('解析选中 candidate-pair：候选类型/TURN 使用/RTT/抖动/丢包', () {
      final sample = parseCallQualityReports([
        report('pair-1', 'candidate-pair', {
          'state': 'succeeded',
          'nominated': 'true',
          'priority': 100,
          'localCandidateId': 'L1',
          'remoteCandidateId': 'R1',
          'currentRoundTripTime': '0.042',
        }),
        report('L1', 'local-candidate', {'candidateType': 'relay'}),
        report('R1', 'remote-candidate', {'candidateType': 'srflx'}),
        report('inbound-1', 'inbound-rtp', {
          'jitter': '0.008',
          'packetsReceived': '1000',
          'packetsLost': '10',
        }),
      ]);
      expect(sample, isNotNull);
      expect(sample!.localCandidateType, 'relay');
      expect(sample.remoteCandidateType, 'srflx');
      expect(sample.usesTurn, isTrue, reason: '本端 relay = 经 TURN 中继');
      expect(sample.rttMs, closeTo(42, 0.001));
      expect(sample.jitterMs, closeTo(8, 0.001));
      expect(sample.packetsReceived, 1000);
      expect(sample.packetsLost, 10);
    });

    test('host-host 直连不判 TURN；缺 rtt/丢包字段安全为空', () {
      final sample = parseCallQualityReports([
        report('pair-1', 'candidate-pair', {
          'state': 'succeeded',
          'nominated': 'true',
          'localCandidateId': 'L1',
          'remoteCandidateId': 'R1',
        }),
        report('L1', 'local-candidate', {'candidateType': 'host'}),
        report('R1', 'remote-candidate', {'candidateType': 'host'}),
      ]);
      expect(sample!.usesTurn, isFalse);
      expect(sample.rttMs, isNull);
      expect(sample.jitterMs, isNull);
      expect(sample.packetsLost, isNull);
    });

    test('无成功 candidate-pair 时返回空样本', () {
      final sample = parseCallQualityReports([
        report('pair-x', 'candidate-pair', {'state': 'in-progress'}),
      ]);
      expect(sample, isNotNull);
      expect(sample!.localCandidateType, isNull);
      expect(sample.usesTurn, isFalse);
    });

    test('F 扩展：编解码器/可用出站带宽/隐藏事件数/ICE 状态', () {
      final sample = parseCallQualityReports([
        report('pair-1', 'candidate-pair', {
          'state': 'succeeded',
          'nominated': 'true',
          'localCandidateId': 'L1',
          'remoteCandidateId': 'R1',
          'currentRoundTripTime': '0.030',
          'state2': 'ignored',
          'availableOutgoingBitrate': '312000',
        }),
        report('L1', 'local-candidate', {'candidateType': 'host'}),
        report('R1', 'remote-candidate', {'candidateType': 'srflx'}),
        report('codec-1', 'codec', {
          'mimeType': 'audio/opus',
          'payloadType': '111',
        }),
        report('inbound-1', 'inbound-rtp', {
          'jitter': '0.006',
          'packetsReceived': '500',
          'packetsLost': '2',
          'codecId': 'codec-1',
          'concealmentEvents': '37',
        }),
      ]);
      expect(sample!.iceState, 'succeeded', reason: '选中 pair 的 ICE 状态');
      expect(sample.availableOutgoingBitrateBps, 312000);
      expect(sample.concealmentEvents, 37, reason: '音频隐藏事件（弱网劣化信号）');
      final codecs = sample.codecs;
      expect(codecs, contains('audio/opus'));
    });

    test('F 扩展：缺新字段时安全为空（老浏览器/音频无 concealment）', () {
      final sample = parseCallQualityReports([
        report('pair-1', 'candidate-pair', {
          'state': 'succeeded',
          'nominated': 'true',
          'localCandidateId': 'L1',
          'remoteCandidateId': 'R1',
        }),
        report('L1', 'local-candidate', {'candidateType': 'host'}),
        report('R1', 'remote-candidate', {'candidateType': 'host'}),
        report('inbound-1', 'inbound-rtp', {'packetsReceived': '10'}),
      ]);
      expect(sample!.availableOutgoingBitrateBps, isNull);
      expect(sample.concealmentEvents, isNull);
      expect(sample.codecs, isEmpty);
    });

    test('F 扩展：summary 汇编包含编解码与带宽结论', () async {
      final monitor = CallQualityMonitor(
        getStats: () async => [
          StatsReport('p', 'candidate-pair', 0, {
            'state': 'succeeded',
            'nominated': 'true',
            'localCandidateId': 'L',
            'remoteCandidateId': 'R',
            'currentRoundTripTime': '0.025',
            'availableOutgoingBitrate': '250000',
          }),
          StatsReport('L', 'local-candidate', 0, {'candidateType': 'host'}),
          StatsReport('R', 'remote-candidate', 0, {'candidateType': 'host'}),
          StatsReport('c1', 'codec', 0, {'mimeType': 'video/VP8'}),
          StatsReport('i', 'inbound-rtp', 0, {
            'jitter': '0.004',
            'packetsReceived': '100',
            'packetsLost': '0',
            'codecId': 'c1',
            'concealmentEvents': '5',
          }),
        ],
        interval: const Duration(milliseconds: 5),
      );
      monitor.start();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (monitor.samples.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await monitor.stop();
      final text = monitor.summary() ?? '';
      expect(text, contains('codec=video/VP8'));
      expect(text, contains('availOut='));
      expect(text, contains('conceal='));
    });
  });

  group('CallQualityMonitor（轮询与汇总）', () {
    test('start 轮询抽样，stop 后停止，summary 汇总 TURN/RTT/丢包', () async {
      final samples = <List<StatsReport>>[
        [
          StatsReport('p', 'candidate-pair', 0, {
            'state': 'succeeded',
            'nominated': 'true',
            'localCandidateId': 'L',
            'remoteCandidateId': 'R',
            'currentRoundTripTime': '0.020',
          }),
          StatsReport('L', 'local-candidate', 0, {'candidateType': 'relay'}),
          StatsReport('R', 'remote-candidate', 0, {'candidateType': 'relay'}),
          StatsReport('i', 'inbound-rtp', 0, {
            'jitter': '0.005',
            'packetsReceived': '100',
            'packetsLost': '1'
          }),
        ],
        [
          StatsReport('p', 'candidate-pair', 0, {
            'state': 'succeeded',
            'nominated': 'true',
            'localCandidateId': 'L',
            'remoteCandidateId': 'R',
            'currentRoundTripTime': '0.040',
          }),
          StatsReport('L', 'local-candidate', 0, {'candidateType': 'relay'}),
          StatsReport('R', 'remote-candidate', 0, {'candidateType': 'relay'}),
          StatsReport('i', 'inbound-rtp', 0, {
            'jitter': '0.010',
            'packetsReceived': '100',
            'packetsLost': '3'
          }),
        ],
      ];
      var cursor = 0;
      final monitor = CallQualityMonitor(
        getStats: () async => samples[cursor++ % samples.length],
        interval: const Duration(milliseconds: 10),
      );
      monitor.start();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (monitor.samples.length < 4 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await monitor.stop();
      expect(monitor.samples.length, greaterThanOrEqualTo(2));
      expect(monitor.turnUsed, isTrue);
      final summary = monitor.summary();
      expect(summary, contains('turn=used'));
      expect(summary, contains('rttAvg=30.0ms'));
      expect(summary, contains('jitterMax=10.0ms'));
      // 抽样次数随时间累积，丢包按比率断言（每次抽样 4/204）。
      expect(summary, contains('(1.96%)'));
    });

    test('getStats 抛错不中断轮询（尽力而为）', () async {
      var calls = 0;
      final monitor = CallQualityMonitor(
        getStats: () async {
          calls++;
          throw StateError('pc disposed');
        },
        interval: const Duration(milliseconds: 5),
      );
      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await monitor.stop();
      expect(calls, greaterThanOrEqualTo(2));
      expect(monitor.summary(), isNull, reason: '无有效抽样时如实返回空');
    });
  });

  group('IncomingCallGate（来电本地成员优先）', () {
    test('本地成员命中：零服务器请求，立即放行', () async {
      var remoteCalls = 0;
      final gate = IncomingCallGate(
        localMembers: () => {'@me:x', '@peer:x'},
        remoteMembers: () async {
          remoteCalls++;
          return {'@me:x', '@peer:x'};
        },
      );
      final remote = await gate.validate(
        localUserId: '@me:x',
        advertisedRemoteUserId: '@peer:x',
        roomJoined: true,
        roomEncrypted: true,
      );
      expect(remote, '@peer:x');
      expect(remoteCalls, 0, reason: '本地已同步成员必须优先，不来服务器请求');
    });

    test('本地成员为空：回退服务器获取（超时内）', () async {
      final gate = IncomingCallGate(
        localMembers: () => const <String>{},
        remoteMembers: () async => {'@me:x', '@peer:x'},
        serverFetchTimeout: const Duration(seconds: 2),
      );
      final remote = await gate.validate(
        localUserId: '@me:x',
        advertisedRemoteUserId: null,
        roomJoined: true,
        roomEncrypted: true,
      );
      expect(remote, '@peer:x');
    });

    test('服务器超时/失败：拒接（安全优先，与旧语义一致）', () async {
      final gate = IncomingCallGate(
        localMembers: () => const <String>{},
        remoteMembers: () => Completer<Set<String>?>().future,
        serverFetchTimeout: const Duration(milliseconds: 20),
      );
      final remote = await gate.validate(
        localUserId: '@me:x',
        advertisedRemoteUserId: null,
        roomJoined: true,
        roomEncrypted: true,
      );
      expect(remote, isNull);
    });

    test('安全不变量：非双方/未加密/未入房/与信令声明不符一律拒接', () async {
      final gate = IncomingCallGate(
        localMembers: () => {'@me:x', '@peer:x', '@extra:x'},
        remoteMembers: () async => null,
      );
      expect(
        await gate.validate(
            localUserId: '@me:x',
            advertisedRemoteUserId: null,
            roomJoined: true,
            roomEncrypted: true),
        isNull,
        reason: '三方房间不得放行通话',
      );
      expect(
        IncomingCallGate.resolveRemote({'@me:x', '@peer:x'},
            localUserId: '@me:x', advertisedRemoteUserId: '@other:x'),
        isNull,
        reason: '成员与信令声明的远端不一致必须拒接',
      );
      expect(
        IncomingCallGate.resolveRemote({'@peer:x'}, localUserId: '@me:x'),
        isNull,
        reason: '本地用户不在成员内不得放行',
      );
    });
  });
}
