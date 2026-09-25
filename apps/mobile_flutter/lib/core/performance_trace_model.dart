/// Closed performance metadata. No model accepts arbitrary labels or content.
/// Thresholds affect diagnostics only; never business results or retries.
abstract final class PerformanceThresholds {
  static const conversationFirstFrameMs = 500;
  static const conversationLocalReadyMs = 1000;
  static const localDatabaseMs = 100;
  static const businessApiMs = 1000;
  static const mediaFirstVisibleMs = 1000;
  static const callSetupMs = 3000;
  static const messageSendMs = 1000;
  static const mediaTranscodeMs = 3000;
  static const slowFrameCountWarning = 4;
  static const syncWaitMs = 1000;
  static const syncProcessingMs = 500;
  static const callRttMs = 200;
  static const callJitterMs = 50;
  static const callPacketLossPercent = 5;
  static const normalSamplePercent = 5;
  static const maxActiveTraces = 100;
  static const maxStagesPerTrace = 64;
  static const frameTimingAttributionTimeout = Duration(milliseconds: 1200);
  static const remoteSyncObservationWindow = Duration(seconds: 45);
  static const messageTraceObservationWindow = Duration(minutes: 5);
}

enum PerformanceOperationType {
  appStartup,
  appResume,
  conversationOpen,
  messageSend,
  matrixSync,
  mediaLoad,
  recentPicturesLoad,
  videoPrepare,
  videoPoster,
  search,
  searchPageOpen,
  contactsLoad,
  momentsLoad,
  walletLoad,
  apiRequest,
  callSetup,
  callActive,
  profileLoad,
  chatListLoad,
}

enum PerformanceStage {
  userAction,
  identityLookupDone,
  localRoomLookupDone,
  routeEnter,
  routePushStarted,
  firstFrameRendered,
  roomAttachStarted,
  roomAttachDone,
  timelineLocalStarted,
  localTimelineReady,
  remoteSyncReady,
  matrixConnected,
  syncFinished,
  conversationReady,
  contentReady,
  cacheLoadStarted,
  cacheLoadDone,
  remoteRefreshStarted,
  remoteRefreshDone,
  composerSubmit,
  outboxPersist,
  sendAdmission,
  matrixSendStart,
  matrixSendFinish,
  ack,
  timelineVisible,
  syncResponseWaitStarted,
  syncResponseReceived,
  syncProcessingDone,
  syncCleanupDone,
  queueEntered,
  queueExited,
  sharedFlightJoined,
  sharedFlightDone,
  downloadStarted,
  downloadDone,
  decryptStarted,
  decryptDone,
  decodeStarted,
  decodeDone,
  videoSelected,
  videoValidated,
  videoPrepareStarted,
  videoPrepareDone,
  videoTranscodeStarted,
  videoTranscodeDone,
  videoThumbnailDone,
  videoEncrypted,
  videoUploadStarted,
  videoUploadDone,
  videoEventSent,
  callStart,
  signalingReady,
  iceGathering,
  iceConnected,
  mediaFirstPacket,
  callConnected,
  localSearchStarted,
  localSearchDone,
  databaseSearchStarted,
  databaseSearchDone,
  remoteSearchStarted,
  remoteSearchDone,
  renderResults,
  requestFinished,
}

enum PerformanceResult {
  success,
  slow,
  waitingNetwork,
  rejected,
  failed,
  cancelled
}

enum PerformanceOpeningSource { localRoom, pendingConversation }

enum PerformanceLifecycle { foreground, background, resuming, unknown }

enum PerformanceAppNetworkState { online, weak, offline, recovering, unknown }

enum PerformanceMatrixState { connected, connecting, disconnected, unknown }

enum PerformanceNetworkError {
  dnsFailure,
  connectTimeout,
  readTimeout,
  socketFailure,
  tlsFailure,
  offline,
  server5xx,
  rateLimit,
  authFailure,
  businessRejection,
  cancelled,
  unknown,
}

enum PerformanceEndpointCategory {
  auth,
  profile,
  contacts,
  friendship,
  moments,
  finance,
  support,
  push,
  media,
  diagnostics,
  other,
}

enum PerformanceHttpMethod { get, post, put, patch, delete, head, other }

enum PerformanceCacheSource {
  memory,
  disk,
  network,
  miss,
  serverPoster,
  localFrame,
  unknown,
}

enum PerformanceMediaType { image, video, audio, file, avatar, unknown }

enum PerformanceMediaPriority { interactive, visible, prefetch, background }

enum PerformanceSizeBucket { zero, tiny, small, medium, large, huge, unknown }

enum PerformanceDatabaseOperation {
  timelineLocalLoad,
  conversationSnapshotLoad,
  outboxQuery,
  mediaIndexLookup,
  messageSearch,
}

enum PerformanceRowCountBucket {
  zero,
  oneToTwenty,
  twentyOneToHundred,
  hundredOneToFiveHundred,
  overFiveHundred,
}

enum PerformanceRelayProtocol { udp, tcp, tls, unknown }

/// A fixed, identity-free summary of one actual encoder pass. These fields are
/// local diagnostics only until the server's strict upload schema supports them.
enum PerformanceVideoTranscodeProfile { normal, aggressive }

enum PerformanceVideoTranscodeOutcome {
  success,
  nativeFailure,
  cancelled,
  unknownFailure,
  missingOutput,
  invalidOutput,
  overLimit,
}

final class PerformanceVideoTranscodeAttempt {
  const PerformanceVideoTranscodeAttempt({
    required this.profile,
    required this.outcome,
    required this.durationMs,
  });

  final PerformanceVideoTranscodeProfile profile;
  final PerformanceVideoTranscodeOutcome outcome;
  final int durationMs;
}

enum PerformanceBottleneck {
  clientUi,
  localDatabase,
  networkTransport,
  businessApi,
  matrixSync,
  matrixRoom,
  messageSend,
  mediaCache,
  mediaScheduler,
  mediaSharedFlight,
  mediaNetwork,
  mediaDecode,
  mediaTranscode,
  webRtc,
  turn,
  server,
  mixed,
  unknown,
}

extension PerformanceWireName on Enum {
  String get wireName => name.replaceAllMapped(
      RegExp(r'[A-Z]'), (match) => '_${match.group(0)!.toLowerCase()}');
}

final class PerformanceFrameCounts {
  const PerformanceFrameCounts({
    this.total = 0,
    this.slow = 0,
    this.slowBuild = 0,
    this.slowRaster = 0,
  });
  final int total;
  final int slow;
  final int slowBuild;
  final int slowRaster;

  PerformanceFrameCounts difference(PerformanceFrameCounts earlier) =>
      PerformanceFrameCounts(
        total: (total - earlier.total).clamp(0, 1000000),
        slow: (slow - earlier.slow).clamp(0, 1000000),
        slowBuild: (slowBuild - earlier.slowBuild).clamp(0, 1000000),
        slowRaster: (slowRaster - earlier.slowRaster).clamp(0, 1000000),
      );
}

/// An immutable, identity-free operation record. Stage values are elapsed
/// offsets from start; interval durations are derived only from observed marks.
final class PerformanceRecord {
  PerformanceRecord({
    required String operationId,
    required this.operation,
    required this.totalUs,
    required Map<PerformanceStage, int> stagesUs,
    required this.result,
    required this.lifecycle,
    required this.frames,
    this.frameAttributionComplete = true,
    this.openingSource,
    this.appNetworkState = PerformanceAppNetworkState.unknown,
    this.matrixState = PerformanceMatrixState.unknown,
    this.transportAvailable,
    this.serviceReachable,
    this.networkError,
    this.endpointCategory,
    this.httpMethod,
    this.statusCode,
    this.retryCount = 0,
    this.softKickCount = 0,
    this.hardRestartCount = 0,
    this.syncErrorCount,
    this.reconnectCount,
    this.lastHealthySyncAgeMs,
    this.cacheSource,
    this.mediaType,
    this.sizeBucket,
    this.databaseOperation,
    this.rowCountBucket,
    this.resultCountBucket,
    this.schedulerQueue,
    this.schedulerActive,
    this.schedulerVideoActive,
    this.mediaPriority,
    this.rttMs,
    this.jitterMs,
    this.packetsLost,
    this.packetsReceived,
    this.usesTurn,
    this.relayProtocol,
    this.candidateProtocol,
    List<PerformanceVideoTranscodeAttempt> videoTranscodeAttempts = const [],
  })  : operationId = _checkedOperationId(operationId),
        stagesUs = Map.unmodifiable(stagesUs),
        videoTranscodeAttempts =
            List.unmodifiable(videoTranscodeAttempts.take(2));

  static final RegExp _operationIdPattern = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

  static String _checkedOperationId(String value) {
    if (!_operationIdPattern.hasMatch(value)) {
      throw ArgumentError.value(
          value, 'operationId', 'expected random UUID v4');
    }
    return value;
  }

  final String operationId;
  final PerformanceOperationType operation;
  final int totalUs;
  final Map<PerformanceStage, int> stagesUs;
  final PerformanceResult result;
  final PerformanceLifecycle lifecycle;
  final PerformanceFrameCounts frames;

  /// False means frame timing has not covered the trace interval. Counts must
  /// not be interpreted as zero or used to classify a UI bottleneck.
  final bool frameAttributionComplete;
  final PerformanceOpeningSource? openingSource;
  final PerformanceAppNetworkState appNetworkState;
  final PerformanceMatrixState matrixState;
  final bool? transportAvailable;
  final bool? serviceReachable;
  final PerformanceNetworkError? networkError;
  final PerformanceEndpointCategory? endpointCategory;
  final PerformanceHttpMethod? httpMethod;
  final int? statusCode;
  final int retryCount;
  final int softKickCount;
  final int hardRestartCount;
  final int? syncErrorCount;
  final int? reconnectCount;
  final int? lastHealthySyncAgeMs;
  final PerformanceCacheSource? cacheSource;
  final PerformanceMediaType? mediaType;
  final PerformanceSizeBucket? sizeBucket;
  final PerformanceDatabaseOperation? databaseOperation;
  final PerformanceRowCountBucket? rowCountBucket;
  final PerformanceRowCountBucket? resultCountBucket;
  final int? schedulerQueue;
  final int? schedulerActive;
  final int? schedulerVideoActive;
  final PerformanceMediaPriority? mediaPriority;
  final double? rttMs;
  final double? jitterMs;
  final int? packetsLost;
  final int? packetsReceived;
  final bool? usesTurn;
  final PerformanceRelayProtocol? relayProtocol;
  final PerformanceRelayProtocol? candidateProtocol;
  final List<PerformanceVideoTranscodeAttempt> videoTranscodeAttempts;

  /// Replaces only frame attribution after a delayed Flutter timing report.
  /// The operation and all business measurements remain frozen at finish().
  PerformanceRecord withFrameAttribution(PerformanceFrameCounts newFrames,
          {required bool complete}) =>
      PerformanceRecord(
        operationId: operationId,
        operation: operation,
        totalUs: totalUs,
        stagesUs: stagesUs,
        result: result,
        lifecycle: lifecycle,
        frames: newFrames,
        frameAttributionComplete: complete,
        openingSource: openingSource,
        appNetworkState: appNetworkState,
        matrixState: matrixState,
        transportAvailable: transportAvailable,
        serviceReachable: serviceReachable,
        networkError: networkError,
        endpointCategory: endpointCategory,
        httpMethod: httpMethod,
        statusCode: statusCode,
        retryCount: retryCount,
        softKickCount: softKickCount,
        hardRestartCount: hardRestartCount,
        syncErrorCount: syncErrorCount,
        reconnectCount: reconnectCount,
        lastHealthySyncAgeMs: lastHealthySyncAgeMs,
        cacheSource: cacheSource,
        mediaType: mediaType,
        sizeBucket: sizeBucket,
        databaseOperation: databaseOperation,
        rowCountBucket: rowCountBucket,
        resultCountBucket: resultCountBucket,
        schedulerQueue: schedulerQueue,
        schedulerActive: schedulerActive,
        schedulerVideoActive: schedulerVideoActive,
        mediaPriority: mediaPriority,
        rttMs: rttMs,
        jitterMs: jitterMs,
        packetsLost: packetsLost,
        packetsReceived: packetsReceived,
        usesTurn: usesTurn,
        relayProtocol: relayProtocol,
        candidateProtocol: candidateProtocol,
        videoTranscodeAttempts: videoTranscodeAttempts,
      );

  int get totalMs => totalUs ~/ 1000;
  int get slowFrameCount => frames.slow;
  int get slowBuildCount => frames.slowBuild;
  int get slowRasterCount => frames.slowRaster;

  int? betweenMs(PerformanceStage start, PerformanceStage end) {
    final first = stagesUs[start];
    final last = stagesUs[end];
    if (first == null || last == null || last < first) return null;
    return (last - first) ~/ 1000;
  }

  /// The observed encoder-start-to-operation-end interval when encoding did
  /// not complete. It can include retry and cleanup; no native phase is guessed.
  int? get transcodeUntilFailureMs {
    if (operation != PerformanceOperationType.videoPrepare ||
        result != PerformanceResult.failed ||
        stagesUs.containsKey(PerformanceStage.videoTranscodeDone)) {
      return null;
    }
    final startedUs = stagesUs[PerformanceStage.videoTranscodeStarted];
    if (startedUs == null || startedUs > totalUs) return null;
    return (totalUs - startedUs) ~/ 1000;
  }

  /// A completed sync observed before the local timeline has no sync wait.
  /// An absent sync mark stays null: offline readiness is never inferred.
  int? get conversationSyncWaitMs {
    final local = stagesUs[PerformanceStage.localTimelineReady];
    final remote = stagesUs[PerformanceStage.remoteSyncReady];
    if (local == null || remote == null) return null;
    return ((remote - local).clamp(0, 3600000000)) ~/ 1000;
  }

  /// Local, closed-key view for one operation. The upload contract keeps the
  /// raw stage offsets, so the server can derive intervals without new PII.
  Map<String, int> get timingSummaryMs {
    final timings = <String, int>{};
    void add(String key, PerformanceStage start, PerformanceStage end) {
      final measured = betweenMs(start, end);
      if (measured != null) timings[key] = measured;
    }

    void addFromStart(String key, PerformanceStage stage) {
      final elapsed = stagesUs[stage];
      if (elapsed != null) timings[key] = elapsed ~/ 1000;
    }

    switch (operation) {
      case PerformanceOperationType.appResume:
        // onForeground starts the trace, so these offsets are measured from
        // that real lifecycle boundary without adding a synthetic mark.
        addFromStart(
            'resume_to_first_frame_ms', PerformanceStage.firstFrameRendered);
        addFromStart(
            'resume_to_matrix_connected_ms', PerformanceStage.matrixConnected);
        addFromStart(
            'resume_to_sync_finished_ms', PerformanceStage.syncFinished);
        addFromStart('resume_to_conversation_ready_ms',
            PerformanceStage.conversationReady);
      case PerformanceOperationType.conversationOpen:
        timings['conversation_open_total_ms'] = totalMs;
        add('identity_lookup_ms', PerformanceStage.userAction,
            PerformanceStage.identityLookupDone);
        add('local_room_lookup_ms', PerformanceStage.identityLookupDone,
            PerformanceStage.localRoomLookupDone);
        add('navigation_ms', PerformanceStage.routePushStarted,
            PerformanceStage.firstFrameRendered);
        add('first_frame_ms', PerformanceStage.userAction,
            PerformanceStage.firstFrameRendered);
        add('room_attach_ms', PerformanceStage.roomAttachStarted,
            PerformanceStage.roomAttachDone);
        add('timeline_local_ms', PerformanceStage.timelineLocalStarted,
            PerformanceStage.localTimelineReady);
        if (conversationSyncWaitMs case final wait?) {
          timings['sync_wait_ms'] = wait;
        }
        add('sync_response_wait_ms', PerformanceStage.syncResponseWaitStarted,
            PerformanceStage.syncResponseReceived);
        add('sync_processing_ms', PerformanceStage.syncResponseReceived,
            PerformanceStage.syncProcessingDone);
        add('sync_cleanup_ms', PerformanceStage.syncProcessingDone,
            PerformanceStage.syncCleanupDone);
      case PerformanceOperationType.messageSend:
        timings['message_send_total_ms'] = totalMs;
        add('composer_to_persist_ms', PerformanceStage.composerSubmit,
            PerformanceStage.outboxPersist);
        add('persist_to_send_ms', PerformanceStage.outboxPersist,
            PerformanceStage.matrixSendStart);
        add('matrix_send_ms', PerformanceStage.matrixSendStart,
            PerformanceStage.matrixSendFinish);
        add('send_to_visible_ms', PerformanceStage.matrixSendFinish,
            PerformanceStage.timelineVisible);
      case PerformanceOperationType.matrixSync:
        timings['sync_cycle_total_ms'] = totalMs;
        final response = stagesUs[PerformanceStage.syncResponseReceived];
        if (response != null) {
          timings['sync_response_wait_ms'] = response ~/ 1000;
        }
        add('sync_processing_ms', PerformanceStage.syncResponseReceived,
            PerformanceStage.syncProcessingDone);
        add('sync_cleanup_ms', PerformanceStage.syncProcessingDone,
            PerformanceStage.syncCleanupDone);
      case PerformanceOperationType.mediaLoad:
      case PerformanceOperationType.videoPoster:
        timings['media_total_ms'] = totalMs;
        add('queue_wait_ms', PerformanceStage.queueEntered,
            PerformanceStage.queueExited);
        add('shared_flight_wait_ms', PerformanceStage.sharedFlightJoined,
            PerformanceStage.sharedFlightDone);
        add('download_ms', PerformanceStage.downloadStarted,
            PerformanceStage.downloadDone);
        add('decrypt_ms', PerformanceStage.decryptStarted,
            PerformanceStage.decryptDone);
        add('decode_ms', PerformanceStage.decodeStarted,
            PerformanceStage.decodeDone);
      case PerformanceOperationType.videoPrepare:
        timings['media_total_ms'] = totalMs;
        add('prepare_ms', PerformanceStage.videoPrepareStarted,
            PerformanceStage.videoPrepareDone);
        add('transcode_ms', PerformanceStage.videoTranscodeStarted,
            PerformanceStage.videoTranscodeDone);
        add('upload_ms', PerformanceStage.videoUploadStarted,
            PerformanceStage.videoUploadDone);
        add('send_event_ms', PerformanceStage.videoUploadDone,
            PerformanceStage.videoEventSent);
      case PerformanceOperationType.callSetup:
        timings['call_setup_total_ms'] = totalMs;
        add('signaling_ms', PerformanceStage.callStart,
            PerformanceStage.signalingReady);
        add('ice_connect_ms', PerformanceStage.signalingReady,
            PerformanceStage.iceConnected);
        add('media_first_packet_ms', PerformanceStage.iceConnected,
            PerformanceStage.mediaFirstPacket);
      case PerformanceOperationType.apiRequest:
        timings['request_total_ms'] = totalMs;
      case PerformanceOperationType.walletLoad:
      case PerformanceOperationType.contactsLoad:
      case PerformanceOperationType.momentsLoad:
      case PerformanceOperationType.searchPageOpen:
      case PerformanceOperationType.recentPicturesLoad:
      case PerformanceOperationType.chatListLoad:
      case PerformanceOperationType.profileLoad:
        add('first_frame_ms', PerformanceStage.routeEnter,
            PerformanceStage.firstFrameRendered);
        add('content_ready_ms', PerformanceStage.routeEnter,
            PerformanceStage.contentReady);
        add('cache_load_ms', PerformanceStage.cacheLoadStarted,
            PerformanceStage.cacheLoadDone);
        add('remote_refresh_ms', PerformanceStage.remoteRefreshStarted,
            PerformanceStage.remoteRefreshDone);
        if (operation == PerformanceOperationType.walletLoad) {
          add('cache_to_first_frame_ms', PerformanceStage.cacheLoadDone,
              PerformanceStage.firstFrameRendered);
        }
      case PerformanceOperationType.search:
        add('local_search_ms', PerformanceStage.localSearchStarted,
            PerformanceStage.localSearchDone);
        add('database_search_ms', PerformanceStage.databaseSearchStarted,
            PerformanceStage.databaseSearchDone);
        add('remote_search_ms', PerformanceStage.remoteSearchStarted,
            PerformanceStage.remoteSearchDone);
        add('local_search_to_render_ms', PerformanceStage.localSearchStarted,
            PerformanceStage.renderResults);
      default:
        // Other operations still retain their measured stage offsets.
        break;
    }
    return Map.unmodifiable(timings);
  }

  Map<String, Object?> toLocalDiagnosticJson() => {
        ...toJson(),
        if (timingSummaryMs.isNotEmpty) 'timings_ms': timingSummaryMs,
        if (videoTranscodeAttempts.isNotEmpty)
          'video_transcode_attempts': [
            for (final attempt in videoTranscodeAttempts)
              {
                'profile': attempt.profile.wireName,
                'outcome': attempt.outcome.wireName,
                'duration_ms': attempt.durationMs,
              },
          ],
        if (transcodeUntilFailureMs case final elapsed?)
          'transcode_until_failure_ms': elapsed,
      };

  double? get packetLossPercent {
    final lost = packetsLost;
    final received = packetsReceived;
    if (lost == null || received == null || lost < 0 || received < 0) {
      return null;
    }
    final total = lost + received;
    return total > 0 ? 100 * lost / total : null;
  }

  Map<String, Object?> toJson() => {
        'operation_id': operationId,
        'operation': operation.wireName,
        'result': result.wireName,
        'total_ms': totalMs.clamp(0, 3600000),
        'stages': [
          for (final entry in stagesUs.entries)
            {
              'stage': entry.key.wireName,
              'elapsed_ms': (entry.value ~/ 1000).clamp(0, 3600000),
            },
        ],
        'lifecycle': lifecycle.wireName,
        'frame_attribution_complete': frameAttributionComplete,
        if (frameAttributionComplete) 'slow_frame_count': slowFrameCount,
        if (frameAttributionComplete) 'slow_build_count': slowBuildCount,
        if (frameAttributionComplete) 'slow_raster_count': slowRasterCount,
        if (openingSource != null) 'opening_source': openingSource!.wireName,
        if (appNetworkState != PerformanceAppNetworkState.unknown)
          'app_network_state': appNetworkState.wireName,
        if (matrixState != PerformanceMatrixState.unknown)
          'matrix_state': matrixState.wireName,
        if (transportAvailable != null)
          'transport_available': transportAvailable,
        if (serviceReachable != null) 'service_reachable': serviceReachable,
        if (networkError != null) 'network_error': networkError!.wireName,
        if (endpointCategory != null)
          'endpoint_category': endpointCategory!.wireName,
        if (httpMethod != null) 'method': httpMethod!.wireName,
        if (statusCode != null) 'status_code': statusCode,
        if (retryCount > 0) 'retry_count': retryCount.clamp(0, 20),
        if (softKickCount > 0) 'soft_kick_count': softKickCount.clamp(0, 1000),
        if (hardRestartCount > 0)
          'hard_restart_count': hardRestartCount.clamp(0, 1000),
        if (syncErrorCount != null)
          'sync_error_count': syncErrorCount!.clamp(0, 1000),
        if (reconnectCount != null)
          'reconnect_count': reconnectCount!.clamp(0, 1000),
        if (lastHealthySyncAgeMs != null)
          'last_healthy_sync_age_ms': lastHealthySyncAgeMs!.clamp(0, 3600000),
        if (cacheSource != null) 'cache_source': cacheSource!.wireName,
        if (mediaType != null) 'media_type': mediaType!.wireName,
        if (sizeBucket != null) 'size_bucket': sizeBucket!.wireName,
        if (databaseOperation != null)
          'database_operation': databaseOperation!.wireName,
        if (rowCountBucket != null)
          'row_count_bucket': rowCountBucket!.wireName,
        if (resultCountBucket != null)
          'result_count_bucket': resultCountBucket!.wireName,
        if (schedulerQueue != null)
          'scheduler_queue': schedulerQueue!.clamp(0, 1000),
        if (schedulerActive != null)
          'scheduler_active': schedulerActive!.clamp(0, 1000),
        if (schedulerVideoActive != null)
          'scheduler_video_active': schedulerVideoActive!.clamp(0, 1000),
        if (mediaPriority != null) 'media_priority': mediaPriority!.wireName,
        if (rttMs != null) 'rtt_ms': rttMs!.clamp(0, 60000),
        if (jitterMs != null) 'jitter_ms': jitterMs!.clamp(0, 60000),
        if (packetLossPercent != null)
          'packet_loss_percent': packetLossPercent!.clamp(0, 100),
        if (usesTurn != null) 'uses_turn': usesTurn,
        if (relayProtocol != null) 'relay_protocol': relayProtocol!.wireName,
        if (candidateProtocol != null)
          'candidate_protocol': candidateProtocol!.wireName,
      };
}

/// Pure classification. A long total alone is deliberately insufficient.
abstract final class PerformanceBottleneckClassifier {
  static PerformanceBottleneck classify(PerformanceRecord record) {
    final loss = record.packetLossPercent;
    if (record.operation == PerformanceOperationType.callActive &&
        ((record.rttMs != null &&
                record.rttMs! >= PerformanceThresholds.callRttMs) ||
            (record.jitterMs != null &&
                record.jitterMs! >= PerformanceThresholds.callJitterMs) ||
            (loss != null &&
                loss >= PerformanceThresholds.callPacketLossPercent))) {
      return record.usesTurn == true
          ? PerformanceBottleneck.turn
          : PerformanceBottleneck.webRtc;
    }
    final transportFailureObserved = switch (record.networkError) {
      PerformanceNetworkError.dnsFailure ||
      PerformanceNetworkError.connectTimeout ||
      PerformanceNetworkError.readTimeout ||
      PerformanceNetworkError.socketFailure ||
      PerformanceNetworkError.tlsFailure ||
      PerformanceNetworkError.offline =>
        true,
      _ => false,
    };
    if (record.operation == PerformanceOperationType.apiRequest &&
        record.statusCode == null &&
        transportFailureObserved) {
      return PerformanceBottleneck.networkTransport;
    }
    final slowFramesObserved = record.frameAttributionComplete &&
        record.frames.slow >= PerformanceThresholds.slowFrameCountWarning;
    final candidates = <(PerformanceBottleneck, int)>[];
    void add(PerformanceBottleneck kind, int? duration, int threshold) {
      if (duration != null && duration >= threshold) {
        candidates.add((kind, duration));
      }
    }

    add(
        PerformanceBottleneck.clientUi,
        record.betweenMs(PerformanceStage.routePushStarted,
            PerformanceStage.firstFrameRendered),
        PerformanceThresholds.conversationFirstFrameMs);
    add(
        PerformanceBottleneck.matrixRoom,
        record.betweenMs(PerformanceStage.roomAttachStarted,
            PerformanceStage.roomAttachDone),
        PerformanceThresholds.conversationLocalReadyMs);
    add(
        PerformanceBottleneck.matrixRoom,
        record.betweenMs(PerformanceStage.timelineLocalStarted,
            PerformanceStage.localTimelineReady),
        PerformanceThresholds.conversationLocalReadyMs);
    add(
        PerformanceBottleneck.localDatabase,
        record.betweenMs(PerformanceStage.databaseSearchStarted,
            PerformanceStage.databaseSearchDone),
        PerformanceThresholds.localDatabaseMs);
    final syncWait = record.betweenMs(
        PerformanceStage.localTimelineReady, PerformanceStage.remoteSyncReady);
    if (syncWait != null && syncWait >= PerformanceThresholds.syncWaitMs) {
      candidates.add((
        record.transportAvailable == false || transportFailureObserved
            ? PerformanceBottleneck.networkTransport
            : PerformanceBottleneck.matrixSync,
        syncWait
      ));
    }
    add(
        PerformanceBottleneck.matrixSync,
        record.betweenMs(PerformanceStage.syncResponseReceived,
            PerformanceStage.syncProcessingDone),
        PerformanceThresholds.syncProcessingMs);
    if (record.operation == PerformanceOperationType.matrixSync &&
        (record.transportAvailable == false ||
            transportFailureObserved ||
            record.serviceReachable == false)) {
      add(
          record.transportAvailable == false || transportFailureObserved
              ? PerformanceBottleneck.networkTransport
              : PerformanceBottleneck.matrixSync,
          record.stagesUs[PerformanceStage.syncResponseReceived] == null
              ? null
              : record.stagesUs[PerformanceStage.syncResponseReceived]! ~/ 1000,
          PerformanceThresholds.syncWaitMs);
    }
    add(
        PerformanceBottleneck.mediaCache,
        record.cacheSource == PerformanceCacheSource.disk ||
                record.cacheSource == PerformanceCacheSource.memory
            ? record.betweenMs(PerformanceStage.cacheLoadStarted,
                PerformanceStage.cacheLoadDone)
            : null,
        PerformanceThresholds.mediaFirstVisibleMs);
    add(
        PerformanceBottleneck.mediaScheduler,
        record.betweenMs(
            PerformanceStage.queueEntered, PerformanceStage.queueExited),
        PerformanceThresholds.mediaFirstVisibleMs);
    add(
        PerformanceBottleneck.mediaSharedFlight,
        record.betweenMs(PerformanceStage.sharedFlightJoined,
            PerformanceStage.sharedFlightDone),
        PerformanceThresholds.mediaFirstVisibleMs);
    add(
        PerformanceBottleneck.mediaNetwork,
        record.betweenMs(
            PerformanceStage.downloadStarted, PerformanceStage.downloadDone),
        PerformanceThresholds.mediaFirstVisibleMs);
    add(
        PerformanceBottleneck.mediaDecode,
        record.betweenMs(
            PerformanceStage.decodeStarted, PerformanceStage.decodeDone),
        PerformanceThresholds.mediaFirstVisibleMs);
    add(
        PerformanceBottleneck.mediaTranscode,
        record.betweenMs(PerformanceStage.videoTranscodeStarted,
                PerformanceStage.videoTranscodeDone) ??
            record.transcodeUntilFailureMs,
        PerformanceThresholds.mediaTranscodeMs);
    add(
        PerformanceBottleneck.messageSend,
        record.betweenMs(PerformanceStage.matrixSendStart,
            PerformanceStage.matrixSendFinish),
        PerformanceThresholds.messageSendMs);
    add(
        PerformanceBottleneck.webRtc,
        record.betweenMs(
            PerformanceStage.signalingReady, PerformanceStage.iceConnected),
        PerformanceThresholds.callSetupMs);
    add(
        PerformanceBottleneck.businessApi,
        record.operation == PerformanceOperationType.apiRequest &&
                record.statusCode != null
            ? record.totalMs
            : null,
        PerformanceThresholds.businessApiMs);
    if (candidates.isEmpty) {
      return slowFramesObserved
          ? PerformanceBottleneck.clientUi
          : PerformanceBottleneck.unknown;
    }
    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    if (candidates.length > 1 && candidates[1].$2 * 3 >= candidates[0].$2 * 2) {
      return PerformanceBottleneck.mixed;
    }
    return candidates.first.$1;
  }
}
