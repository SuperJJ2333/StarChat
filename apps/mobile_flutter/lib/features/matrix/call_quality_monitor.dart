import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

/// 一次 getStats 抽样（脱敏：仅网络/传输统计，不含媒体内容）。
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

  double? secondsToMs(Object? value) {
    if (value == null) return null;
    final parsed = double.tryParse(value.toString());
    return parsed == null ? null : parsed * 1000;
  }

  int? asInt(Object? value) => int.tryParse(value?.toString() ?? '');

  double? rttMs = secondsToMs(pair.values['currentRoundTripTime']);
  double? jitterMs;
  int? packetsReceived;
  int? packetsLost;
  int? concealmentEvents;
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
    final codecId = report.values['codecId'];
    if (codecId is String) {
      final mimeType = byId[codecId]?.values['mimeType']?.toString();
      if (mimeType != null && mimeType.isNotEmpty && !codecs.contains(mimeType)) {
        codecs.add(mimeType);
      }
    }
  }

  return CallQualitySample(
    localCandidateType: candidateType(pair.values['localCandidateId']),
    remoteCandidateType: candidateType(pair.values['remoteCandidateId']),
    rttMs: rttMs,
    jitterMs: jitterMs,
    packetsReceived: packetsReceived,
    packetsLost: packetsLost,
    iceState: pair.values['state']?.toString(),
    availableOutgoingBitrateBps:
        asInt(pair.values['availableOutgoingBitrate']),
    concealmentEvents: concealmentEvents,
    codecs: codecs,
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
    String fmt(double? value) => value == null ? '-' : value.toStringAsFixed(1);
    return '[chatflow/callquality] summary samples=${samples.length} '
        'turn=${turnUsed ? 'used' : 'not-used'} '
        'codec=${codecText.isEmpty ? '-' : codecText} '
        'availOut=${fmt(availOutKbps)}kbps '
        'conceal=$concealPeak '
        'rttAvg=${fmt(rtts.isEmpty ? null : rtts.reduce((a, b) => a + b) / rtts.length)}ms '
        'jitterMax=${fmt(jitters.isEmpty ? null : jitters.reduce((a, b) => a > b ? a : b))}ms '
        'lost=$lost/${received + lost}'
        '${lossPercent == null ? '' : '(${lossPercent.toStringAsFixed(2)}%)'}';
  }
}
