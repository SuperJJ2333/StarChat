import 'dart:ui';
import 'package:flutter/foundation.dart';
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
      this.performanceMetrics,
      this.spool,
      this.spoolScope});
  final int sessionEpoch;
  final String version;
  final ChatDiagnosticPlatform platform;
  final ChatDiagnosticUploader upload;
  final ChatDiagnostics? diagnostics;
  final PerformanceMetrics? performanceMetrics;
  final ChatDiagnosticSpoolStore? spool;
  final Future<String?> Function()? spoolScope;
  bool get collectsFrames =>
      (performanceMetrics ?? PerformanceMetrics.instance).enabled;
  final Widget child;
  @override
  State<ChatDiagnosticsScope> createState() => _ChatDiagnosticsScopeState();
}

final class _ChatDiagnosticsScopeState extends State<ChatDiagnosticsScope>
    with WidgetsBindingObserver {
  late ChatDiagnostics _diagnostics;
  int _generation = -1;
  late PerformanceMetrics _metrics;
  void _start() {
    _diagnostics = widget.diagnostics ?? ChatDiagnostics.instance;
    _diagnostics.startSession(
        version: widget.version,
        platform: widget.platform,
        upload: widget.upload,
        store: widget.spool,
        spoolScope: widget.spoolScope);
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
      _metrics.reset();
      PerformanceTraceRecorder.instance.lifecycle =
          PerformanceLifecycle.unknown;
    }
  }

  @override
  void initState() {
    super.initState();
    _start();
    WidgetsBinding.instance.addObserver(this);
    _metrics = widget.performanceMetrics ?? PerformanceMetrics.instance;
    if (widget.collectsFrames) _metrics.addFrameTimingListener(_timings);
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
        oldWidget.diagnostics != widget.diagnostics ||
        oldWidget.spool != widget.spool ||
        oldWidget.performanceMetrics != widget.performanceMetrics) {
      _metrics.removeFrameTimingListener(_timings);
      _stop();
      _metrics = widget.performanceMetrics ?? PerformanceMetrics.instance;
      _start();
      if (widget.collectsFrames) _metrics.addFrameTimingListener(_timings);
    }
  }

  void _timings(List<FrameTiming> timings, int budgetUs, bool clockValid) {
    if (_diagnostics.sessionGeneration != _generation) return;
    final foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
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
    _metrics.removeFrameTimingListener(_timings);
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
