import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'chat_diagnostics.dart';
import 'performance_metrics.dart';
import 'performance_trace.dart';

/// Diagnostics live exactly as long as the authenticated application. No
/// account identifier is persisted or sent by this scope.
final class ChatDiagnosticsScope extends StatefulWidget {
  const ChatDiagnosticsScope(
      {super.key,
      required this.sessionEpoch,
      required this.version,
      required this.platform,
      required this.upload,
      required this.child,
      this.diagnostics,
      this.performanceMetrics});
  final int sessionEpoch;
  final String version;
  final ChatDiagnosticPlatform platform;
  final ChatDiagnosticUploader upload;
  final ChatDiagnostics? diagnostics;
  final PerformanceMetrics? performanceMetrics;
  final Widget child;
  @override
  State<ChatDiagnosticsScope> createState() => _ChatDiagnosticsScopeState();
}

final class _ChatDiagnosticsScopeState extends State<ChatDiagnosticsScope>
    with WidgetsBindingObserver {
  late ChatDiagnostics _diagnostics;
  int _generation = -1;
  void _start() {
    _diagnostics = widget.diagnostics ?? ChatDiagnostics.instance;
    _diagnostics.startSession(
        version: widget.version,
        platform: widget.platform,
        upload: widget.upload);
    _generation = _diagnostics.sessionGeneration;
    PerformanceTraceRecorder.instance.lifecycle =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed
            ? PerformanceLifecycle.foreground
            : PerformanceLifecycle.background;
  }

  void _stop() {
    if (_diagnostics.sessionGeneration == _generation) {
      _diagnostics.stopSession();
      PerformanceTraceRecorder.instance.clear();
      (widget.performanceMetrics ?? PerformanceMetrics.instance).reset();
      PerformanceTraceRecorder.instance.lifecycle =
          PerformanceLifecycle.unknown;
    }
  }

  @override
  void initState() {
    super.initState();
    _start();
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_timings);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final recorder = PerformanceTraceRecorder.instance;
    if (state != AppLifecycleState.resumed) {
      recorder.lifecycle = PerformanceLifecycle.background;
      return;
    }
    recorder.lifecycle = PerformanceLifecycle.resuming;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation) {
        recorder.lifecycle = PerformanceLifecycle.foreground;
      }
    });
  }

  @override
  void didUpdateWidget(covariant ChatDiagnosticsScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionEpoch != widget.sessionEpoch ||
        oldWidget.diagnostics != widget.diagnostics) {
      _stop();
      _start();
    }
  }

  void _timings(List<FrameTiming> timings) {
    if (_diagnostics.sessionGeneration != _generation) return;
    final foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final refreshRate = View.maybeOf(context)?.display.refreshRate ?? 60;
    final budgetUs =
        (1000000 / (refreshRate.isFinite && refreshRate > 0 ? refreshRate : 60))
            .round();
    var maximum = Duration.zero;
    var count = 0;
    for (final frame in timings) {
      if (foreground) {
        _diagnostics.recordFrame(
            buildUs: frame.buildDuration.inMicroseconds,
            rasterUs: frame.rasterDuration.inMicroseconds,
            budgetUs: budgetUs);
      }
      if (frame.totalSpan.inMilliseconds < 250) continue;
      count++;
      if (frame.totalSpan > maximum) maximum = frame.totalSpan;
    }
    if (count > 0) {
      _diagnostics.record(
          stage: ChatDiagnosticStage.framework,
          error: ChatDiagnosticError.slow,
          elapsed: maximum,
          count: count);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

bool _installed = false;
void installChatErrorReporter() {
  if (_installed) return;
  _installed = true;
  final previousFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    ChatDiagnostics.instance.record(
        stage: ChatDiagnosticStage.framework,
        error: ChatDiagnosticError.unknown);
    (previousFlutter ?? FlutterError.presentError)(details);
  };
  final previousPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    ChatDiagnostics.instance.record(
        stage: ChatDiagnosticStage.framework,
        error: ChatDiagnosticError.unknown);
    return previousPlatform?.call(error, stack) ?? false;
  };
}
