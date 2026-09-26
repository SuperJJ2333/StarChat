import 'package:shared_preferences/shared_preferences.dart';
import 'performance_trace_model.dart';

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

/// Rebuild typed records, discarding arbitrary keys/strings from local storage.
/// Never infer packet counts from a derived percentage.
PerformanceRecord? restoreDiagnosticOperation(Object? raw) {
  if (raw is! Map<String, dynamic> ||
      raw.keys.any((key) => !const {
            'app_network_state',
            'cache_source',
            'candidate_protocol',
            'database_operation',
            'endpoint_category',
            'frame_attribution_complete',
            'frames_total',
            'hard_restart_count',
            'jitter_ms',
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
            'result',
            'result_count_bucket',
            'retry_count',
            'row_count_bucket',
            'rtt_ms',
            'scheduler_active',
            'scheduler_queue',
            'scheduler_video_active',
            'service_reachable',
            'size_bucket',
            'slow_build_count',
            'slow_frame_count',
            'slow_raster_count',
            'soft_kick_count',
            'stages',
            'status_code',
            'sync_error_count',
            'total_ms',
            'transport_available',
            'uses_turn'
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
  if (operation == null ||
      result == null ||
      lifecycle == null ||
      total == null ||
      id is! String ||
      stages is! List ||
      stages.length > 64) {
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
      softKickCount: integer('soft_kick_count', 1000) ?? 0,
      hardRestartCount: integer('hard_restart_count', 1000) ?? 0,
      syncErrorCount: integer('sync_error_count', 1000),
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
