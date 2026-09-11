import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

// Closed enums deliberately prevent identifiers, URLs or content in telemetry.
enum PerformanceOperation {
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
}

enum PerformanceCounter {
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
  }

  Map<String, Object> snapshot() => {
        'schema': 1,
        'enabled': enabled,
        'sampleCapacity': sampleCapacity,
        'operations': {
          for (final entry in _samples.entries)
            entry.key.name: _summary(entry.value, _counts[entry.key]!),
        },
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
