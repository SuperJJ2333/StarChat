import 'dart:async';
import 'chat_diagnostics.dart';
import 'network_state_manager.dart';

/// Observe an operation without changing its result, error or session lifetime.
Future<T> traceChatOperation<T>({
  required ChatDiagnosticStage stage,
  required Future<T> Function() operation,
  ChatDiagnostics? diagnostics,
  bool Function(Object)? isCancellation,
}) async {
  final collector = diagnostics ?? ChatDiagnostics.instance;
  final generation = collector.sessionGeneration;
  final watch = Stopwatch()..start();
  try {
    final result = await operation();
    if (generation == collector.sessionGeneration) {
      collector.record(
          stage: stage,
          error: ChatDiagnosticError.slow,
          elapsed: watch.elapsed);
    }
    return result;
  } catch (error) {
    if (generation == collector.sessionGeneration &&
        !(isCancellation?.call(error) ?? false)) {
      final status = networkFailureHttpStatus(error);
      collector.record(
          stage: stage,
          error: error is TimeoutException
              ? ChatDiagnosticError.timeout
              : status != null
                  ? ChatDiagnosticError.rejected
                  : defaultNetworkFailureClassifier(error)
                      ? ChatDiagnosticError.network
                      : ChatDiagnosticError.unknown,
          status: status,
          elapsed: watch.elapsed);
    }
    rethrow;
  }
}
