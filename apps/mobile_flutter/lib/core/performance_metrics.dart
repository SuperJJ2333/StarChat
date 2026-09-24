import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'performance_trace_model.dart';

// Closed enums deliberately prevent identifiers, URLs or content in telemetry.
enum PerformanceOperation {
  appStartup,
  appResume,
  conversationOpen,
  messageSend,
  matrixSync,
  syncCycleTotal,
  recentPicturesLoad,
  videoPrepare,
  videoPoster,
  search,
  searchPageOpen,
  contactsLoad,
  momentsLoad,
  walletLoad,
  apiRequest,
  callSetup,
  callActive,
  profileLoad,
  chatListLoad,
  frameBuild,
  frameRaster,
  frameTotal,
  timelineRefresh,
  draftSnapshot,
  mediaLoad,
  avatarResolve,
  localFeedLoad,
  conversationProjection,
  composerToFrame,
  syncResponseWait,
  syncProcessing,
  syncCleanup,
}

enum PerformanceCounter {
  slowFrames,
  syncErrors,
  syncSoftKicks,
  syncHardRestarts,
  syncReconnects,
  frames,
  slowBuildFrames,
  slowRasterFrames,
  timelineNotification,
  messageRowBuild,
  mediaMemoryHit,
  mediaDiskHit,
  mediaDownload,
  mediaFlightJoin,
  avatarRetry,
}

/// Local, bounded diagnostics. No persistence, network upload, or user data.
/// Release defaults to disabled; enable explicitly only for diagnostic builds.
final class PerformanceMetrics {
  PerformanceMetrics({required this.enabled, this.sampleCapacity = 1024}) {
    if (sampleCapacity <= 0) {
      throw ArgumentError.value(
          sampleCapacity, 'sampleCapacity', 'must be positive');
    }
  }

  static final instance = PerformanceMetrics(
    enabled: kProfileMode ||
        const bool.fromEnvironment('CHATFLOW_PERFORMANCE_METRICS'),
  );

  final bool enabled;
  final int sampleCapacity;
  final _samples = <PerformanceOperation, ListQueue<int>>{};
  final _stageSamples = <PerformanceStage, ListQueue<int>>{};
  final _recentTraces = ListQueue<PerformanceRecord>();
  final _counts = <PerformanceOperation, int>{};
  final _counters = <PerformanceCounter, int>{};
  bool _observing = false;
  bool _extensionRegistered = false;

  void record(PerformanceOperation operation, int microseconds) {
    if (!enabled || microseconds < 0) return;
    final samples = _samples.putIfAbsent(operation, ListQueue<int>.new);
    if (samples.length == sampleCapacity) samples.removeFirst();
    samples.addLast(microseconds);
    _counts.update(operation, (n) => n + 1, ifAbsent: () => 1);
  }

  void increment(PerformanceCounter counter) {
    if (!enabled) return;
    _counters.update(counter, (n) => n + 1, ifAbsent: () => 1);
  }

  void recordFrame({
    required int buildUs,
    required int rasterUs,
    required int totalUs,
    required int budgetUs,
  }) {
    if (!enabled) return;
    increment(PerformanceCounter.frames);
    record(PerformanceOperation.frameBuild, buildUs);
    record(PerformanceOperation.frameRaster, rasterUs);
    record(PerformanceOperation.frameTotal, totalUs);
    if (buildUs > budgetUs) increment(PerformanceCounter.slowBuildFrames);
    if (rasterUs > budgetUs) increment(PerformanceCounter.slowRasterFrames);
    if (buildUs > budgetUs || rasterUs > budgetUs) {
      increment(PerformanceCounter.slowFrames);
    }
  }

  PerformanceFrameCounts get frameCounts => PerformanceFrameCounts(
        total: _counters[PerformanceCounter.frames] ?? 0,
        slow: _counters[PerformanceCounter.slowFrames] ?? 0,
        slowBuild: _counters[PerformanceCounter.slowBuildFrames] ?? 0,
        slowRaster: _counters[PerformanceCounter.slowRasterFrames] ?? 0,
      );

  /// The trace closes on this path. Work is bounded by the fixed stage enum;
  /// the hot-path mark/recordFrame methods never sort, encode or perform I/O.
  void recordTrace(PerformanceRecord trace) {
    if (!enabled) return;
    if (_recentTraces.length == sampleCapacity) _recentTraces.removeFirst();
    _recentTraces.addLast(trace);
    record(PerformanceOperation.values.byName(trace.operation.name),
        trace.totalUs);
    var previous = 0;
    for (final entry in trace.stagesUs.entries) {
      final elapsed = entry.value - previous;
      if (elapsed < 0) continue;
      final samples = _stageSamples.putIfAbsent(entry.key, ListQueue<int>.new);
      if (samples.length == sampleCapacity) samples.removeFirst();
      samples.addLast(elapsed);
      previous = entry.value;
    }
  }

  Map<String, Object> snapshot() => {
        'schema': 1,
        'enabled': enabled,
        'sampleCapacity': sampleCapacity,
        'operations': {
          for (final entry in _samples.entries)
            entry.key.name: _summary(entry.value, _counts[entry.key]!),
        },
        'stages': {
          for (final entry in _stageSamples.entries)
            entry.key.wireName: _summary(entry.value, entry.value.length),
        },
        'recentTraces': [
          for (final trace in _recentTraces)
            {
              ...trace.toLocalDiagnosticJson(),
              'bottleneck':
                  PerformanceBottleneckClassifier.classify(trace).wireName,
            }
        ],
        'counters': {
          for (final entry in _counters.entries) entry.key.name: entry.value,
        },
      };

  Map<String, int> _summary(ListQueue<int> samples, int count) {
    final sorted = samples.toList()..sort();
    int percentile(double p) => sorted[(sorted.length * p).ceil() - 1];
    return {
      'count': count,
      'retainedSamples': sorted.length,
      'p50Us': percentile(.5),
      'p95Us': percentile(.95),
      'p99Us': percentile(.99),
      'maxUs': sorted.last,
    };
  }

  void reset() {
    _samples.clear();
    _stageSamples.clear();
    _recentTraces.clear();
    _counts.clear();
    _counters.clear();
  }

  /// Attach once after WidgetsFlutterBinding.ensureInitialized(). Query locally
  /// through the VM service extension; no diagnostic UI or server endpoint.
  void startFrameObservation() {
    if (!enabled || _observing) return;
    _observing = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    if (!_extensionRegistered) {
      _extensionRegistered = true;
      developer.registerExtension('ext.chatflow.performance',
          (_, parameters) async {
        final result = snapshot();
        if (parameters['reset'] == 'true') reset();
        return developer.ServiceExtensionResponse.result(jsonEncode(result));
      });
    }
  }

  void stopFrameObservation() {
    if (!_observing) return;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _observing = false;
  }

  void _onTimings(List<FrameTiming> timings) {
    final hz =
        PlatformDispatcher.instance.implicitView?.display.refreshRate ?? 60;
    final budgetUs = (1000000 / (hz > 0 ? hz : 60)).round();
    for (final timing in timings) {
      // totalSpan contains pipeline latency and is NOT a dropped-frame count.
      recordFrame(
        buildUs: timing.buildDuration.inMicroseconds,
        rasterUs: timing.rasterDuration.inMicroseconds,
        totalUs: timing.totalSpan.inMicroseconds,
        budgetUs: budgetUs,
      );
    }
  }
}
