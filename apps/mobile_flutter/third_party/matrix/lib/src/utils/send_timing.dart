import 'dart:async';

/// Local diagnostic categories. No identifiers or message data cross this hook.
enum MatrixSendTiming {
  localEcho,
  queueWait,
  sessionLoad,
  sessionCheck,
  sessionCreate,
  encrypt,
  sessionPersist,
  http,
  acknowledgement,
}

typedef MatrixSendTimingObserver = void Function(
    MatrixSendTiming phase, int microseconds);

T measureMatrixSendSync<T>(MatrixSendTiming phase, T Function() work,
    MatrixSendTimingObserver? observer) {
  if (observer == null) return work();
  final watch = Stopwatch()..start();
  try {
    return work();
  } finally {
    watch.stop();
    try {
      observer(phase, watch.elapsedMicroseconds);
    } catch (_) {}
  }
}

Future<T> measureMatrixSend<T>(MatrixSendTiming phase,
    FutureOr<T> Function() work, MatrixSendTimingObserver? observer) async {
  if (observer == null) return await work();
  final watch = Stopwatch()..start();
  try {
    return await work();
  } finally {
    watch.stop();
    try {
      observer(phase, watch.elapsedMicroseconds);
    } catch (_) {
      // Diagnostics must never replace a result or a protocol failure.
    }
  }
}
