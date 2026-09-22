part of 'business_api_client.dart';

// HTTP status alone is not proof that a refresh credential is revoked.
bool _terminalRefreshError(BusinessApiException error) =>
    (error.statusCode == 401 || error.statusCode == 403) &&
    const {
      'SESSION_REPLACED',
      'REFRESH_TOKEN_INVALID',
      'REFRESH_TOKEN_REUSED',
      'REFRESH_TOKEN_EXPIRED',
      'SESSION_REVOKED',
      'ACCOUNT_NOT_ACTIVE',
      'AUTH_REQUIRED',
    }.contains(error.code);

const _refreshUnavailable = BusinessApiException(
    statusCode: 503,
    code: 'SESSION_REFRESH_PENDING',
    message: '登录连接暂时未恢复，请稍后重试');
const _storageUnavailable = BusinessApiException(
    statusCode: 503,
    code: 'SESSION_STORAGE_UNAVAILABLE',
    message: '设备暂时无法保存登录信息，请稍后重试');

extension _RecoverableBusinessRefresh on BusinessApiClient {
  void _refreshDiagnostic(ChatDiagnosticStage stage,
      {ChatDiagnosticError error = ChatDiagnosticError.unknown,
      int? status,
      int retryCount = 0,
      Duration elapsed = Duration.zero}) {
    ChatDiagnostics.instance.record(
        stage: stage,
        error: error,
        status: status,
        retryCount: retryCount,
        elapsed: elapsed,
        lifecycle: _sessionForeground
            ? ChatDiagnosticLifecycle.foreground
            : ChatDiagnosticLifecycle.background);
  }

  Future<StoredBusinessSession> _persistRefreshSession(
      int epoch,
      StoredBusinessSession expected,
      StoredBusinessSession target,
      ChatDiagnosticStage failureStage) async {
    // Caller owns _sessionWrites throughout compare, write and uncertain readback.
    if (epoch != _sessionEpoch) throw BusinessApiClient._ended;
    final before = await sessionStore.session();
    if (before != expected) throw BusinessApiClient._ended;
    try {
      await sessionStore.saveSession(
          accessToken: target.accessToken,
          refreshToken: target.refreshToken,
          matrixUserId: target.matrixUserId,
          deviceKey: target.deviceKey,
          pendingRefreshOperation: target.pendingRefreshOperation);
    } catch (_) {
      _refreshDiagnostic(failureStage);
      if (epoch != _sessionEpoch) throw BusinessApiClient._ended;
      final after = await sessionStore.session();
      if (after == target) return target;
      if (after != expected) throw BusinessApiClient._ended;
      throw _storageUnavailable;
    }
    if (epoch != _sessionEpoch) throw BusinessApiClient._ended;
    return target;
  }

  Future<(StoredBusinessSession, bool)> _prepareRefresh(int epoch) =>
      _writeCurrentSession(epoch, () async {
        final stored = await sessionStore.session();
        if (stored == null) throw BusinessApiClient._ended;
        if (stored.pendingRefreshOperation != null) return (stored, true);
        final pending = StoredBusinessSession(
            version: stored.version,
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            matrixUserId: stored.matrixUserId,
            deviceKey: stored.deviceKey,
            pendingRefreshOperation: SecureSessionStore.newRefreshOperation());
        final saved = await _persistRefreshSession(epoch, stored, pending,
            ChatDiagnosticStage.refreshPendingWriteFailed);
        return (saved, false);
      });

  Future<StoredBusinessSession> _runRecoverableRefresh() async {
    final epoch = _sessionEpoch;
    final next = _refreshRetryAt;
    if (next != null && DateTime.now().isBefore(next)) {
      throw _refreshUnavailable;
    }
    final watch = Stopwatch()..start();
    for (var attempt = 0; attempt < 2; attempt++) {
      var stage = ChatDiagnosticStage.refreshPendingWriteFailed;
      try {
        final (pending, recovering) = await _prepareRefresh(epoch);
        stage = ChatDiagnosticStage.refreshRequestUncertain;
        final response = await _client
            .post(_uri('/auth/refresh'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'refresh_token': pending.refreshToken,
                  'operation_id': pending.pendingRefreshOperation
                }))
            .timeout(BusinessApiClient._httpTimeout);
        if (epoch != _sessionEpoch) throw BusinessApiClient._ended;
        late final Map<String, dynamic> body;
        try {
          body = _decode(response);
        } on BusinessApiException catch (error) {
          if (error.code == 'REFRESH_RESULT_SUPERSEDED' &&
              error.statusCode == 409) {
            _refreshDiagnostic(ChatDiagnosticStage.refreshResultSuperseded,
                status: 409);
            return await _writeCurrentSession(epoch, () async {
              final latest = await sessionStore.session();
              if (latest != null &&
                  latest.refreshToken != pending.refreshToken &&
                  latest.matrixUserId == pending.matrixUserId &&
                  latest.deviceKey == pending.deviceKey &&
                  latest.pendingRefreshOperation == null) {
                return latest;
              }
              if (latest != pending) throw BusinessApiClient._ended;
              // Invalidate outside the write queue to avoid deadlock.
              throw const BusinessApiException(
                  statusCode: 401,
                  code: 'REFRESH_TOKEN_INVALID',
                  message: '登录凭证已更新，请重新登录');
            });
          }
          rethrow;
        }
        final access = body['access_token'];
        final refresh = body['refresh_token'];
        if (access is! String ||
            access.isEmpty ||
            refresh is! String ||
            refresh.isEmpty) {
          throw _refreshUnavailable;
        }
        stage = ChatDiagnosticStage.refreshResultWriteFailed;
        final replacement = StoredBusinessSession(
            version: 1,
            accessToken: access,
            refreshToken: refresh,
            matrixUserId: pending.matrixUserId,
            deviceKey: pending.deviceKey);
        final saved = await _writeCurrentSession(
            epoch,
            () => _persistRefreshSession(epoch, pending, replacement,
                ChatDiagnosticStage.refreshResultWriteFailed));
        if (epoch != _sessionEpoch) throw BusinessApiClient._ended;
        _refreshFailures = 0;
        _refreshRetryAt = null;
        if (attempt > 0 || recovering) {
          _refreshDiagnostic(ChatDiagnosticStage.refreshRetryRecovered,
              error: ChatDiagnosticError.recovered,
              retryCount: attempt,
              elapsed: watch.elapsed);
        }
        return saved;
      } catch (error) {
        if (epoch != _sessionEpoch ||
            (error is BusinessApiException &&
                error.code == 'AUTH_SESSION_ENDED')) {
          throw BusinessApiClient._ended;
        }
        if (error is BusinessApiException && _terminalRefreshError(error)) {
          _refreshDiagnostic(ChatDiagnosticStage.refreshTerminalInvalidated,
              error: ChatDiagnosticError.rejected, status: error.statusCode);
          await _invalidateSession(epoch, error.code);
          rethrow;
        }
        _refreshDiagnostic(stage,
            retryCount: attempt,
            elapsed: watch.elapsed,
            error: error is TimeoutException
                ? ChatDiagnosticError.timeout
                : error is BusinessApiException
                    ? ChatDiagnosticError.rejected
                    : ChatDiagnosticError.unknown,
            status: error is BusinessApiException ? error.statusCode : null);
        // Do not retry before storage is available, or downgrade a legacy422.
        final immediateRetry = attempt == 0 &&
            _sessionForeground &&
            stage == ChatDiagnosticStage.refreshRequestUncertain &&
            (error is! BusinessApiException || error.statusCode >= 500);
        if (immediateRetry) continue;
        _refreshFailures = (_refreshFailures + 1).clamp(1, 4);
        final seconds = [5, 15, 30, 60][_refreshFailures - 1];
        _refreshRetryAt = DateTime.now().add(Duration(seconds: seconds));
        if (error is BusinessApiException) rethrow;
        throw stage == ChatDiagnosticStage.refreshRequestUncertain
            ? _refreshUnavailable
            : _storageUnavailable;
      }
    }
    throw _refreshUnavailable;
  }
}
