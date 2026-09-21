import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'chat_diagnostics.dart';

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
      this.diagnostics});
  final int sessionEpoch;
  final String version;
  final ChatDiagnosticPlatform platform;
  final ChatDiagnosticUploader upload;
  final ChatDiagnostics? diagnostics;
  final Widget child;
  @override
  State<ChatDiagnosticsScope> createState() => _ChatDiagnosticsScopeState();
}

final class _ChatDiagnosticsScopeState extends State<ChatDiagnosticsScope> {
  late ChatDiagnostics _diagnostics;
  int _generation = -1;
  void _start() {
    _diagnostics = widget.diagnostics ?? ChatDiagnostics.instance;
    _diagnostics.startSession(
        version: widget.version,
        platform: widget.platform,
        upload: widget.upload);
    _generation = _diagnostics.sessionGeneration;
  }

  void _stop() {
    if (_diagnostics.sessionGeneration == _generation) {
      _diagnostics.stopSession();
    }
  }

  @override
  void initState() {
    super.initState();
    _start();
    SchedulerBinding.instance.addTimingsCallback(_timings);
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
    var maximum = Duration.zero;
    var count = 0;
    for (final frame in timings) {
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
