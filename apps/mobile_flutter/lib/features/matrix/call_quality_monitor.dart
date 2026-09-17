import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

/// 一次 getStats 抽样（脱敏：仅网络/传输统计，不含媒体内容）。
///
/// 隐私边界（Task J）：只允许承载 RTT / jitter / jitter buffer / 丢包 /
/// 码率 / relay-direct / candidate 协议 / codec / concealment / AEC 指标。
/// **禁止**出现 IP 地址、TURN 用户名或凭据、SDP、ICE candidate 原文、
/// 消息明文或任何媒体内容。本类只保存解析后的数值与枚举字符串。
final class CallQualitySample {
  const CallQualitySample({
    this.localCandidateType,
    this.remoteCandidateType,
    this.rttMs,
    this.jitterMs,
    this.packetsReceived,
    this.packetsLost,
    this.iceState,
    this.availableOutgoingBitrateBps,
    this.concealmentEvents,
    this.codecs = const [],
    this.localCandidateProtocol,
    this.remoteCandidateProtocol,
    this.relayProtocol,
    this.jitterBufferDelaySeconds,
    this.jitterBufferEmittedCount,
    this.echoReturnLoss,
    this.echoReturnLossEnhancement,
  });

  /// host=本机网卡；srflx/prflx=STUN 打洞；relay=TURN 中继。
  final String? localCandidateType;
  final String? remoteCandidateType;

  /// 是否经 TURN 中继（任一侧 relay）。
  bool get usesTurn =>
      localCandidateType == 'relay' || remoteCandidateType == 'relay';

  final double? rttMs;
  final double? jitterMs;
  final int? packetsReceived;
  final int? packetsLost;

  /// 选中 candidate-pair 的 ICE 状态（succeeded/in-progress/failed…）。
  final String? iceState;

  /// 估算可用出站带宽（bps，ESTIMATE 型统计；缺失为 null）。
  final int? availableOutgoingBitrateBps;

  /// 音频隐藏事件累计数（丢包补偿触发次数，弱网劣化信号）。
  final int? concealmentEvents;

  /// 收流编解码器（如 audio/opus、video/VP8），按 inbound-rtp 去重。
  final List<String> codecs;

  /// candidate 传输协议（udp/tcp）。平台不支持时为 null（不伪造）。
  final String? localCandidateProtocol;
  final String? remoteCandidateProtocol;

  /// TURN 中继传输协议（如 udp/tcp/tls），Stats 提供时才记录。
  final String? relayProtocol;

  /// jitter buffer 累计延迟与累计发射采样数（平台提供时才记录）。
  ///
  /// 二者相除即 [averageJitterBufferDelayMs]；缺失时整体为 null，
  /// 绝不猜测一个数值。
  final double? jitterBufferDelaySeconds;
  final int? jitterBufferEmittedCount;

  /// 回声返回损耗（dB，平台支持时才提供；用于 AEC 诊断）。
  final double? echoReturnLoss;
  final double? echoReturnLossEnhancement;

  /// 平均 jitter buffer 延迟（ms）。缺任一字段时为 null。
  double? get averageJitterBufferDelayMs {
    final delay = jitterBufferDelaySeconds;
    final emitted = jitterBufferEmittedCount;
    if (delay == null || emitted == null || emitted <= 0) return null;
    return delay * 1000 / emitted;
  }

  /// 是否为窄带/低质量候选协议（诊断提示，不用于结束通话）。
  String get candidateProtocolText {
    final parts = <String>[
      if (localCandidateProtocol != null) 'local=$localCandidateProtocol',
      if (remoteCandidateProtocol != null) 'remote=$remoteCandidateProtocol',
      if (relayProtocol != null) 'relay=$relayProtocol',
    ];
    return parts.isEmpty ? '-' : parts.join(',');
  }
}

/// 解析 getStats 报告（纯函数，测试注入 fake StatsReport）。
///
/// 解析目标：
/// - 选中的 candidate-pair（state=succeeded 且 nominated/selected）→
///   local/remote candidate id → 候选类型（host/srflx/prflx/relay）→ TURN 使用；
/// - candidate-pair 的 currentRoundTripTime（秒→毫秒）；
/// - inbound-rtp 的 jitter（秒→毫秒）与 packetsLost / packetsReceived。
CallQualitySample? parseCallQualityReports(List<StatsReport> reports) {
  final byId = {for (final report in reports) report.id: report};

  StatsReport? selectedPair;
  int bestPriority = -1;
  for (final report in reports) {
    if (report.type != 'candidate-pair') continue;
    final values = report.values;
    if (values['state']?.toString() != 'succeeded') continue;
    final nominated = values['nominated']?.toString() == 'true' ||
        values['selected']?.toString() == 'true';
    final priority = (int.tryParse(values['priority']?.toString() ?? '') ?? 0) +
        (nominated ? 1 << 40 : 0);
    if (priority > bestPriority) {
      bestPriority = priority;
      selectedPair = report;
    }
  }
  final pair = selectedPair;
  if (pair == null) return const CallQualitySample();

  String? candidateType(Object? candidateId) {
    if (candidateId is! String) return null;
    return byId[candidateId]?.values['candidateType']?.toString();
  }

  /// candidate 传输协议（udp/tcp）。缺失返回 null。
  String? candidateProtocol(Object? candidateId) {
    if (candidateId is! String) return null;
    final values = byId[candidateId]?.values;
    if (values == null) return null;
    final protocol = values['protocol']?.toString();
    if (protocol != null && protocol.isNotEmpty) return protocol;
    return null;
  }

  /// TURN 中继协议（candidate 上的 `relayProtocol`；平台不提供时为 null）。
  String? candidateRelayProtocol(Object? candidateId) {
    if (candidateId is! String) return null;
    final value = byId[candidateId]?.values['relayProtocol']?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  double? secondsToMs(Object? value) {
    if (value == null) return null;
    final parsed = double.tryParse(value.toString());
    return parsed == null ? null : parsed * 1000;
  }

  double? asDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  int? asInt(Object? value) => int.tryParse(value?.toString() ?? '');

  double? rttMs = secondsToMs(pair.values['currentRoundTripTime']);
  double? jitterMs;
  int? packetsReceived;
  int? packetsLost;
  int? concealmentEvents;
  double? jitterBufferDelaySeconds;
  int? jitterBufferEmittedCount;
  double? echoReturnLoss;
  double? echoReturnLossEnhancement;
  final codecs = <String>[];
  for (final report in reports) {
    if (report.type != 'inbound-rtp') continue;
    jitterMs ??= secondsToMs(report.values['jitter']);
    packetsReceived =
        (packetsReceived ?? 0) + (asInt(report.values['packetsReceived']) ?? 0);
    packetsLost =
        (packetsLost ?? 0) + (asInt(report.values['packetsLost']) ?? 0);
    final concealNow = asInt(report.values['concealmentEvents']);
    if (concealNow != null) {
      concealmentEvents = (concealmentEvents ?? 0) + concealNow;
    }
    // 累计计数器：跨报告取较大值（不跨类型误加）。
    final bufferDelay = asDouble(report.values['jitterBufferDelay']);
    if (bufferDelay != null) {
      jitterBufferDelaySeconds = (jitterBufferDelaySeconds ?? 0) + bufferDelay;
    }
    final emitted = asInt(report.values['jitterBufferEmittedCount']);
    if (emitted != null) {
      jitterBufferEmittedCount = (jitterBufferEmittedCount ?? 0) + emitted;
    }
    // AEC/回声指标：平台不提供时为 null（不伪造）。
    echoReturnLoss ??= asDouble(report.values['echoReturnLoss']);
    echoReturnLossEnhancement ??=
        asDouble(report.values['echoReturnLossEnhancement']);
    final codecId = report.values['codecId'];
    if (codecId is String) {
      final mimeType = byId[codecId]?.values['mimeType']?.toString();
      if (mimeType != null &&
          mimeType.isNotEmpty &&
          !codecs.contains(mimeType)) {
        codecs.add(mimeType);
      }
    }
  }

  // relayProtocol 可能出现在 candidate-pair 或选中 candidate 上。
  String? relayProtocol = pair.values['relayProtocol']?.toString();
  relayProtocol ??= candidateRelayProtocol(pair.values['localCandidateId']);
  relayProtocol ??= candidateRelayProtocol(pair.values['remoteCandidateId']);

  return CallQualitySample(
    localCandidateType: candidateType(pair.values['localCandidateId']),
    remoteCandidateType: candidateType(pair.values['remoteCandidateId']),
    rttMs: rttMs,
    jitterMs: jitterMs,
    packetsReceived: packetsReceived,
    packetsLost: packetsLost,
    iceState: pair.values['state']?.toString(),
    availableOutgoingBitrateBps: asInt(pair.values['availableOutgoingBitrate']),
    concealmentEvents: concealmentEvents,
    codecs: codecs,
    localCandidateProtocol: candidateProtocol(pair.values['localCandidateId']),
    remoteCandidateProtocol:
        candidateProtocol(pair.values['remoteCandidateId']),
    relayProtocol: relayProtocol,
    jitterBufferDelaySeconds: jitterBufferDelaySeconds,
    jitterBufferEmittedCount: jitterBufferEmittedCount,
    echoReturnLoss: echoReturnLoss,
    echoReturnLossEnhancement: echoReturnLossEnhancement,
  );
}

/// 通话质量监控：连接期间周期性 getStats 抽样，结束输出汇总
/// （RTT 均值/最大抖动/丢包率/TURN 使用结论）。
final class CallQualityMonitor {
  CallQualityMonitor({
    required Future<List<StatsReport>> Function() getStats,
    this.interval = const Duration(seconds: 5),
    this.clock = DateTime.now,
    this.onSample,
  }) : _getStats = getStats;

  final Future<List<StatsReport>> Function() _getStats;
  final Duration interval;
  final DateTime Function() clock;
  final void Function(CallQualitySample sample)? onSample;

  final List<CallQualitySample> samples = [];
  Timer? _timer;
  bool _stopped = false;

  bool get isRunning => _timer != null;

  /// 任意抽样出现 relay 候选 → 本通话经 TURN 中继。
  bool get turnUsed => samples.any((sample) => sample.usesTurn);

  void start() {
    if (_timer != null) return;
    _stopped = false;
    unawaited(_poll());
    _timer = Timer.periodic(interval, (_) => unawaited(_poll()));
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_stopped) return;
    try {
      final reports = await _getStats();
      if (_stopped) return;
      final sample = parseCallQualityReports(reports);
      if (sample == null) return;
      samples.add(sample);
      onSample?.call(sample);
    } catch (error) {
      debugPrint(
          '[chatflow/callquality] getStats failed: ${error.runtimeType}');
    }
  }

  /// 通话结束汇总（无抽样时如实返回 null）。
  String? summary() {
    if (samples.isEmpty) return null;
    final rtts =
        samples.map((s) => s.rttMs).whereType<double>().toList(growable: false);
    final jitters = samples
        .map((s) => s.jitterMs)
        .whereType<double>()
        .toList(growable: false);
    final received = samples
        .map((s) => s.packetsReceived)
        .whereType<int>()
        .fold<int>(0, (a, b) => a + b);
    final lost = samples
        .map((s) => s.packetsLost)
        .whereType<int>()
        .fold<int>(0, (a, b) => a + b);
    final lossPercent =
        received + lost == 0 ? null : lost * 100.0 / (received + lost);
    final availOut = samples
        .map((s) => s.availableOutgoingBitrateBps)
        .whereType<int>()
        .toList(growable: false);
    final availOutKbps = availOut.isEmpty
        ? null
        : (availOut.reduce((a, b) => a + b) / availOut.length / 1000);
    // concealmentEvents 是累计计数器：取抽样峰值（不跨抽样累加）。
    final concealPeak = samples
        .map((s) => s.concealmentEvents)
        .whereType<int>()
        .fold<int>(0, (a, b) => a > b ? a : b);
    final codecText = samples
        .map((s) => s.codecs)
        .lastWhere((c) => c.isNotEmpty, orElse: () => const [])
        .join('/');
    // jitter buffer 平均延迟：取最后一个有值的抽样（累计量不可跨抽样累加）。
    final jitterBuffer = samples
        .map((s) => s.averageJitterBufferDelayMs)
        .lastWhere((value) => value != null, orElse: () => null);
    // AEC/回声指标：平台提供时取最后一个非空值。
    final erl = samples
        .map((s) => s.echoReturnLoss)
        .lastWhere((value) => value != null, orElse: () => null);
    final erle = samples
        .map((s) => s.echoReturnLossEnhancement)
        .lastWhere((value) => value != null, orElse: () => null);
    final protocols = samples
        .map((s) => s.candidateProtocolText)
        .lastWhere((value) => value != '-', orElse: () => '-');
    final pathText = samples.any((s) => s.usesTurn)
        ? 'relay'
        : (samples.any((s) =>
                s.localCandidateType != null || s.remoteCandidateType != null)
            ? 'direct'
            : '-');
    String fmt(double? value) => value == null ? '-' : value.toStringAsFixed(1);
    // 路径解读提示（只陈述**已观测事实**，不下质量结论、不据此结束通话）：
    // `turn=not-used` 只表示「本通话未走中继」，不等于「网络差」——P2P 直连的
    // 延迟通常更低。真正的风险是「需要中继却没有」（严格 NAT/CGNAT 可能完全
    // 连不通）与「中继区域过远」；后者需结合 path + rtt 判断，且多区域 TURN
    // 属于服务端基础设施。绝不用 turn 状态或 RTT 阈值直接结束通话。
    final pathNote = switch (pathText) {
      'relay' => 'pathNote=relayed-check-relay-region-against-rtt',
      'direct' => 'pathNote=p2p-direct-no-relay-observed',
      _ => 'pathNote=unknown',
    };
    return '[chatflow/callquality] summary samples=${samples.length} '
        'turn=${turnUsed ? 'used' : 'not-used'} '
        'path=$pathText '
        '$pathNote '
        'codec=${codecText.isEmpty ? '-' : codecText} '
        'protocol=$protocols '
        'availOut=${fmt(availOutKbps)}kbps '
        'conceal=$concealPeak '
        'jitterBuffer=${fmt(jitterBuffer)}ms '
        'erl=${fmt(erl)}dB erle=${fmt(erle)}dB '
        'rttAvg=${fmt(rtts.isEmpty ? null : rtts.reduce((a, b) => a + b) / rtts.length)}ms '
        'jitterMax=${fmt(jitters.isEmpty ? null : jitters.reduce((a, b) => a > b ? a : b))}ms '
        'lost=$lost/${received + lost}'
        '${lossPercent == null ? '' : '(${lossPercent.toStringAsFixed(2)}%)'}';
  }
}
