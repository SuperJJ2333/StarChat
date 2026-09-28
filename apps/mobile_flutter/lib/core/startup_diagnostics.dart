import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'startup_failure_metadata.dart';
import 'startup_diagnostics_spool.dart';
import 'startup_diagnostics_transport.dart';

final class _Event {
  _Event(this.body, {required this.signature, this.frozen = false});
  Map<String, Object> body;
  final String? signature;
  bool frozen;
}

/// Terminal failures only. Capture is synchronous/no-throw and never touches
/// storage, keys, a session or the network. All asynchronous work is optional.
final class StartupDiagnostics {
  // Saturation suppresses further capture instead of evicting signatures:
  // previously attempted failures must stay suppressed until process exit.
  static const maxProcessSignatures = 128;
  StartupDiagnostics(
      {required this.spool,
      required this.transport,
      required String appVersion,
      required int buildNumber,
      required String osVersion,
      bool? enabled,
      DateTime Function()? clock,
      String Function()? eventIdFactory,
      this.ioTimeout = const Duration(milliseconds: 500),
      this.uploadTimeout = const Duration(seconds: 5),
      this.retryDelays = const [
        Duration(seconds: 30),
        Duration(minutes: 2),
        Duration(minutes: 10)
      ]})
      : _appVersion = appVersion,
        _buildNumber = buildNumber,
        _osVersion = safeStartupDiagnosticsOsVersion(osVersion),
        enabled = enabled ?? Platform.isIOS,
        _clock = clock ?? DateTime.now,
        _eventIdFactory = eventIdFactory ?? const Uuid().v4;
  final StartupDiagnosticsSpool spool;
  final StartupDiagnosticsTransport transport;
  final bool enabled;
  final DateTime Function() _clock;
  final String Function() _eventIdFactory;
  final Duration ioTimeout, uploadTimeout;
  final List<Duration> retryDelays;
  String _appVersion;
  int _buildNumber;
  final String _osVersion;
  final _events = <_Event>[];
  final _frozenSignatures = <String>{};
  Future<void>? _initializing, _flushing;
  Future<StartupDiagnosticsUploadResult>? _pendingUpload;
  Completer<void>? _attemptAbort;
  Future<void> _io = Future.value();
  bool _spoolAvailable = true, _disposed = false;
  int _retry = 0;
  Timer? _retryTimer;
  final _abort = Completer<void>();

  void updateVersion(String appVersion, int buildNumber) {
    try {
      if (!isStartupDiagnosticsAppVersion(appVersion) ||
          buildNumber < 1 ||
          buildNumber > 10000000) {
        return;
      }
      _appVersion = appVersion;
      _buildNumber = buildNumber;
      for (final event in _events.where((event) => !event.frozen)) {
        event.body = {
          ...event.body,
          'app_version': appVersion,
          'build': buildNumber
        };
      }
    } catch (_) {/* Observation must never alter startup. */}
  }

  void record(StartupFailureStage stage, StartupFailureMetadata failure) {
    try {
      if (!enabled || _disposed) return;
      final signature = [
        stage.wireName,
        failure.boundary.wireName,
        failure.category.wireName,
        failure.preflightCause?.wireName,
        failure.nativeStatus?.wireValue,
        failure.loginStage?.wireName
      ].join('|');
      if (_frozenSignatures.contains(signature)) return;
      if (_frozenSignatures.length >= maxProcessSignatures) return;
      _prune();
      for (final event in _events) {
        if (event.signature == signature && !event.frozen) {
          final count = event.body['count'] as int;
          if (count < 100) event.body = {...event.body, 'count': count + 1};
          return;
        }
      }
      final time = _clock().toUtc();
      final minute =
          DateTime.utc(time.year, time.month, time.day, time.hour, time.minute)
              .toIso8601String()
              .replaceFirst('.000Z', 'Z');
      final body = <String, Object>{
        'schema': 1,
        'platform': 'ios',
        'event_id': _eventIdFactory(),
        'app_version': _appVersion,
        'build': _buildNumber,
        'os_version': _osVersion,
        'occurred_at': minute,
        'stage': stage.wireName,
        'boundary': failure.boundary.wireName,
        'category': failure.category.wireName,
        if (failure.preflightCause != null)
          'preflight_cause': failure.preflightCause!.wireName,
        if (failure.nativeStatus != null)
          'native_status': failure.nativeStatus!.wireValue,
        if (failure.loginStage != null)
          'login_stage': failure.loginStage!.wireName,
        'count': 1
      };
      if (validateStartupDiagnosticsReport(body, now: time) == null) return;
      _events.add(_Event(body, signature: signature));
      _prune();
    } catch (_) {/* No raw error is retained or recursively reported. */}
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    if (!enabled || _disposed) return;
    try {
      final restored = await spool.read().timeout(ioTimeout);
      if (_disposed) return;
      final accepted =
          boundedStartupDiagnosticsReports(restored, now: _clock());
      final ids = _events.map((event) => event.body['event_id']).toSet();
      _events.insertAll(0, [
        for (final body in accepted)
          if (!ids.contains(body['event_id']))
            _Event(body, signature: null, frozen: true)
      ]);
      _prune();
      await _persist();
    } catch (_) {
      _spoolAvailable = false;
    }
  }

  Future<void> flush() {
    if (!enabled || _disposed) return Future.value();
    if (_flushing != null) return _flushing!;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retry = 0;
    return _startFlush();
  }

  Future<void> _startFlush() {
    final work = _flush();
    _flushing = work;
    return work.whenComplete(() => _flushing = null);
  }

  Future<void> _flush() async {
    try {
      await initialize();
      if (_disposed) return;
      _prune();
      await _persist();
      // A non-cooperative injected uploader can outlive our waiting deadline.
      // Keep its attempt tracked until it actually ends, so no second upload
      // runs concurrently and a late acceptance never removes current memory.
      if (_pendingUpload != null) return;
      while (_events.isNotEmpty && !_disposed) {
        final event = _events.first;
        if (event.signature != null &&
            !_frozenSignatures.contains(event.signature) &&
            _frozenSignatures.length >= maxProcessSignatures) {
          _events.remove(event);
          await _persist();
          continue;
        }
        event.frozen = true;
        if (event.signature != null) _frozenSignatures.add(event.signature!);
        final snapshot = Map<String, Object>.unmodifiable(event.body);
        // Frozen state is represented by immutable wire bodies after restart;
        // no count or identity can change across retry attempts.
        await _persist();
        final attemptAbort = Completer<void>();
        _attemptAbort = attemptAbort;
        final operation = transport
            .upload(snapshot, abort: attemptAbort.future)
            .then((value) => value,
                onError: (Object _) => StartupDiagnosticsUploadResult.retry);
        _pendingUpload = operation;
        unawaited(operation.then((_) {
          if (identical(_pendingUpload, operation)) _pendingUpload = null;
          if (identical(_attemptAbort, attemptAbort)) _attemptAbort = null;
        }));
        final result = await Future.any([
          operation,
          _abort.future.then((_) => StartupDiagnosticsUploadResult.retry),
        ]).timeout(uploadTimeout, onTimeout: () {
          if (!attemptAbort.isCompleted) attemptAbort.complete();
          return StartupDiagnosticsUploadResult.retry;
        });
        if (_disposed) return;
        if (result == StartupDiagnosticsUploadResult.retry) {
          _scheduleRetry();
          return;
        }
        _events.remove(event);
        await _persist();
      }
    } catch (_) {
      if (!_disposed) _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_disposed || _retry >= retryDelays.length) return;
    _retryTimer = Timer(retryDelays[_retry++], () {
      _retryTimer = null;
      if (!_disposed && _flushing == null) unawaited(_startFlush());
    });
  }

  void _prune() {
    final now = _clock();
    _events.removeWhere((event) =>
        validateStartupDiagnosticsReport(event.body, now: now) == null);
    while (_events.length > startupDiagnosticsMaxEvents ||
        utf8
                .encode(jsonEncode(_events.map((event) => event.body).toList()))
                .length >
            startupDiagnosticsMaxBytes) {
      _events.removeAt(0);
    }
  }

  Future<void> _persist() async {
    if (!_spoolAvailable || _disposed) return;
    _io = _io.then((_) async {
      if (!_spoolAvailable || _disposed) return;
      final snapshot = [
        for (final event in _events)
          Map<String, Object>.unmodifiable(event.body)
      ];
      try {
        await spool.write(snapshot).timeout(ioTimeout);
      } catch (_) {
        _spoolAvailable = false;
      }
    });
    await _io;
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_attemptAbort != null && !_attemptAbort!.isCompleted) {
      _attemptAbort!.complete();
    }
    if (!_abort.isCompleted) _abort.complete();
  }
}
