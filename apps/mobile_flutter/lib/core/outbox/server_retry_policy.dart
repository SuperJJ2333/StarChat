/// Shared foreground/background automatic retry budget. Never shorten Retry-After.
abstract final class ServerRetryPolicy {
  static const delays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];

  static Duration? delay(int consumed, Object error) {
    if (consumed < 0 || consumed >= delays.length) return null;
    var delay = delays[consumed];
    try {
      final dynamic failure = error;
      final Object? milliseconds = failure.retryAfterMs;
      if (milliseconds is int && milliseconds > delay.inMilliseconds) {
        if (milliseconds > 900000) return null;
        delay = Duration(milliseconds: milliseconds);
      }
    } catch (_) {}
    try {
      final dynamic failure = error;
      final Object? seconds = failure.retryAfterSeconds;
      if (seconds is int && seconds > delay.inSeconds) {
        if (seconds > 900) return null;
        delay = Duration(seconds: seconds);
      }
    } catch (_) {}
    return delay > const Duration(minutes: 15) ? null : delay;
  }
}
