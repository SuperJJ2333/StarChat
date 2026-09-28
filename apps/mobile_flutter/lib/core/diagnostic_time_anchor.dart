import 'dart:io';

/// A calibrated event window based on a fresh authenticated HTTP Date header.
/// It contains no local wall-clock value, URL, account identifier or header.
final class DiagnosticUtcWindow {
  const DiagnosticUtcWindow({
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.clockUncertaintyMs,
    required this.timeAnchorAgeMs,
  });

  final String startedAtUtc;
  final String endedAtUtc;
  final int clockUncertaintyMs;
  final int timeAnchorAgeMs;

  static final _utc = RegExp(
    r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)$',
  );

  static DiagnosticUtcWindow? restore(Map<String, dynamic> raw, int totalMs) {
    final startText = raw['started_at_utc'];
    final endText = raw['ended_at_utc'];
    final uncertainty = raw['clock_uncertainty_ms'];
    final age = raw['time_anchor_age_ms'];
    if (startText is! String ||
        endText is! String ||
        !_utc.hasMatch(startText) ||
        !_utc.hasMatch(endText) ||
        uncertainty is! int ||
        uncertainty < 0 ||
        uncertainty > 2000 ||
        age is! int ||
        age < 0 ||
        age > 300000) {
      return null;
    }
    final start = DateTime.tryParse(startText);
    final end = DateTime.tryParse(endText);
    if (start == null || end == null || end.isBefore(start)) return null;
    if ((end.difference(start).inMilliseconds - totalMs).abs() >
        uncertainty + 1000) {
      return null;
    }
    return DiagnosticUtcWindow(
      startedAtUtc: startText,
      endedAtUtc: endText,
      clockUncertaintyMs: uncertainty,
      timeAnchorAgeMs: age,
    );
  }

  Map<String, Object> toJson() => {
        'started_at_utc': startedAtUtc,
        'ended_at_utc': endedAtUtc,
        'clock_uncertainty_ms': clockUncertaintyMs,
        'time_anchor_age_ms': timeAnchorAgeMs,
      };
}

/// Uses monotonic request boundaries; never samples the device wall clock.
final class DiagnosticTimeAnchor {
  DateTime? _serverDateUtc;
  int? _midpointMs;
  int? _observedMs;
  int? _uncertaintyMs;

  static final _httpDate = RegExp(
    r'^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d\d:\d\d:\d\d GMT$',
  );

  bool observe({
    required String? dateHeader,
    required int sentAtMs,
    required int receivedAtMs,
  }) {
    final rttMs = receivedAtMs - sentAtMs;
    if (dateHeader == null ||
        !_httpDate.hasMatch(dateHeader) ||
        sentAtMs < 0 ||
        rttMs < 0 ||
        rttMs > 2000 ||
        (_observedMs != null && receivedAtMs < _observedMs!)) {
      return false;
    }
    DateTime serverDate;
    try {
      serverDate = HttpDate.parse(dateHeader).toUtc();
    } on FormatException {
      return false;
    } on HttpException {
      return false;
    }
    if (HttpDate.format(serverDate) != dateHeader) return false;
    _serverDateUtc = serverDate;
    _midpointMs = sentAtMs + rttMs ~/ 2;
    _observedMs = receivedAtMs;
    _uncertaintyMs = 1000 + rttMs ~/ 2;
    return true;
  }

  DiagnosticUtcWindow? window(int startMs, int endMs) {
    final serverDate = _serverDateUtc;
    final midpoint = _midpointMs;
    final observed = _observedMs;
    final uncertainty = _uncertaintyMs;
    if (serverDate == null ||
        midpoint == null ||
        observed == null ||
        uncertainty == null ||
        startMs < 0 ||
        endMs < startMs ||
        endMs < observed ||
        observed - startMs > 300000 ||
        endMs - observed > 300000) {
      return null;
    }
    final start = serverDate.add(Duration(milliseconds: startMs - midpoint));
    final end = serverDate.add(Duration(milliseconds: endMs - midpoint));
    return DiagnosticUtcWindow(
      startedAtUtc: start.toIso8601String(),
      endedAtUtc: end.toIso8601String(),
      clockUncertaintyMs: uncertainty,
      timeAnchorAgeMs: endMs - observed,
    );
  }

  void reset() {
    _serverDateUtc = null;
    _midpointMs = null;
    _observedMs = null;
    _uncertaintyMs = null;
  }
}
