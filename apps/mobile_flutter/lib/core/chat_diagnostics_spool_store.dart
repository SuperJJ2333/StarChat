import 'package:shared_preferences/shared_preferences.dart';
import 'performance_trace_model.dart';
import 'diagnostic_time_anchor.dart';

/// Local adapter; callers pass only closed metadata serialized by diagnostics.
abstract interface class ChatDiagnosticSpoolStore {
  Future<String?> read();
  Future<void> write(String payload);
  Future<void> clear();
}

final class SharedPreferencesChatDiagnosticSpoolStore
    implements ChatDiagnosticSpoolStore {
  SharedPreferencesChatDiagnosticSpoolStore(this.preferences);
  final SharedPreferences preferences;
  // Retain the established key so schema v2 data is read and migrated in place.
  static const key = 'changliao.diagnostics.spool.v2';
  @override
  Future<String?> read() async => preferences.getString(key);
  @override
  Future<void> write(String payload) async {
    await preferences.setString(key, payload);
  }

  @override
  Future<void> clear() async {
    await preferences.remove(key);
  }
}

/// Local-only envelope identity. Schema v2 entries receive a new identity when
/// admitted to the queue; v3 requires a strict UUID and closed record payload.
({String? queueEntryId, PerformanceDiagnosticOperation record})?
    restoreDiagnosticQueueOperation(Object? raw, {required int schema}) {
  if (schema == 2) {
    final record = restoreDiagnosticOperation(raw);
    return record == null ? null : (queueEntryId: null, record: record);
  }
  if (schema != 3 || raw is! Map<String, dynamic>) return null;
  final id = raw['queue_entry_id'];
  if (id is! String ||
      !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
          .hasMatch(id)) {
    return null;
  }
  final payload = Map<String, dynamic>.of(raw)..remove('queue_entry_id');
  final PerformanceDiagnosticOperation? record =
      payload.containsKey('observation_kind')
          ? restoreDiagnosticObservation(payload)
          : restoreDiagnosticOperation(payload);
  return record == null ? null : (queueEntryId: id, record: record);
}

/// Local partial evidence is a separate closed union member. It cannot carry
/// final outcomes, frame counts, packet counters or content. Optional span
/// indexes preserve the root's actual retry/window without completing it.
PerformanceTraceObservation? restoreDiagnosticObservation(Object? raw) {
  if (raw is! Map<String, dynamic> ||
      raw.keys.any((key) => !const {
            'operation_id',
            'operation',
            'attempt_index',
            'window_index',
            'observation_kind',
            'observed_elapsed_ms',
            'observed_idle_ms',
            'stages',
            'lifecycle',
            'frame_attribution_complete'
          }.contains(key))) {
    return null;
  }
  T? enumValue<T extends Enum>(List<T> values, Object? value) {
    for (final e in values) {
      if (e.wireName == value) return e;
    }
    return null;
  }

  final operation =
      enumValue(PerformanceOperationType.values, raw['operation']);
  final kind =
      enumValue(PerformanceObservationKind.values, raw['observation_kind']);
  final lifecycle = enumValue(PerformanceLifecycle.values, raw['lifecycle']);
  final observed = raw['observed_elapsed_ms'];
  final idle = raw['observed_idle_ms'];
  final stages = raw['stages'];
  final id = raw['operation_id'];
  final attemptIndex = raw['attempt_index'];
  final windowIndex = raw['window_index'];
  if (operation == null ||
      kind == null ||
      lifecycle == null ||
      id is! String ||
      raw['frame_attribution_complete'] != false ||
      observed is! int ||
      observed < 0 ||
      observed > 3600000 ||
      idle is! int ||
      idle < 0 ||
      idle > observed ||
      stages is! List ||
      stages.length > PerformanceThresholds.maxStagesPerTrace) {
    return null;
  }
  if (raw.containsKey('attempt_index') &&
          (attemptIndex is! int ||
              attemptIndex < 0 ||
              attemptIndex > 20 ||
              (operation != PerformanceOperationType.videoPrepare &&
                  operation != PerformanceOperationType.messageSend)) ||
      raw.containsKey('window_index') &&
          (windowIndex is! int ||
              windowIndex < 0 ||
              windowIndex > 1000000 ||
              operation != PerformanceOperationType.callActive) ||
      raw.containsKey('attempt_index') && raw.containsKey('window_index')) {
    return null;
  }
  final offsets = <PerformanceStage, int>{};
  var previous = 0;
  for (final item in stages) {
    if (item is! Map ||
        item.keys.any((key) => key != 'stage' && key != 'elapsed_ms')) {
      return null;
    }
    final stage = enumValue(PerformanceStage.values, item['stage']);
    final ms = item['elapsed_ms'];
    if (stage == null ||
        offsets.containsKey(stage) ||
        ms is! int ||
        ms < previous ||
        ms > observed) {
      return null;
    }
    offsets[stage] = ms * 1000;
    previous = ms;
  }
  // Both offsets and idle were truncated from real microseconds. Their
  // difference can lose one millisecond; accept only that rounding interval.
  final elapsedSinceMark = observed - previous;
  if (idle > elapsedSinceMark || elapsedSinceMark - idle > 1) return null;
  try {
    return PerformanceTraceObservation(
        operationId: id,
        operation: operation,
        kind: kind,
        observedUs: observed * 1000,
        idleUs: idle * 1000,
        lifecycle: lifecycle,
        attemptIndex: attemptIndex as int?,
        windowIndex: windowIndex as int?,
        stagesUs: offsets);
  } on ArgumentError {
    return null;
  }
}

/// Rebuild typed records, discarding arbitrary keys/strings from local storage.
/// Never infer packet counts from a derived percentage.
PerformanceRecord? restoreDiagnosticOperation(Object? raw) {
  if (raw is! Map<String, dynamic> ||
      raw.keys.any((key) => !const {
            'app_network_state',
            'attempt_index',
            'cache_source',
            'clock_uncertainty_ms',
            'cancel_reason',
            'candidate_protocol',
            'database_operation',
            'endpoint_category',
            'ended_at_utc',
            'first_hit_ms',
            'frame_attribution_complete',
            'frames_total',
            'hard_restart_count',
            'full_coverage_ms',
            'jitter_ms',
            'keyboard_direction',
            'last_healthy_sync_age_ms',
            'lifecycle',
            'matrix_state',
            'media_priority',
            'media_type',
            'method',
            'network_error',
            'opening_source',
            'operation',
            'operation_id',
            'packet_loss_percent',
            'packets_lost',
            'packets_received',
            'reconnect_count',
            'relay_protocol',
            'restart_reason',
            'result',
            'result_count_bucket',
            'retry_count',
            'row_count_bucket',
            'rtt_ms',
            'scheduler_active',
            'scheduler_queue',
            'scheduler_video_active',
            'scan_page_count',
            'scan_row_count',
            'service_reachable',
            'size_bucket',
            'slow_build_count',
            'slow_frame_count',
            'slow_raster_count',
            'soft_kick_count',
            'stages',
            'status_code',
            'started_at_utc',
            'sync_error_count',
            'timeline_event_count',
            'time_anchor_age_ms',
            'total_ms',
            'transport_available',
            'uses_turn',
            'room_route_phase',
            'window_index'
          }.contains(key))) {
    return null;
  }
  T? enumValue<T extends Enum>(List<T> values, Object? value) {
    for (final e in values) {
      if (e.wireName == value) return e;
    }
    return null;
  }

  int? integer(String key, int maximum) {
    final v = raw[key];
    return v is int && v >= 0 && v <= maximum ? v : null;
  }

  double? number(String key) {
    final v = raw[key];
    return v is num && v.isFinite && v >= 0 && v <= 60000 ? v.toDouble() : null;
  }

  bool? boolean(String key) {
    final v = raw[key];
    return v is bool ? v : null;
  }

  final operation =
      enumValue(PerformanceOperationType.values, raw['operation']);
  final result = enumValue(PerformanceResult.values, raw['result']);
  final lifecycle = enumValue(PerformanceLifecycle.values, raw['lifecycle']);
  final total = integer('total_ms', 3600000);
  final id = raw['operation_id'];
  final stages = raw['stages'];
  final attemptIndex = integer('attempt_index', 20);
  final windowIndex = integer('window_index', 1000000);
  if (operation == null ||
      result == null ||
      lifecycle == null ||
      total == null ||
      id is! String ||
      stages is! List ||
      stages.length > 64) {
    return null;
  }
  if (raw.containsKey('attempt_index') &&
          (attemptIndex == null ||
              (operation != PerformanceOperationType.videoPrepare &&
                  operation != PerformanceOperationType.messageSend)) ||
      raw.containsKey('window_index') &&
          (windowIndex == null ||
              operation != PerformanceOperationType.callActive) ||
      raw.containsKey('attempt_index') && raw.containsKey('window_index')) {
    return null;
  }
  final keyboardDirection =
      enumValue(PerformanceKeyboardDirection.values, raw['keyboard_direction']);
  final roomRoutePhase =
      enumValue(PerformanceRoomRoutePhase.values, raw['room_route_phase']);
  final restartReason =
      enumValue(PerformanceSearchRestartReason.values, raw['restart_reason']);
  final cancelReason =
      enumValue(PerformanceSearchCancelReason.values, raw['cancel_reason']);
  if ((operation == PerformanceOperationType.keyboardTransition) !=
          (keyboardDirection != null) ||
      (operation == PerformanceOperationType.roomLocalFrame) !=
          (roomRoutePhase != null) ||
      (operation != PerformanceOperationType.historySearch &&
          (raw.containsKey('restart_reason') ||
              raw.containsKey('cancel_reason') ||
              raw.containsKey('scan_page_count') ||
              raw.containsKey('scan_row_count') ||
              raw.containsKey('first_hit_ms') ||
              raw.containsKey('full_coverage_ms'))) ||
      (operation != PerformanceOperationType.matrixSync &&
          raw.containsKey('timeline_event_count')) ||
      (raw.containsKey('restart_reason') && restartReason == null) ||
      (raw.containsKey('cancel_reason') && cancelReason == null)) {
    return null;
  }
  for (final (key, maximum) in [
    ('timeline_event_count', 100000),
    ('scan_page_count', 100000),
    ('scan_row_count', 10000000),
    ('first_hit_ms', 3600000),
    ('full_coverage_ms', 3600000),
  ]) {
    if (raw.containsKey(key) && integer(key, maximum) == null) return null;
  }
  final offsets = <PerformanceStage, int>{};
  var previous = 0;
  for (final item in stages) {
    if (item is! Map ||
        item.keys.any((key) => key != 'stage' && key != 'elapsed_ms')) {
      return null;
    }
    final stage = enumValue(PerformanceStage.values, item['stage']);
    final ms = item['elapsed_ms'];
    if (stage == null ||
        offsets.containsKey(stage) ||
        ms is! int ||
        ms < previous ||
        ms > total) {
      return null;
    }
    offsets[stage] = ms * 1000;
    previous = ms;
  }
  final frameAttributionComplete =
      boolean('frame_attribution_complete') ?? false;
  final measuredSlow = integer('slow_frame_count', 1000000);
  final measuredBuild = integer('slow_build_count', 1000000);
  final measuredRaster = integer('slow_raster_count', 1000000);
  final measuredTotal = integer('frames_total', 1000000);
  if (frameAttributionComplete &&
      (measuredSlow == null ||
          measuredBuild == null ||
          measuredRaster == null ||
          measuredTotal == null)) {
    return null;
  }
  final slow = measuredSlow ?? 0;
  final build = measuredBuild ?? 0;
  final raster = measuredRaster ?? 0;
  final frameTotal = measuredTotal ?? 0;
  if (slow > frameTotal ||
      build > slow ||
      raster > slow ||
      slow > build + raster) {
    return null;
  }
  const utcKeys = {
    'started_at_utc',
    'ended_at_utc',
    'clock_uncertainty_ms',
    'time_anchor_age_ms',
  };
  final utcPresent = utcKeys.where(raw.containsKey).length;
  if (utcPresent != 0 && utcPresent != utcKeys.length) return null;
  final utcWindow =
      utcPresent == 0 ? null : DiagnosticUtcWindow.restore(raw, total);
  if (utcPresent > 0 && utcWindow == null) return null;
  try {
    return PerformanceRecord(
      operationId: id,
      operation: operation,
      totalUs: total * 1000,
      stagesUs: offsets,
      result: result,
      lifecycle: lifecycle,
      frames: PerformanceFrameCounts(
          total: frameTotal, slow: slow, slowBuild: build, slowRaster: raster),
      frameAttributionComplete: frameAttributionComplete,
      openingSource:
          enumValue(PerformanceOpeningSource.values, raw['opening_source']),
      appNetworkState: enumValue(
              PerformanceAppNetworkState.values, raw['app_network_state']) ??
          PerformanceAppNetworkState.unknown,
      matrixState:
          enumValue(PerformanceMatrixState.values, raw['matrix_state']) ??
              PerformanceMatrixState.unknown,
      networkError:
          enumValue(PerformanceNetworkError.values, raw['network_error']),
      endpointCategory: enumValue(
          PerformanceEndpointCategory.values, raw['endpoint_category']),
      httpMethod: enumValue(PerformanceHttpMethod.values, raw['method']),
      cacheSource:
          enumValue(PerformanceCacheSource.values, raw['cache_source']),
      mediaType: enumValue(PerformanceMediaType.values, raw['media_type']),
      sizeBucket: enumValue(PerformanceSizeBucket.values, raw['size_bucket']),
      databaseOperation: enumValue(
          PerformanceDatabaseOperation.values, raw['database_operation']),
      rowCountBucket:
          enumValue(PerformanceRowCountBucket.values, raw['row_count_bucket']),
      resultCountBucket: enumValue(
          PerformanceRowCountBucket.values, raw['result_count_bucket']),
      mediaPriority:
          enumValue(PerformanceMediaPriority.values, raw['media_priority']),
      relayProtocol:
          enumValue(PerformanceRelayProtocol.values, raw['relay_protocol']),
      candidateProtocol:
          enumValue(PerformanceRelayProtocol.values, raw['candidate_protocol']),
      transportAvailable: boolean('transport_available'),
      serviceReachable: boolean('service_reachable'),
      usesTurn: boolean('uses_turn'),
      statusCode: (integer('status_code', 599) ?? 0) >= 100
          ? integer('status_code', 599)
          : null,
      retryCount: integer('retry_count', 20) ?? 0,
      attemptIndex: attemptIndex,
      windowIndex: windowIndex,
      softKickCount: integer('soft_kick_count', 1000) ?? 0,
      hardRestartCount: integer('hard_restart_count', 1000) ?? 0,
      syncErrorCount: integer('sync_error_count', 1000),
      timelineEventCount: integer('timeline_event_count', 100000),
      utcWindow: utcWindow,
      searchRestartReason: restartReason,
      searchCancelReason: cancelReason,
      keyboardDirection: keyboardDirection,
      roomRoutePhase: roomRoutePhase,
      scanPageCount: integer('scan_page_count', 100000),
      scanRowCount: integer('scan_row_count', 10000000),
      firstHitMs: integer('first_hit_ms', 3600000),
      fullCoverageMs: integer('full_coverage_ms', 3600000),
      reconnectCount: integer('reconnect_count', 1000),
      lastHealthySyncAgeMs: integer('last_healthy_sync_age_ms', 3600000),
      schedulerQueue: integer('scheduler_queue', 1000),
      schedulerActive: integer('scheduler_active', 1000),
      schedulerVideoActive: integer('scheduler_video_active', 1000),
      packetsLost: integer('packets_lost', 2147483647),
      packetsReceived: integer('packets_received', 2147483647),
      rttMs: number('rtt_ms'),
      jitterMs: number('jitter_ms'),
    );
  } on ArgumentError {
    return null;
  }
}
