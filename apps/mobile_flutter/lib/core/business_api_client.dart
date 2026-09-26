import 'package:crypto/crypto.dart' show sha256, Hmac;
import 'dart:convert';
import 'business_phone_contracts.dart' as phone_contracts;
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'session_store.dart';
import 'package:uuid/uuid.dart';
import 'business_api_error.dart';
import 'business_api_performance_client.dart';
import 'chat_diagnostics.dart';
import 'performance_trace.dart';
import 'business_auth_contracts.dart';
import '../features/profile/profile_controller.dart';
import '../features/profile/invite_controller.dart';
import '../features/profile/invite_snapshot_store.dart';
import '../features/contacts/contact_models.dart';
import '../features/profile/complaint_models.dart';
import '../features/redpacket/red_packet_controller.dart';
import '../features/moments/moments_privacy_changes.dart';
import 'permissions/blocked_contacts.dart';
import 'support_identity_repository.dart';

export 'business_api_error.dart';
part 'business_session_refresh.dart';

enum BusinessSessionRestore { absent, authenticated, offline, invalid }

abstract interface class BusinessSessionGateway {
  Future<BusinessSessionRestore> restoreSession();
  Future<String?> currentMatrixUserId();
  Future<BusinessSessionRevocation?> clearLocalSession();
}

/// Opaque authority to revoke the server-side session after local access has
/// already been removed. The credential used by the implementation is never
/// exposed to controllers or logs.
abstract interface class BusinessSessionRevocation {
  Future<void> revoke();
}

final class _BusinessSessionRevocation implements BusinessSessionRevocation {
  const _BusinessSessionRevocation(this._revoke);
  final Future<void> Function() _revoke;

  @override
  Future<void> revoke() => _revoke();
}

final class BusinessApiClient
    implements
        BusinessSessionGateway,
        BusinessSessionMonitor,
        BusinessSessionLifecycle,
        MatrixSessionCompletionGateway,
        RegistrationGateway,
        DualDomainBusinessGateway,
        ProfileGateway,
        ContactsGateway,
        AddFriendGateway,
        ComplaintGateway,
        RedPacketViewGateway,
        PersonalInvitationGateway,
        InviteHistoryGateway,
        InviteCacheScopeProvider,
        SupportIdentityGateway,
        phone_contracts.PhoneAuthGateway,
        phone_contracts.PhoneInvitationContinuationGateway,
        phone_contracts.RechargeGateway {
  BusinessApiClient({
    required this.baseUri,
    required this.sessionStore,
    http.Client? client,
    PerformanceTraceRecorder? performanceRecorder,
  }) : _client = BusinessApiPerformanceClient(client ?? http.Client(),
            recorder: performanceRecorder);
  final Uri baseUri;
  final SecureSessionStore sessionStore;
  final BusinessApiPerformanceClient _client;
  bool _diagnosticUploadActive = false;

  /// Account-scoped shared presentation cache; widgets only remove listeners.
  late final SupportIdentityRepository supportIdentities =
      SupportIdentityRepository(this, scope: () async {
    final session = await sessionStore.session();
    final account = session?.matrixUserId;
    if (account == null || account.isEmpty) return null;
    return sha256.convert(utf8.encode('$baseUri|$account')).toString();
  }, store: const PreferencesSupportIdentitySnapshotStore());

  /// Salted local-only namespace; never included in telemetry or HTTP headers.
  Future<String?> diagnosticSpoolScope() async {
    final epoch = _sessionEpoch;
    final session = await sessionStore.session();
    final account = session?.matrixUserId;
    if (account == null || account.isEmpty || epoch != _sessionEpoch) {
      return null;
    }
    final salt = await sessionStore.diagnosticSalt();
    if (epoch != _sessionEpoch) return null;
    return Hmac(sha256, utf8.encode(salt))
        .convert(utf8.encode('$baseUri|$account'))
        .toString();
  }

  /// Best-effort metadata transport, deliberately outside _authorized/_decode.
  /// 401/429 never refresh credentials, revoke a session or recurse into logs.
  /// A dedicated socket is force-closed on deadline/abort, including stalled
  /// response headers. No diagnostic body or credential is persisted here.
  Future<int> uploadChatDiagnostics(
      ChatDiagnosticBatch batch, Future<void> abort) async {
    if (_diagnosticUploadActive) return 0;
    _diagnosticUploadActive = true;
    final epoch = _sessionEpoch;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final cancelled = Completer<int>();
    var ended = false;
    void cancel() {
      if (ended) return;
      ended = true;
      client.close(force: true);
      if (!cancelled.isCompleted) cancelled.complete(0);
    }

    final timer = Timer(const Duration(seconds: 5), cancel);
    unawaited(abort.then((_) => cancel(),
        onError: (Object _, StackTrace __) => cancel()));
    Future<int> send() async {
      final session = await sessionStore.session();
      if (ended || epoch != _sessionEpoch || session == null) return 0;
      final bytes = utf8.encode(jsonEncode(batch.toJson()));
      if (bytes.length > 16384) return 0;
      final request =
          await client.postUrl(baseUri.resolve('/api/v1/client-diagnostics'));
      if (ended || epoch != _sessionEpoch) return 0;
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(
          HttpHeaders.authorizationHeader, 'Bearer ${session.accessToken}');
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      if (ended || epoch != _sessionEpoch) return 0;
      // Do not allocate/read an untrusted response body for a status-only API.
      return response.statusCode;
    }

    try {
      return await Future.any([send(), cancelled.future]);
    } catch (_) {
      return 0;
    } finally {
      ended = true;
      timer.cancel();
      client.close(force: true);
      _diagnosticUploadActive = false;
    }
  }

  final Uuid _uuid = const Uuid();
  final Map<String, String> _pendingIdempotencyKeys = {};
  final _invalidations =
      StreamController<BusinessSessionInvalidation>.broadcast(sync: true);
  @override
  Stream<BusinessSessionInvalidation> get sessionInvalidations =>
      _invalidations.stream;
  @override
  int get sessionEpoch => _sessionEpoch;
  Future<void> _sessionWrites = Future<void>.value();
  Future<T> _writeSession<T>(Future<T> Function() action) {
    final result = _sessionWrites.then((_) => action());
    _sessionWrites =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<T> _writeCurrentSession<T>(int epoch, Future<T> Function() action) =>
      _writeSession(() {
        if (epoch != _sessionEpoch) throw _ended;
        return action();
      });

  @override
  Future<void> checkSessionValidity() => sendPresenceHeartbeat();

  bool _sessionForeground = true;
  int _refreshFailures = 0;
  DateTime? _refreshRetryAt;

  @override
  void setSessionForeground(bool foreground) {
    if (foreground && !_sessionForeground) _refreshRetryAt = null;
    _sessionForeground = foreground;
  }

  @override
  Future<void> completeMatrixSession(
      {required String matrixAccessToken,
      required String matrixDeviceId}) async {
    final response = await _authorized((headers) => _client.post(
        _uri('/auth/matrix-session'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'matrix_access_token': matrixAccessToken,
          'matrix_device_id': matrixDeviceId
        })));
    final body = _decode(response);
    if (body['status'] != 'ACTIVE') {
      throw const BusinessApiException(
          statusCode: 503,
          code: 'MATRIX_SESSION_REVOKE_PENDING',
          message: '旧设备退出尚未完成，请重试');
    }
  }

  static const _ended = BusinessApiException(
      statusCode: 401, code: 'AUTH_SESSION_ENDED', message: '会话已结束');

  Future<void> _invalidateSession(int epoch, String code) async {
    if (epoch != _sessionEpoch) return;
    final invalidatedEpoch = ++_sessionEpoch;
    supportIdentities.clear();
    _refreshFlight = null;
    _refreshRetryAt = null;
    _refreshFailures = 0;
    await _writeSession(() async {
      if (invalidatedEpoch == _sessionEpoch) {
        await sessionStore.clearBusinessSession();
      }
    });
    if (invalidatedEpoch != _sessionEpoch) return;
    _invalidations
        .add(BusinessSessionInvalidation(epoch: invalidatedEpoch, code: code));
  }

  Future<void> _checkReplacement(http.Response response, int epoch) async {
    if (epoch != _sessionEpoch) throw _ended;
    if (response.statusCode != 401) return;
    try {
      _decode(response);
    } on BusinessApiException catch (error) {
      if (error.code == 'SESSION_REPLACED') {
        await _invalidateSession(epoch, error.code);
        rethrow;
      }
    } on FormatException {
      // A proxy may return non-JSON 401; ordinary refresh still decides validity.
    }
  }

  String newIdempotencyKey() => _uuid.v4();
  String _pendingIdempotencyKey(String operation) =>
      _pendingIdempotencyKeys.putIfAbsent(operation, newIdempotencyKey);
  Uri _uri(String path) {
    return baseUri.resolve(
      path.startsWith('/api/v1/') ? path : '/api/v1$path',
    );
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    required String deviceKey,
    required String deviceName,
  }) async {
    final loginEpoch = ++_sessionEpoch;
    supportIdentities.clear();
    _refreshFlight = null;
    _refreshRetryAt = null;
    _refreshFailures = 0;
    _matrixGrantFlight = null;
    _matrixGrantRetryAt = null;
    final response = await _client.post(
      _uri('/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'device_key': deviceKey,
        'device_name': deviceName,
      }),
    );
    final body = _decode(response);
    if (loginEpoch != _sessionEpoch) throw _ended;
    final returnedMatrixUserId = body['matrix_user_id']?.toString();
    await _writeCurrentSession(
        loginEpoch,
        () => sessionStore.saveSession(
              accessToken: body['access_token'] as String,
              refreshToken: body['refresh_token'] as String,
              deviceKey: deviceKey,
              matrixUserId:
                  returnedMatrixUserId == null || returnedMatrixUserId.isEmpty
                      ? null
                      : returnedMatrixUserId,
            ));
    return body;
  }

  @override
  Future<void> loginBusiness({
    required String username,
    required String password,
    required String deviceKey,
    required String deviceName,
  }) async {
    await login(
      username: username,
      password: password,
      deviceKey: deviceKey,
      deviceName: deviceName,
    );
  }

  Future<MatrixLoginGrant>? _matrixGrantFlight;
  DateTime? _matrixGrantRetryAt;

  @override
  Future<MatrixLoginGrant> issueMatrixLoginToken() {
    final existing = _matrixGrantFlight;
    if (existing != null) return existing;
    final retryAt = _matrixGrantRetryAt;
    if (retryAt != null && retryAt.isAfter(DateTime.now())) {
      final seconds = (retryAt.difference(DateTime.now()).inMilliseconds / 1000)
          .ceil()
          .clamp(1, 86400);
      return Future.error(BusinessApiException(
          statusCode: 429,
          code: 'MATRIX_LOGIN_RATE_LIMITED',
          message: '聊天登录请求较频繁，请等待 $seconds 秒后重试',
          retryAfterSeconds: seconds));
    }
    late final Future<MatrixLoginGrant> flight;
    flight = _requestMatrixLoginToken().whenComplete(() {
      if (identical(_matrixGrantFlight, flight)) _matrixGrantFlight = null;
    });
    _matrixGrantFlight = flight;
    return flight;
  }

  Future<MatrixLoginGrant> _requestMatrixLoginToken() async {
    try {
      final response = await _authorized((headers) =>
          _client.post(_uri('/auth/matrix-login-token'), headers: headers));
      final body = _decode(response);
      return MatrixLoginGrant(
          loginToken: body['login_token'] as String,
          homeserver: body['homeserver'] as String,
          expiresIn: body['expires_in'] as int,
          matrixUserId: body['matrix_user_id'] as String);
    } on BusinessApiException catch (error) {
      if (error.statusCode == 429) {
        _matrixGrantRetryAt = DateTime.now()
            .add(Duration(seconds: error.retryAfterSeconds ?? 60));
      }
      rethrow;
    }
  }

  @override
  Future<void> bindMatrixUserId(String matrixUserId) async {
    final epoch = _sessionEpoch;
    await _writeCurrentSession(epoch, () async {
      final stored = await sessionStore.session();
      if (stored == null || epoch != _sessionEpoch) throw _ended;
      await sessionStore.saveSession(
        accessToken: stored.accessToken,
        refreshToken: stored.refreshToken,
        matrixUserId: matrixUserId,
        deviceKey: stored.deviceKey,
        pendingRefreshOperation: stored.pendingRefreshOperation,
      );
    });
  }

  @override
  Future<void> logoutBusiness() => logout();
  @override
  Future<InvitationValidationResult> validateInvitation(
    String invitationCode,
  ) async {
    final response = await _client.post(
      _uri('/invitations/validate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'invitation_code': invitationCode}),
    );
    final body = _decode(response);
    return mapInvitationCheck(
      valid: body['valid'] == true,
      reason: body['reason']?.toString(),
    );
  }

  @override
  Future<PersonalInvitation> fetchPersonalInvitation() async {
    final body = await getJson('/invitations/mine');
    return PersonalInvitation(
      code: body['code'] as String,
      maxUses: (body['max_uses'] as num?)?.toInt() ?? 0,
      useCount: (body['use_count'] as num?)?.toInt() ?? 0,
      shareUrl: body['share_url'] as String,
    );
  }

  /// 邀请码本地快照的账号作用域；未登录或令牌不可解析时返回 null，
  /// 调用方据此保守处理（不落盘并丢弃无法校验的旧快照）。
  @override
  Future<String?> inviteCacheScope() async {
    try {
      return await walletIntentScope();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<InviteHistoryPage> fetchInviteHistory(
      {int limit = 20, int offset = 0}) async {
    final body =
        await getJson('/invitations/history?limit=$limit&offset=$offset');
    final next = (body['next_offset'] as num?)?.toInt();
    return InviteHistoryPage(
      items: (body['items'] as List? ?? const [])
          .map((value) => InviteHistoryItem.fromJson(
              (value as Map).cast<String, dynamic>()))
          .toList(growable: false),
      nextOffset: next,
    );
  }

  @override
  Future<RegistrationReceipt> register({
    required String username,
    String? nickname,
    required String email,
    required String password,
    required String invitationCode,
  }) async {
    final operation =
        'register:${username.trim().toLowerCase()}:${email.trim().toLowerCase()}:$invitationCode';
    final response = await _client.post(
      _uri('/auth/register'),
      headers: {
        'Content-Type': 'application/json',
        'X-Device-Key': await sessionStore.registrationDeviceKey(),
        'Idempotency-Key': _pendingIdempotencyKey(operation),
      },
      body: jsonEncode({
        'username': username,
        if (nickname != null) 'nickname': nickname,
        'email': email,
        'password': password,
        'invitation_code': invitationCode,
      }),
    );
    final body = _decode(response);
    _pendingIdempotencyKeys.remove(operation);
    return RegistrationReceipt(
      registrationSession: body['registration_session'] as String,
      status: body['status'] as String,
      resendAfterSeconds: body['resend_after_seconds'] as int,
    );
  }

  @override
  Future<void> verifyEmail({
    required String registrationSession,
    String? code,
    String? token,
  }) async {
    final operation =
        'verify:$registrationSession:${code != null ? 'code:$code' : 'token:$token'}';
    final response = await _client.post(
      _uri('/auth/email-verifications/verify'),
      headers: {
        'Content-Type': 'application/json',
        'Idempotency-Key': _pendingIdempotencyKey(operation),
      },
      body: jsonEncode({
        'registration_session': registrationSession,
        if (code != null) 'code': code,
        if (token != null) 'token': token,
      }),
    );
    _decode(response);
    _pendingIdempotencyKeys.remove(operation);
  }

  @override
  Future<int> changeRegistrationEmail({
    required String registrationSession,
    required String email,
  }) async {
    final operation = 'change-email:$registrationSession:$email';
    final response = await _client.post(
      _uri('/auth/registrations/$registrationSession/email'),
      headers: {
        'Content-Type': 'application/json',
        'X-Device-Key': await sessionStore.registrationDeviceKey(),
        'Idempotency-Key': _pendingIdempotencyKey(operation),
      },
      body: jsonEncode({'email': email}),
    );
    final body = _decode(response);
    _pendingIdempotencyKeys.remove(operation);
    return body['resend_after_seconds'] as int;
  }

  @override
  Future<int> resendVerification(String registrationSession) async {
    final operation = 'resend:$registrationSession';
    final response = await _client.post(
      _uri('/auth/email-verifications/resend'),
      headers: {
        'Content-Type': 'application/json',
        'X-Device-Key': await sessionStore.registrationDeviceKey(),
        'Idempotency-Key': _pendingIdempotencyKey(operation),
      },
      body: jsonEncode({'registration_session': registrationSession}),
    );
    final body = _decode(response);
    _pendingIdempotencyKeys.remove(operation);
    return body['resend_after_seconds'] as int;
  }

  @override
  Future<RegistrationStatusReceipt> registrationStatus(
    String registrationSession,
  ) async {
    final response = await _client.get(
      _uri('/auth/registrations/${Uri.encodeComponent(registrationSession)}'),
    );
    final body = _decode(response);
    return RegistrationStatusReceipt(
      status: body['status'] as String,
      resendAfterSeconds: body['resend_after_seconds'] as int,
    );
  }

  ProfileData _profile(Map<String, dynamic> body) => ProfileData(
        username: body['username'] as String,
        nickname: body['nickname'] as String,
        maskedEmail: body['masked_email'] as String,
        fallbackSeed: body['avatar_fallback_seed'] as String,
        signature: body['signature']?.toString(),
        nudgeSuffix: body['nudge_suffix']?.toString(),
        avatarUrl: body['avatar_url']?.toString(),
      );
  @override
  Future<ProfileData> loadProfile() async =>
      _profile(await getJson('/profile/me'));
  @override
  Future<ProfileData> updateProfile({
    String? nickname,
    String? signature,
    String? nudgeSuffix,
  }) async =>
      _profile(
        await patchJson(
            '/profile/me',
            {
              if (nickname != null) 'nickname': nickname,
              if (signature != null) 'signature': signature,
              if (nudgeSuffix != null) 'nudge_suffix': nudgeSuffix,
            },
            idempotencyKey: newIdempotencyKey()),
      );
  @override
  Future<AvatarUploadSession> createAvatarUpload({
    required String mimeType,
    required int byteSize,
  }) async {
    final body = await postJson(
        '/profile/avatar/uploads',
        {
          'mime_type': mimeType,
          'byte_size': byteSize,
        },
        idempotencyKey: newIdempotencyKey());
    return AvatarUploadSession(
      uploadId: body['upload_id'] as String,
      uploadUrl: body['upload_url'] as String,
    );
  }

  @override
  Future<void> putAvatar(
    AvatarUploadSession session,
    AvatarCandidate candidate,
  ) async {
    final response = await _authorized(
      (headers) => _client.put(
        baseUri.resolve(session.uploadUrl),
        headers: {...headers, 'Content-Type': candidate.mimeType},
        body: candidate.bytes,
      ),
    );
    if (response.statusCode >= 400) _decode(response);
  }

  @override
  Future<ProfileData> completeAvatar(String uploadId) async => _profile(
        await postJson(
          '/profile/avatar/uploads/$uploadId/complete',
          {},
          idempotencyKey: newIdempotencyKey(),
        ),
      );
  @override
  Future<void> cancelAvatar(String uploadId) async {
    final response = await _authorized(
      (headers) => _client.delete(
        _uri('/profile/avatar/uploads/$uploadId'),
        headers: headers,
      ),
    );
    if (response.statusCode >= 400) _decode(response);
  }

  @override
  Future<void> deleteAvatar() async {
    final response = await _authorized(
      (headers) => _client.delete(
        _uri('/profile/avatar'),
        headers: {...headers, 'Idempotency-Key': newIdempotencyKey()},
      ),
    );
    if (response.statusCode >= 400) _decode(response);
  }

  @override
  Future<BusinessSessionRestore> restoreSession() async {
    final epoch = _sessionEpoch;
    try {
      final stored = await sessionStore.session();
      if (stored == null) return BusinessSessionRestore.absent;
      await refreshSession();
      return BusinessSessionRestore.authenticated;
    } on BusinessApiException catch (error) {
      if (_terminalRefreshError(error)) {
        if (epoch == _sessionEpoch) await _invalidateSession(epoch, error.code);
        return BusinessSessionRestore.invalid;
      }
      if (epoch != _sessionEpoch) return BusinessSessionRestore.invalid;
      return BusinessSessionRestore.offline;
    } catch (_) {
      return BusinessSessionRestore.offline;
    }
  }

  /// 进行中的令牌刷新。服务端刷新令牌单次使用，且对已消费令牌的重放
  /// 会按 TOKEN_REUSE 撤销整个设备令牌族；并发 401 必须共享同一次刷新
  /// 调用（single-flight），否则首页聚合加载会互相触发撤族踢用户回登录页。
  Future<StoredBusinessSession>? _refreshFlight;

  Future<StoredBusinessSession> refreshSession() {
    final existing = _refreshFlight;
    if (existing != null) return existing;
    final flight = _refreshSession();
    _refreshFlight = flight;
    return flight.whenComplete(() {
      if (identical(_refreshFlight, flight)) _refreshFlight = null;
    });
  }

  Future<StoredBusinessSession> _refreshSession() => _runRecoverableRefresh();

  /// Records a lightweight authenticated activity heartbeat. It carries no
  /// Matrix identifiers, message data, or tokens beyond the Authorization
  /// header and lets the admin presence view reflect foreground usage.
  Future<void> sendPresenceHeartbeat({String? clientVersion}) async {
    final session = await sessionStore.session();
    if (session == null) {
      throw const BusinessApiException(
        statusCode: 401,
        code: 'AUTH_REQUIRED',
        message: '需要登录',
      );
    }
    final response = await _authorized(
      (headers) => _client.post(
        _uri('/presence/heartbeat'),
        headers: {
          ...headers,
          if (session.deviceKey != null) 'X-Device-Key': session.deviceKey!,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          if (clientVersion != null) 'client_version': clientVersion,
        }),
      ),
    );
    if (response.statusCode >= 400) _decode(response);
  }

  Future<void> logout() async {
    final revocation = await clearLocalSession();
    if (revocation == null) return;
    try {
      await revocation.revoke().timeout(const Duration(seconds: 5));
    } catch (_) {
      // Local authorization is already removed. Server revocation is
      // deliberately bounded and retried by normal token expiry policy.
    }
  }

  @override
  Future<BusinessSessionRevocation?> clearLocalSession() async {
    final epoch = ++_sessionEpoch;
    supportIdentities.clear();
    _refreshFlight = null;
    _refreshRetryAt = null;
    _refreshFailures = 0;
    final stored = await _writeSession(() async {
      if (epoch != _sessionEpoch) return null;
      final previous = await sessionStore.session();
      if (epoch != _sessionEpoch) return null;
      await sessionStore.clearBusinessSession();
      return previous;
    });
    if (stored == null) return null;
    return _BusinessSessionRevocation(() async {
      await _client.post(
        _uri('/auth/logout'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': stored.refreshToken}),
      );
    });
  }

  Future<String?> currentUserId() async {
    final token = (await sessionStore.session())?.accessToken;
    if (token == null) return null;
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    return payload is Map<String, dynamic> ? payload['sub']?.toString() : null;
  }

  @override
  Future<String?> currentMatrixUserId() async =>
      (await sessionStore.session())?.matrixUserId;
  Future<Map<String, dynamic>> caibiBalance() => getJson('/ledger/balances/me');
  Future<Map<String, dynamic>> ledgerTransactions({
    String? kind,
    DateTime? startAt,
    DateTime? endAt,
    String? q,
    String? cursor,
    int limit = 50,
  }) {
    final parameters = <String, String>{'limit': '$limit'};
    if (kind != null) parameters['kind'] = kind;
    if (startAt != null) {
      parameters['start_at'] = startAt.toUtc().toIso8601String();
    }
    if (endAt != null) {
      parameters['end_at'] = endAt.toUtc().toIso8601String();
    }
    if (q != null && q.isNotEmpty) parameters['q'] = q;
    if (cursor != null) parameters['cursor'] = cursor;
    return getJson(
        '/ledger/transactions/me?${Uri(queryParameters: parameters).query}');
  }

  Future<Map<String, dynamic>> ledgerTransactionDetail(String id) =>
      getJson('/ledger/transactions/me/${Uri.encodeComponent(id)}');
  Future<Map<String, dynamic>> transferCaibi(
    String receiverId,
    String amount,
  ) =>
      postJson(
          '/ledger/transfers',
          {
            'receiver_id': receiverId,
            'amount': amount,
          },
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> paymentPinStatus(
          {String? expectedWalletScope, String? expectedPaymentScope}) =>
      getJson('/payment-pin/status',
          expectedWalletScope: expectedWalletScope,
          expectedPaymentScope: expectedPaymentScope);

  Future<Map<String, dynamic>> setupPaymentPin({
    required String pin,
    required String loginPassword,
    required String idempotencyKey,
    required String expectedWalletScope,
    String? expectedPaymentScope,
  }) =>
      postJson(
          '/payment-pin/setup', {'pin': pin, 'login_password': loginPassword},
          idempotencyKey: idempotencyKey,
          expectedWalletScope: expectedWalletScope,
          expectedPaymentScope: expectedPaymentScope);

  Future<Map<String, dynamic>> authorizePaymentPin({
    required String pin,
    required String action,
    required Map<String, dynamic> payload,
    required String idempotencyKey,
    required String expectedWalletScope,
    String? expectedPaymentScope,
  }) =>
      postJson(
          '/payment-pin/authorize',
          {
            'pin': pin,
            'action': action,
            'payload': payload,
            'idempotency_key': idempotencyKey,
          },
          idempotencyKey: newIdempotencyKey(),
          expectedWalletScope: expectedWalletScope,
          expectedPaymentScope: expectedPaymentScope);

  Future<Map<String, dynamic>> createRedPacket({
    required String mode,
    required String total,
    required int shareCount,
    String? roomId,
    String? recipientId,
    String? idempotencyKey,
    String? paymentAuthorization,
    String? expectedWalletScope,
  }) =>
      postJson(
          '/red-packets',
          {
            'mode': mode,
            'total': total,
            'share_count': shareCount,
            if (roomId != null) 'room_id': roomId,
            if (recipientId != null) 'recipient_id': recipientId,
            if (paymentAuthorization != null)
              'payment_authorization': paymentAuthorization,
          },
          idempotencyKey: idempotencyKey ?? newIdempotencyKey(),
          expectedWalletScope: expectedWalletScope);
  @override
  Future<Map<String, dynamic>> claimRedPacket(String id) => postJson(
        '/red-packets/$id/claims',
        {},
        idempotencyKey: newIdempotencyKey(),
      );
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) =>
      getJson('/red-packets/$id');
  Future<Map<String, dynamic>> listRedPackets({String? roomId}) => getJson(
        '/red-packets${roomId == null ? '' : '?room_id=${Uri.encodeQueryComponent(roomId)}'}',
      );
  Future<Map<String, dynamic>> redPacketLimits() =>
      getJson('/red-packets/limits');
  Future<Map<String, dynamic>> latestAppUpdate() async {
    final platform = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? 'ios'
        : 'android';
    final response = await getJson('/app-updates/latest?platform=$platform');
    // Both update entry points share this boundary. A missing or mismatched
    // platform can never offer a download intended for another operating system.
    if (response['platform'] != platform) {
      return {'configured': false};
    }
    return response;
  }

  Future<Map<String, dynamic>> createChatTransfer({
    required String receiverId,
    required String amount,
    String? note,
    String? roomId,
    String? idempotencyKey,
    String? paymentAuthorization,
    String? expectedWalletScope,
  }) =>
      postJson(
          '/chat-transfers',
          {
            'receiver_id': receiverId,
            'amount': amount,
            if (note != null && note.isNotEmpty) 'note': note,
            if (roomId != null) 'room_id': roomId,
            if (paymentAuthorization != null)
              'payment_authorization': paymentAuthorization,
          },
          idempotencyKey: idempotencyKey ?? newIdempotencyKey(),
          expectedWalletScope: expectedWalletScope);
  Future<Map<String, dynamic>> acceptChatTransfer(String id) => postJson(
        '/chat-transfers/$id/accept',
        {},
        idempotencyKey: newIdempotencyKey(),
      );
  Future<Map<String, dynamic>> declineChatTransfer(String id) => postJson(
        '/chat-transfers/$id/decline',
        {},
        idempotencyKey: newIdempotencyKey(),
      );
  Future<Map<String, dynamic>> chatTransferDetail(String id) =>
      getJson('/chat-transfers/$id');
  Future<Map<String, dynamic>> walletBalance() =>
      getJson('/wallet/balances/me');
  Future<Map<String, dynamic>> walletDepositAddress() =>
      getJson('/wallet/official-deposit-address');

  /// U03：服务端有效网络/确认阈值/最小金额（客户端展示的统一来源）。
  Future<Map<String, dynamic>> walletConfig() => getJson('/wallet/config');
  Future<Map<String, dynamic>> walletHistory({String? kind}) =>
      getJson('/wallet/transactions${kind == null ? '' : '?kind=$kind'}');
  Future<Map<String, dynamic>> withdrawalStatus(String id) =>
      getJson('/wallet/withdrawals/$id');
  Future<Map<String, dynamic>> convertWallet({
    required String direction,
    required String amount,
    required String idempotencyKey,
    String? expectedWalletScope,
  }) =>
      postJson(
          '/wallet/conversions',
          {
            'direction': direction,
            'amount': amount,
          },
          idempotencyKey: idempotencyKey,
          expectedWalletScope: expectedWalletScope);
  Future<Map<String, dynamic>> walletConversionStatus(String id) =>
      getJson('/wallet/conversions/$id');

  /// Local storage namespace only. Authentication remains server-authoritative.
  Future<String> walletIntentScope() async {
    final session = await sessionStore.session();
    return _walletSessionScope(session);
  }

  Future<String> paymentIntentScope() async =>
      _paymentSessionScope(await sessionStore.session());

  String _paymentSessionScope(StoredBusinessSession? session) {
    final account = _walletSessionScope(session);
    final claims = jsonDecode(utf8.decode(base64Url.decode(
        base64Url.normalize(session!.accessToken.split('.')[1])))) as Map;
    return '$account:${claims['family_id'] ?? ''}:${claims['device_id'] ?? ''}';
  }

  String _walletSessionScope(StoredBusinessSession? session) {
    if (session == null) throw StateError('需要登录');
    final parts = session.accessToken.split('.');
    if (parts.length != 3) throw StateError('无法识别当前账户');
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final subject = claims is Map ? claims['sub'] : null;
    if (subject is! String || subject.isEmpty) throw StateError('无法识别当前账户');
    return '${baseUri.origin}:$subject';
  }

  Future<bool> autoAllowGroupJoin() async =>
      (await getJson('/profile/privacy'))['auto_allow_group_join'] == true;
  Future<bool> setAutoAllowGroupJoin(bool enabled) async =>
      _setAutoAllowGroupJoin(enabled);
  Future<bool> _setAutoAllowGroupJoin(bool enabled) async {
    final response = await _authorized(
      (headers) => _client.put(
        _uri('/profile/privacy/auto-allow-group-join'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'enabled': enabled}),
      ),
    );
    return _decode(response)['auto_allow_group_join'] == true;
  }

  /// BUG2 群二维码：签发入群令牌（群主/管理员；返回 `changliao://g/<token>`）。
  Future<Map<String, dynamic>> issueGroupJoinToken({required String roomId}) =>
      postJson(
        '/groups/$roomId/join-tokens',
        const {},
        idempotencyKey: newIdempotencyKey(),
      );

  /// 扫码后的安全群摘要（不返回 room_id/令牌明文）。
  Future<Map<String, dynamic>> groupJoinInfo({required String token}) =>
      getJson('/groups/join-info?token=${Uri.encodeQueryComponent(token)}');

  /// 兑换令牌入群（直加或转审批，服务端校验）。
  Future<Map<String, dynamic>> redeemGroupJoinToken({required String token}) =>
      postJson(
          '/groups/join-tokens/redeem',
          {
            'token': token,
          },
          idempotencyKey: newIdempotencyKey());

  /// 撤销令牌（轮换 = 新签发 + 撤销旧）。
  Future<Map<String, dynamic>> revokeGroupJoinToken({required String token}) =>
      postJson(
        '/groups/join-tokens/${Uri.encodeQueryComponent(token)}/revoke',
        const {},
        idempotencyKey: newIdempotencyKey(),
      );

  Future<Map<String, dynamic>> requestServerGroupAutoJoin({
    required String roomId,
    required List<String> inviteeUserIds,
  }) =>
      postJson(
          '/groups/auto-join',
          {
            'room_id': roomId,
            'invitee_user_ids': inviteeUserIds,
          },
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> friends() => getJson('/friends');
  @override
  Future<List<ContactSummary>> listContacts() async {
    final body = await friends();
    return (body['items'] as List)
        .map((item) => ContactSummary.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<ContactSummary?> fetchFriendDetail(String userId) async {
    try {
      final body = await getJson('/friends/$userId');
      return ContactSummary.fromJson(body);
    } on BusinessApiException catch (error) {
      if (error.statusCode == 404) return null; // 非好友：状态行隐藏。
      rethrow;
    }
  }

  Future<Map<String, dynamic>> friendRequests() => getJson('/friends/requests');
  @override
  Future<Map<String, dynamic>> submitComplaint({
    required String category,
    required String description,
  }) =>
      postJson(
          '/support/complaints',
          {
            'category': category,
            'description': description,
          },
          idempotencyKey: newIdempotencyKey());
  @override
  Future<Map<String, dynamic>> contactTags() => getJson('/contact-tags');
  @override
  Future<Map<String, dynamic>> createContactTag(String name) => postJson(
        '/contact-tags',
        {'name': name},
        idempotencyKey: newIdempotencyKey(),
      );
  @override
  Future<Map<String, dynamic>> renameContactTag(String id, String name) =>
      patchJson(
          '/contact-tags/$id',
          {
            'name': name,
          },
          idempotencyKey: newIdempotencyKey());
  @override
  Future<void> deleteContactTag(String id) async {
    final response = await _authorized(
      (headers) => _client.delete(
        _uri('/contact-tags/$id'),
        headers: {...headers, 'Idempotency-Key': newIdempotencyKey()},
      ),
    );
    if (response.statusCode >= 400) _decode(response);
  }

  @override
  Future<void> deleteContactTags(List<String> ids) async {
    final response = await _authorized(
      (headers) => _client.delete(
        _uri('/contact-tags'),
        headers: {
          ...headers,
          'Idempotency-Key': newIdempotencyKey(),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'tag_ids': ids}),
      ),
    );
    if (response.statusCode >= 400) _decode(response);
  }

  Future<Map<String, dynamic>> blocks() => getJson('/blocks');
  Future<Map<String, dynamic>> updateContact(
    String id, {
    String? remark,
    List<String> tags = const [],
    String momentsPermission = 'DEFAULT',
  }) =>
      patchJson(
          '/friends/$id',
          {
            'remark': remark,
            'tags': tags,
            'moments_permission': momentsPermission,
          },
          idempotencyKey: newIdempotencyKey());
  @override
  Future<ContactDetails> updateContactDetails(
    ContactDetails contact, {
    required String? remark,
    required List<String> tags,
    required String momentsPermission,
  }) async {
    final body = await updateContact(
      contact.userId,
      remark: remark,
      tags: tags,
      momentsPermission: momentsPermission,
    );
    return contact.copyWith(
      remark: body['remark']?.toString(),
      clearRemark: body['remark'] == null,
      tags: (body['tags'] as List? ?? const [])
          .map((tag) => tag.toString())
          .toList(growable: false),
      momentsPermission:
          body['moments_permission']?.toString() ?? momentsPermission,
    );
  }

  Future<Map<String, dynamic>> blockUser(String id) async {
    final result = await postJson('/blocks', {'user_id': id},
        idempotencyKey: newIdempotencyKey());
    // BUG-10：拉黑后立即生效（聊天的发送门与本投影读同一份状态），
    // 并在服务端持久化后刷新好友朋友圈权限投影。
    blockedContacts.markBlocked(id);
    momentsPrivacyChanges.changed();
    return result;
  }

  @override
  Future<Map<String, dynamic>> blockList() => blocks();

  @override
  Future<void> unblockContact(String userId) async {
    final response = await _authorized(
      (headers) => _client.delete(
        _uri('/blocks/$userId'),
        headers: {...headers, 'Idempotency-Key': newIdempotencyKey()},
      ),
    );
    if (response.statusCode >= 400) _decode(response);
    blockedContacts.markUnblocked(userId);
    momentsPrivacyChanges.changed();
  }

  @override
  Future<void> blockContact(String userId) async {
    await blockUser(userId);
  }

  @override
  Future<void> deleteContact(String userId) async {
    final response = await _authorized(
      (headers) => _client.delete(
        _uri('/friends/$userId'),
        headers: {...headers, 'Idempotency-Key': newIdempotencyKey()},
      ),
    );
    if (response.statusCode >= 400) _decode(response);
  }

  @override
  Future<Map<String, dynamic>> searchUsers(String query) =>
      getJson('/users/search?q=${Uri.encodeQueryComponent(query)}');

  /// BUG 2 群成员非好友：按 Matrix ID 反查公开资料与关系状态。
  /// 不存在/拉黑/自己时服务端返回 404（抛 BusinessApiException）。
  Future<Map<String, dynamic>> lookupUserByMatrixId(
    String matrixUserId,
  ) =>
      getJson(
        '/users/lookup?matrix_user_id=${Uri.encodeQueryComponent(matrixUserId)}',
      );

  @override
  Future<List<SupportIdentity>> lookupSupportIdentities(
      List<String> userIds) async {
    if (userIds.isEmpty || userIds.length > 100) {
      throw ArgumentError.value(userIds, 'userIds', 'must contain 1..100 ids');
    }
    final response = await _authorized(
      (headers) => _client.post(
        _uri('/support/identities/lookup'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'user_ids': userIds}),
      ),
    );
    final body = _decode(response);
    return (body['items'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => SupportIdentity.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value))))
        .toList(growable: false);
  }

  @override
  Future<Map<String, dynamic>> requestFriend(
    String userId, {
    String message = '',
    String? remark,
    List<String> tags = const [],
    String momentsPermission = 'DEFAULT',
  }) =>
      postJson(
          '/friends/requests',
          {
            'target_user_id': userId,
            'message': message,
            if (remark != null && remark.isNotEmpty) 'remark': remark,
            if (tags.isNotEmpty) 'tags': tags,
            'moments_permission': momentsPermission,
          },
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> acceptFriendRequest(String id) => postJson(
        '/friends/requests/$id/accept',
        {},
        idempotencyKey: newIdempotencyKey(),
      );
  Future<Map<String, dynamic>> rejectFriendRequest(String id) => postJson(
        '/friends/requests/$id/reject',
        {},
        idempotencyKey: newIdempotencyKey(),
      );

  /// Canonical Direct Conversation（好友系统重构 Phase E）：
  /// 创建私聊前先查询规范房间，存在即复用。
  Future<String?> canonicalDirectRoomId(String peerUserId) async {
    final epoch = sessionEpoch;
    final body = await getJson(
      '/direct-conversations?peer_user_id=$peerUserId',
    );
    if (!body.containsKey('matrix_room_id')) {
      throw StateError('规范私聊查询响应不完整');
    }
    final roomId = body['matrix_room_id'];
    if (roomId != null && (roomId is! String || roomId.isEmpty)) {
      throw StateError('规范私聊查询响应无效');
    }
    acceptDirectConversationSnapshot(peerUserId, body, epoch: epoch);
    return roomId as String?;
  }

  final Map<String, (int, String?)> _directRevisions = {};
  int? _directRevisionEpoch;

  /// One monotonic view shared by sending, directory sync, and recovery.
  void acceptDirectConversationSnapshot(String peer, Map<String, dynamic> body,
      {required int epoch}) {
    if (epoch != sessionEpoch) {
      throw StateError('Direct conversation account changed');
    }
    if (_directRevisionEpoch != epoch) {
      _directRevisions.clear();
      _directRevisionEpoch = epoch;
    }
    final revision = body['revision'];
    final room = body['matrix_room_id'];
    if (revision != null && (revision is! int || revision < 0)) {
      throw StateError('Invalid direct conversation revision');
    }
    if (room != null && (room is! String || room.isEmpty)) {
      throw StateError('Invalid direct conversation room');
    }
    final previous = _directRevisions[peer];
    if (previous != null &&
        (revision == null ||
            revision < previous.$1 ||
            (revision == previous.$1 &&
                room != null &&
                previous.$2 != null &&
                room != previous.$2))) {
      throw StateError('Stale direct conversation response');
    }
    if (revision is int) {
      _directRevisions[peer] = (revision, room as String? ?? previous?.$2);
    }
  }

  Future<Map<String, dynamic>> claimDirectConversation(
    String peerUserId,
    String attemptId,
  ) =>
      postJson(
          '/direct-conversations/claim',
          {
            'peer_user_id': peerUserId,
            'attempt_id': attemptId,
          },
          idempotencyKey: attemptId);

  Future<Map<String, dynamic>> claimRecoverableDirectConversation(
          String peer, String attempt) =>
      postJson('/direct-conversations/claim-v2',
          {'peer_user_id': peer, 'attempt_id': attempt},
          idempotencyKey: attempt);

  Future<String> recoverDirectConversation(
      String peer, String attempt, String roomId) async {
    final result = await postJson('/direct-conversations/recover',
        {'peer_user_id': peer, 'attempt_id': attempt, 'matrix_room_id': roomId},
        idempotencyKey: attempt);
    final id = result['matrix_room_id'];
    if (id is! String || id.isEmpty) throw StateError('规范私聊登记响应不完整');
    return id;
  }

  Future<Map<String, dynamic>> directConversationAssociations(
      String peer) async {
    final epoch = sessionEpoch;
    final body = await getJson(
        '/direct-conversations/associations?${Uri(queryParameters: {
          'peer_user_id': peer
        }).query}');
    acceptDirectConversationSnapshot(peer, body, epoch: epoch);
    return body;
  }

  Future<void> registerDirectConversationHistory(
      String peer, String roomId) async {
    await postJson('/direct-conversations/associations',
        {'peer_user_id': peer, 'matrix_room_id': roomId},
        idempotencyKey: newIdempotencyKey());
  }

  Future<String> publishDirectConversation(
    String peerUserId,
    String attemptId,
    String roomId,
  ) async {
    final body = await postJson(
        '/direct-conversations/publish',
        {
          'peer_user_id': peerUserId,
          'attempt_id': attemptId,
          'matrix_room_id': roomId,
        },
        idempotencyKey: attemptId);
    final published = body['matrix_room_id'];
    if (published is! String || published.isEmpty) {
      throw StateError('规范私聊登记响应不完整');
    }
    return published;
  }

  /// 客户端创建 Matrix Direct Chat 后注册；并发冲突时服务端返回既有行。
  Future<String> registerDirectConversation(
    String peerUserId,
    String matrixRoomId,
  ) async {
    final body = await postJson(
        '/direct-conversations',
        {
          'peer_user_id': peerUserId,
          'matrix_room_id': matrixRoomId,
        },
        idempotencyKey: newIdempotencyKey());
    final canonical = body['matrix_room_id'];
    if (canonical is! String || canonical.isEmpty) {
      throw StateError('规范私聊登记响应不完整');
    }
    return canonical;
  }

  /// BUG 2 状态机：申请人撤销待处理申请（PENDING → CANCELLED）。
  Future<Map<String, dynamic>> cancelFriendRequest(String id) async {
    final response = await _authorized(
      (headers) => _client.delete(
        _uri('/friends/requests/$id'),
        headers: {...headers, 'Idempotency-Key': newIdempotencyKey()},
      ),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> momentsFeed({
    String mode = 'recommended',
    String? cursor,
  }) =>
      getJson(
        '/moments/feed${Uri(queryParameters: {
              'mode': mode,
              if (cursor != null) 'cursor': cursor
            })}',
      );

  Future<Map<String, dynamic>> momentNewPosts({
    String? since,
    String? cursor,
  }) =>
      getJson(
        '/moments/new-posts${Uri(queryParameters: {
              if (since != null) 'since': since,
              if (cursor != null) 'cursor': cursor
            }).toString()}',
      );
  Future<Map<String, dynamic>> searchMoments(String query) =>
      getJson('/moments/search?q=${Uri.encodeQueryComponent(query)}');
  Future<Map<String, dynamic>> publishMoment({
    required String text,
    required String visibility,
    List<String> imageUrls = const [],
    List<String> videoUrls = const [],
    List<String> includeUserIds = const [],
    List<String> excludeUserIds = const [],
    List<String> includeTagIds = const [],
    List<String> excludeTagIds = const [],
    String? linkUrl,
    String? idempotencyKey,
  }) =>
      postJson(
          '/moments',
          {
            'text': text,
            'visibility': visibility,
            'image_urls': imageUrls,
            if (videoUrls.isNotEmpty) 'video_urls': videoUrls,
            'include_user_ids': includeUserIds,
            'exclude_user_ids': excludeUserIds,
            'include_tag_ids': includeTagIds,
            'exclude_tag_ids': excludeTagIds,
            'link_url': linkUrl,
          },
          idempotencyKey: idempotencyKey ?? newIdempotencyKey());
  Future<Map<String, dynamic>> likeMoment(String id) =>
      postJson('/moments/$id/likes', {}, idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> commentMoment(String id, String text,
          {String? parentId,
          List<String> imageUploadIds = const [],
          String? idempotencyKey}) =>
      postJson(
          '/moments/$id/comments',
          {
            'text': text,
            if (parentId != null) 'parent_id': parentId,
            if (imageUploadIds.isNotEmpty) 'image_upload_ids': imageUploadIds,
          },
          idempotencyKey: idempotencyKey ?? newIdempotencyKey());
  Future<Map<String, dynamic>> momentDetail(String id) =>
      getJson('/moments/$id');
  Future<void> unlikeMoment(String id) => deleteJson('/moments/$id/likes');
  Future<void> deleteMoment(String id) => deleteJson('/moments/$id');
  Future<void> deleteMomentComment(String momentId, String commentId) =>
      deleteJson('/moments/$momentId/comments/$commentId');
  Future<Map<String, dynamic>> momentDraft() => getJson('/moments/draft');
  Future<Map<String, dynamic>> saveMomentDraft(Map<String, dynamic> payload) =>
      putJson('/moments/draft', {'payload': payload});
  Future<void> deleteMomentDraft() => deleteJson('/moments/draft');
  Future<Map<String, dynamic>> momentAds() => getJson('/moments/ads');
  Future<Map<String, dynamic>> beginMomentUpload({
    required String fileName,
    required String mimeType,
    required int byteSize,
  }) =>
      postJson(
          '/moments/media/uploads',
          {
            'file_name': fileName,
            'mime_type': mimeType,
            'byte_size': byteSize,
          },
          idempotencyKey: newIdempotencyKey());
  Future<void> putMomentUpload(
    String uploadId,
    List<int> bytes,
    String mimeType,
  ) async {
    final response = await _authorized(
      (headers) => _client.put(
        _uri('/moments/media/uploads/$uploadId/content'),
        headers: {...headers, 'Content-Type': mimeType},
        body: bytes,
      ),
    );
    if (response.statusCode >= 400) _decode(response);
  }

  Future<Map<String, dynamic>> completeMomentUpload(String uploadId) =>
      postJson(
        '/moments/media/uploads/$uploadId/complete',
        {},
        idempotencyKey: newIdempotencyKey(),
      );
  Future<Map<String, dynamic>> beginMomentCoverUpload({
    required String fileName,
    required String mimeType,
    required int byteSize,
  }) =>
      postJson(
          '/moments/cover/uploads',
          {
            'file_name': fileName,
            'mime_type': mimeType,
            'byte_size': byteSize,
          },
          idempotencyKey: newIdempotencyKey());
  Future<void> putMomentCoverUpload(
    String uploadId,
    List<int> bytes,
    String mimeType,
  ) async {
    final response = await _authorized(
      (headers) => _client.put(
        _uri('/moments/cover/uploads/$uploadId/content'),
        headers: {...headers, 'Content-Type': mimeType},
        body: bytes,
      ),
    );
    if (response.statusCode >= 400) _decode(response);
  }

  Future<Map<String, dynamic>> completeMomentCoverUpload(String uploadId) =>
      postJson(
        '/moments/cover/uploads/$uploadId/complete',
        {},
        idempotencyKey: newIdempotencyKey(),
      );
  Future<Map<String, dynamic>> setMomentCover(String uploadId) => putJson(
        '/moments/cover',
        {'upload_id': uploadId},
        idempotencyKey: newIdempotencyKey(),
      );
  Future<Map<String, dynamic>> personalMoments(String userId) =>
      getJson('/moments/users/$userId');

  /// 单条修改朋友圈可见范围（作者本人）。
  Future<Map<String, dynamic>> updateMomentVisibility(
          String momentId, Map<String, dynamic> selection) =>
      patchJson(
          '/moments/${Uri.encodeComponent(momentId)}/visibility', selection,
          idempotencyKey: newIdempotencyKey());

  Future<Map<String, dynamic>> momentProfilePreview(String userId) =>
      getJson('/moments/users/${Uri.encodeComponent(userId)}/preview');
  Future<Map<String, dynamic>> momentNotifications(
          {int limit = 30, String? cursor}) =>
      getJson('/moments/notifications?limit=$limit'
          '${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}');
  Future<Map<String, dynamic>> momentUnreadCount() =>
      getJson('/moments/notifications/unread-count');
  Future<void> markMomentNotificationsRead(List<String> ids) async {
    if (ids.isEmpty) return;
    final response = await _authorized(
      (headers) => _client.post(
        _uri('/moments/notifications/read'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode(ids),
      ),
    );
    if (response.statusCode != 204) _decode(response);
  }

  Future<Map<String, dynamic>> momentsPreferences() =>
      getJson('/moments/preferences');
  Future<Map<String, dynamic>> updateMomentsPreferences({
    required String historyRange,
    required bool personalized,
    String? coverUrl,
    bool? profileEntryEnabled,
    List<String>? excludedUserIds,
  }) =>
      putJson('/moments/preferences', {
        'history_range': historyRange,
        'personalized_recommendations': personalized,
        if (coverUrl != null) 'cover_url': coverUrl,
        if (profileEntryEnabled != null)
          'profile_entry_enabled': profileEntryEnabled,
        if (excludedUserIds != null) 'excluded_user_ids': excludedUserIds,
      });
  Future<Map<String, dynamic>> requestWithdrawal({
    required String amount,
    required String address,
    required String clientOrderId,
    required String reasonCode,
  }) =>
      postJson(
          '/wallet/withdrawals',
          {
            'amount': amount,
            'address': address,
            'client_order_id': clientOrderId,
            'reason_code': reasonCode,
          },
          idempotencyKey: clientOrderId);
  Future<Map<String, dynamic>> getJson(
    String path, {
    String? expectedWalletScope,
    String? expectedPaymentScope,
  }) async {
    final response = await _authorized(
      (headers) => _client.get(_uri(path), headers: headers),
      expectedWalletScope: expectedWalletScope,
      expectedPaymentScope: expectedPaymentScope,
    );
    return _decode(response);
  }

  // ------------------------------------------------------------------
  // ADR-0075：手机号认证（注册/短信登录/两步换绑/隐私搜索）。
  // 红线：验证码与完整手机号绝不进入日志；会话写入沿用 login 纪律。
  // ------------------------------------------------------------------
  @override
  Future<phone_contracts.RegistrationPhoneReceipt> registerWithPhone({
    required String username,
    String? nickname,
    required String phone,
    required String password,
    required String invitationCode,
  }) async {
    final operation = 'register-phone:$username:$phone:$invitationCode';
    final response = await _client
        .post(
          _uri('/auth/register'),
          headers: {
            'Content-Type': 'application/json',
            'X-Device-Key': await sessionStore.registrationDeviceKey(),
            'Idempotency-Key': _pendingIdempotencyKey(operation),
          },
          body: jsonEncode({
            'username': username,
            if (nickname != null) 'nickname': nickname,
            'phone': phone,
            'password': password,
            'invitation_code': invitationCode,
          }),
        )
        .timeout(_httpTimeout);
    final body = _decode(response);
    _pendingIdempotencyKeys.remove(operation);
    return phone_contracts.RegistrationPhoneReceipt(
      registrationSession: body['registration_session'] as String,
      status: body['status'] as String,
      resendAfterSeconds: body['resend_after_seconds'] as int,
    );
  }

  @override
  Future<void> requestRegistrationOtp(String registrationSession) async {
    final response = await _client
        .post(
          _uri('/auth/phone/registration/request'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'registration_session': registrationSession}),
        )
        .timeout(_httpTimeout);
    _decode(response);
  }

  @override
  Future<void> verifyRegistrationPhone({
    required String registrationSession,
    required String phone,
    required String code,
  }) async {
    final operation = 'phone-verify:$registrationSession:$code';
    final response = await _client
        .post(
          _uri('/auth/phone/registration/verify'),
          headers: {
            'Content-Type': 'application/json',
            'Idempotency-Key': _pendingIdempotencyKey(operation),
          },
          body: jsonEncode({
            'registration_session': registrationSession,
            'phone': phone,
            'code': code,
          }),
        )
        .timeout(_httpTimeout);
    _decode(response);
    _pendingIdempotencyKeys.remove(operation);
  }

  @override
  Future<void> requestPhoneLoginOtp(String phone) async {
    final response = await _client
        .post(
          _uri('/auth/phone/login/request'),
          headers: {
            'Content-Type': 'application/json',
            'X-Device-Key': await sessionStore.registrationDeviceKey(),
          },
          body: jsonEncode({'phone': phone}),
        )
        .timeout(_httpTimeout);
    _decode(response);
  }

  @override
  Future<Map<String, dynamic>> phoneLogin({
    required String phone,
    required String code,
    required String deviceKey,
    required String deviceName,
    String invitationCode = '',
    bool termsAccepted = false,
    bool Function()? shouldContinue,
  }) async {
    final loginEpoch = _beginPhoneLogin();
    final response = await _client
        .post(
          _uri('/auth/phone/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'phone': phone,
            'code': code,
            'allow_invitation_continuation': true,
            if (invitationCode.isNotEmpty) 'invitation_code': invitationCode,
            if (termsAccepted) 'terms_accepted': true,
            'device_key': deviceKey,
            'device_name': deviceName,
          }),
        )
        .timeout(_httpTimeout);
    var body = _decode(response);
    String? invitationTicket;
    if (body['status'] == 'INVITATION_VERIFIED') {
      if (loginEpoch != _sessionEpoch || shouldContinue?.call() == false) {
        throw _ended;
      }
      final ticket = _invitationTicket(body);
      invitationTicket = ticket;
      if (invitationCode.trim().isEmpty) {
        throw phone_contracts.PhoneInvitationContinuationRequired(
            ticket: ticket,
            issue: phone_contracts.PhoneInvitationIssue.required);
      }
      try {
        body = await _submitPhoneInvitation(
            invitationTicket: ticket,
            phone: phone,
            invitationCode: invitationCode,
            termsAccepted: termsAccepted,
            deviceKey: deviceKey,
            deviceName: deviceName,
            shouldContinue: shouldContinue,
            loginEpoch: loginEpoch);
      } on phone_contracts.PhoneInvitationContinuationRequired {
        rethrow;
      } on BusinessApiException catch (error) {
        if (error.code == 'INVITATION_TICKET_INVALID' ||
            error.code == 'AUTH_SESSION_ENDED') {
          rethrow;
        }
        throw phone_contracts.PhoneInvitationContinuationRequired(
            ticket: ticket,
            issue: phone_contracts.PhoneInvitationIssue.uncertain);
      } on Exception {
        throw phone_contracts.PhoneInvitationContinuationRequired(
            ticket: ticket,
            issue: phone_contracts.PhoneInvitationIssue.uncertain);
      }
    }
    try {
      return await _finishPhoneLogin(body,
          deviceKey: deviceKey,
          deviceName: deviceName,
          shouldContinue: shouldContinue,
          loginEpoch: loginEpoch);
    } on BusinessApiException catch (error) {
      if (invitationTicket == null ||
          error.code == 'AUTH_SESSION_ENDED' ||
          error.code == 'LOGIN_TICKET_INVALID') {
        rethrow;
      }
      throw phone_contracts.PhoneInvitationContinuationRequired(
          ticket: invitationTicket,
          issue: error.code == 'PHONE_PROVISIONING_PENDING'
              ? phone_contracts.PhoneInvitationIssue.provisioning
              : phone_contracts.PhoneInvitationIssue.uncertain);
    } on Exception {
      if (invitationTicket == null) rethrow;
      throw phone_contracts.PhoneInvitationContinuationRequired(
          ticket: invitationTicket,
          issue: phone_contracts.PhoneInvitationIssue.uncertain);
    }
  }

  int _beginPhoneLogin() {
    final loginEpoch = ++_sessionEpoch;
    supportIdentities.clear();
    _refreshFlight = null;
    _refreshRetryAt = null;
    _refreshFailures = 0;
    _matrixGrantFlight = null;
    _matrixGrantRetryAt = null;
    return loginEpoch;
  }

  String _invitationTicket(Map<String, dynamic> body) {
    final ticket = body['invitation_ticket'];
    if (ticket is! String || ticket.length < 32 || ticket.length > 128) {
      throw const FormatException('Invalid phone invitation response');
    }
    return ticket;
  }

  phone_contracts.PhoneInvitationIssue? _invitationIssue(Object? status) =>
      switch (status) {
        'INVITATION_REQUIRED' => phone_contracts.PhoneInvitationIssue.required,
        'INVITATION_INVALID' => phone_contracts.PhoneInvitationIssue.invalid,
        'INVITATION_EXPIRED' => phone_contracts.PhoneInvitationIssue.expired,
        'INVITATION_EXHAUSTED' =>
          phone_contracts.PhoneInvitationIssue.exhausted,
        'TERMS_REQUIRED' => phone_contracts.PhoneInvitationIssue.terms,
        _ => null,
      };

  Future<Map<String, dynamic>> _submitPhoneInvitation({
    required String invitationTicket,
    required String phone,
    required String invitationCode,
    required bool termsAccepted,
    required String deviceKey,
    required String deviceName,
    required int loginEpoch,
    bool Function()? shouldContinue,
  }) async {
    if (loginEpoch != _sessionEpoch || shouldContinue?.call() == false) {
      throw _ended;
    }
    final response = await _client
        .post(
          _uri('/auth/phone/login/invitation'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'phone': phone,
            'invitation_ticket': invitationTicket,
            'invitation_code': invitationCode,
            'terms_accepted': termsAccepted,
            'device_key': deviceKey,
            'device_name': deviceName,
          }),
        )
        .timeout(_httpTimeout);
    final body = _decode(response);
    if (loginEpoch != _sessionEpoch || shouldContinue?.call() == false) {
      throw _ended;
    }
    final issue = _invitationIssue(body['status']);
    if (issue != null) {
      if (_invitationTicket(body) != invitationTicket) {
        throw const FormatException('Mismatched phone invitation response');
      }
      throw phone_contracts.PhoneInvitationContinuationRequired(
          ticket: invitationTicket, issue: issue);
    }
    return body;
  }

  @override
  Future<Map<String, dynamic>> completePhoneLoginInvitation({
    required String invitationTicket,
    required String phone,
    required String invitationCode,
    required bool termsAccepted,
    required String deviceKey,
    required String deviceName,
    bool Function()? shouldContinue,
  }) async {
    final loginEpoch = _beginPhoneLogin();
    final body = await _submitPhoneInvitation(
        invitationTicket: invitationTicket,
        phone: phone,
        invitationCode: invitationCode,
        termsAccepted: termsAccepted,
        deviceKey: deviceKey,
        deviceName: deviceName,
        loginEpoch: loginEpoch,
        shouldContinue: shouldContinue);
    return _finishPhoneLogin(body,
        deviceKey: deviceKey,
        deviceName: deviceName,
        shouldContinue: shouldContinue,
        loginEpoch: loginEpoch);
  }

  Future<Map<String, dynamic>> _finishPhoneLogin(
    Map<String, dynamic> body, {
    required String deviceKey,
    required String deviceName,
    required int loginEpoch,
    bool Function()? shouldContinue,
  }) async {
    final waiting = Stopwatch()..start();
    final ticket = body['login_ticket']?.toString();
    while (body['status'] == 'PENDING_MATRIX') {
      if (loginEpoch != _sessionEpoch || shouldContinue?.call() == false) {
        throw _ended;
      }
      if (ticket == null || waiting.elapsed >= const Duration(seconds: 60)) {
        throw BusinessApiException(
            code: 'PHONE_PROVISIONING_PENDING',
            message: '账号仍在开通，请稍后重新登录；无需再次注册',
            statusCode: 202);
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      if (loginEpoch != _sessionEpoch || shouldContinue?.call() == false) {
        throw _ended;
      }
      final remaining = const Duration(seconds: 60) - waiting.elapsed;
      if (remaining <= Duration.zero) continue;
      final completion = await _client
          .post(_uri('/auth/phone/login/complete'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'login_ticket': ticket,
                'device_key': deviceKey,
                'device_name': deviceName
              }))
          .timeout(remaining < _httpTimeout ? remaining : _httpTimeout,
              onTimeout: () => throw BusinessApiException(
                  code: 'PHONE_PROVISIONING_PENDING',
                  message: '账号开通结果待确认，请稍后重新登录；无需再次注册',
                  statusCode: 202));
      body = _decode(completion);
    }
    if (!body.containsKey('access_token') ||
        !body.containsKey('refresh_token')) {
      throw const FormatException('Invalid phone login response');
    }
    if (shouldContinue?.call() == false) throw _ended;
    if (loginEpoch != _sessionEpoch) throw _ended;
    final returnedMatrixUserId = body['matrix_user_id']?.toString();
    await _writeCurrentSession(loginEpoch, () {
      if (shouldContinue?.call() == false) throw _ended;
      return sessionStore.saveSession(
        accessToken: body['access_token'] as String,
        refreshToken: body['refresh_token'] as String,
        deviceKey: deviceKey,
        matrixUserId:
            returnedMatrixUserId == null || returnedMatrixUserId.isEmpty
                ? null
                : returnedMatrixUserId,
      );
    });
    return body;
  }

  @override
  Future<Map<String, dynamic>> rebindOldRequest() async {
    final response = await _authorized(
      (headers) => _client.post(
        _uri('/auth/phone/rebind/old-request'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({}),
      ),
    );
    return _decode(response);
  }

  @override
  Future<void> rebindOldConfirm({required String code}) async {
    final response = await _authorized(
      (headers) => _client.post(
        _uri('/auth/phone/rebind/old-confirm'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'code': code}),
      ),
    );
    _decode(response);
  }

  @override
  Future<void> rebindNewRequest({required String phone}) async {
    final response = await _authorized(
      (headers) => _client.post(
        _uri('/auth/phone/rebind/new-request'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'phone': phone}),
      ),
    );
    _decode(response);
  }

  @override
  Future<void> rebindNewConfirm(
      {required String phone, required String code}) async {
    final response = await _authorized(
      (headers) => _client.post(
        _uri('/auth/phone/rebind/confirm'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'new_phone': phone, 'code': code}),
      ),
    );
    _decode(response);
  }

  @override
  Future<Map<String, dynamic>> searchByPhone(String phone) async {
    final response = await _authorized(
      (headers) => _client.post(
        _uri('/contacts/search-phone'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'phone': phone}),
      ),
    );
    return _decode(response);
  }

  @override
  Future<void> setPhoneFindable(bool enabled) async {
    final response = await _authorized(
      (headers) => _client.patch(
        _uri('/auth/phone/privacy'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'phone_findable': enabled}),
      ),
    );
    _decode(response);
  }

  // ------------------------------------------------------------------
  // ADR-0077：人工充值（客服结算）；ADR-0076：参考汇率；ADR-0079：转让意图。
  // ------------------------------------------------------------------
  @override
  Future<List<Map<String, dynamic>>> rechargeDirectory() async {
    final body = await getJson('/recharge/directory');
    return (body['items'] as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<Map<String, dynamic>> submitRecharge({
    required String amountUsdt,
    String? evidenceTxid,
    String? note,
    required String idempotencyKey,
  }) =>
      postJson(
        '/recharge/requests',
        {
          'amount_usdt': amountUsdt,
          if (evidenceTxid != null) 'evidence_txid': evidenceTxid,
          if (note != null) 'note': note,
        },
        idempotencyKey: idempotencyKey,
      );

  @override
  Future<List<Map<String, dynamic>>> myRecharges() async {
    final body = await getJson('/recharge/requests/mine');
    return (body['items'] as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<void> cancelRecharge(String requestId) =>
      postJson('/recharge/requests/$requestId/cancel', {},
          idempotencyKey: 'recharge-cancel:$requestId');

  @override
  Future<Map<String, dynamic>> fxRate() => getJson('/fx/rate');

  @override
  Future<List<Map<String, dynamic>>> transferIntents(String roomId) async {
    final body = await getJson(
        '/groups/${Uri.encodeComponent(roomId)}/transfer-intents');
    return (body['items'] as List).cast<Map<String, dynamic>>();
  }

  /// Same ownership tenure + target has one durable identity across app restarts.
  /// Unknown requests are replayed to the coordinator, never to Matrix directly.
  Future<Map<String, dynamic>> requestGroupOwnershipTransfer(
      String roomId, String targetMatrixUserId) async {
    final epoch = _sessionEpoch;
    final owner = await getJson('/groups/${Uri.encodeComponent(roomId)}/owner');
    final target = await lookupUserByMatrixId(targetMatrixUserId);
    final targetId = target['user_id'] as String?;
    if (targetId == null ||
        targetId.isEmpty ||
        owner['owner_user_id'] == null) {
      throw const BusinessApiException(
          statusCode: 409,
          code: 'GROUP_OWNER_UNRESOLVABLE',
          message: '无法确认群主或成员身份，请刷新后重试');
    }
    if (epoch != _sessionEpoch) {
      throw const BusinessApiException(
          statusCode: 409, code: 'SESSION_CHANGED', message: '账号已切换，请重新打开群资料');
    }
    final key = sha256
        .convert(utf8.encode(jsonEncode(
            [roomId, owner['owner_user_id'], owner['owner_since'], targetId])))
        .toString();
    return postJson('/groups/${Uri.encodeComponent(roomId)}/transfer-owner',
        {'new_owner_user_id': targetId},
        idempotencyKey: 'owner:$key');
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body, {
    required String idempotencyKey,
    String? expectedWalletScope,
    String? expectedPaymentScope,
  }) async {
    final response = await _authorized(
      (headers) => _client.post(
        _uri(path),
        headers: {
          ...headers,
          'Content-Type': 'application/json',
          'Idempotency-Key': idempotencyKey,
        },
        body: jsonEncode(body),
      ),
      expectedWalletScope: expectedWalletScope,
      expectedPaymentScope: expectedPaymentScope,
    );
    return _decode(response);
  }

  Future<void> deleteJson(String path) async {
    final response = await _authorized(
      (headers) => _client.delete(
        _uri(path),
        headers: {...headers, 'Idempotency-Key': newIdempotencyKey()},
      ),
    );
    if (response.statusCode == 204) return;
    _decode(response);
  }

  Future<Map<String, dynamic>> patchJson(
    String path,
    Map<String, dynamic> body, {
    required String idempotencyKey,
  }) async {
    final response = await _authorized(
      (headers) => _client.patch(
        _uri(path),
        headers: {
          ...headers,
          'Content-Type': 'application/json',
          'Idempotency-Key': idempotencyKey,
        },
        body: jsonEncode(body),
      ),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> putJson(
    String path,
    Map<String, dynamic> body, {
    String? idempotencyKey,
  }) async {
    final response = await _authorized(
      (headers) => _client.put(
        _uri(path),
        headers: {
          ...headers,
          'Content-Type': 'application/json',
          if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
        },
        body: jsonEncode(body),
      ),
    );
    return _decode(response);
  }

  static const _httpTimeout = Duration(seconds: 8);

  /// A03：单次授权操作（初次+刷新+重试）的总预算。
  static const _authorizedTotalTimeout = Duration(seconds: 20);

  /// A03：会话代数——登出递增；在途刷新的迟到结果据此失效。
  int _sessionEpoch = 0;

  /// Debug output uses no request path: path segments can hold room, user or
  /// upload identifiers even when the query string is omitted.
  void _logRequest(Object outcome) {
    if (!kDebugMode) return;
    debugPrint('[chatflow/network] business_request -> $outcome');
  }

  Future<http.Response> _authorized(
    Future<http.Response> Function(Map<String, String>) operation, {
    Duration timeout = _httpTimeout,
    String? expectedWalletScope,
    String? expectedPaymentScope,
  }) async {
    final diagnostics = ChatDiagnostics.instance;
    final diagnosticGeneration = diagnostics.sessionGeneration;
    final requestEpoch = _sessionEpoch;
    final watch = Stopwatch()..start();
    void networkDiagnostic(ChatDiagnosticError error, {int? status}) {
      if (!identical(ChatDiagnostics.instance, diagnostics) ||
          requestEpoch != _sessionEpoch ||
          diagnostics.sessionGeneration != diagnosticGeneration) {
        return;
      }
      diagnostics.record(
          stage: ChatDiagnosticStage.networkRequest,
          error: error,
          elapsed: watch.elapsed,
          status: status);
    }

    final performanceScope = _client.beginLogicalRequest();
    Object? failure;
    Future<http.Response> attempt(Map<String, String> headers) =>
        performanceScope == null
            ? operation(headers)
            : performanceScope.run(() => operation(headers));
    try {
      final epoch = _sessionEpoch;
      // A03：整次授权操作（初次请求 + 刷新 + 重试）受总截止时间约束，
      // 每个阶段都有独立超时——不再出现"刷新/重试无限等待"。
      final deadline = DateTime.now().add(_authorizedTotalTimeout);
      Future<Duration> remaining() async => deadline.difference(DateTime.now());
      final initial = await sessionStore.session();
      if (epoch != _sessionEpoch) throw _ended;
      void guardPayment(StoredBusinessSession? session) {
        if (expectedPaymentScope != null &&
            _paymentSessionScope(session) != expectedPaymentScope) {
          throw StateError('支付会话已变化，请重新打开支付页面');
        }
      }

      guardPayment(initial);
      if (expectedWalletScope != null &&
          _walletSessionScope(initial) != expectedWalletScope) {
        throw StateError('账户已切换，请重新打开钱包');
      }
      http.Response response;
      try {
        response = await attempt({
          if (initial != null) 'Authorization': 'Bearer ${initial.accessToken}',
        }).timeout(timeout);
      } catch (error) {
        _logRequest('ERROR:${error.runtimeType}');
        rethrow;
      }
      if (response.statusCode >= 400) {
        _logRequest('HTTP ${response.statusCode}');
      }
      if (response.statusCode == 401) {
        networkDiagnostic(ChatDiagnosticError.rejected, status: 401);
      }
      await _checkReplacement(response, epoch);
      if (response.statusCode != 401 || initial == null) {
        if (expectedPaymentScope != null) {
          guardPayment(await sessionStore.session());
        }
        return response;
      }
      final refreshBudget = await remaining();
      if (refreshBudget <= Duration.zero) {
        throw TimeoutException('authorized request budget exhausted');
      }
      // Bound this caller, not the shared refresh: its durable result must still
      // be saved for other callers if this request's budget runs out.
      final replacement = await refreshSession().timeout(refreshBudget);
      if (epoch != _sessionEpoch) throw _ended;
      guardPayment(replacement);
      if (expectedWalletScope != null &&
          _walletSessionScope(replacement) != expectedWalletScope) {
        throw StateError('账户已切换，请重新打开钱包');
      }
      final budget = await remaining();
      if (budget.isNegative) {
        throw TimeoutException('authorized request budget exhausted');
      }
      performanceScope?.retryCount++;
      final retried = await attempt({
        'Authorization': 'Bearer ${replacement.accessToken}',
      }).timeout(budget < timeout ? budget : timeout);
      await _checkReplacement(retried, epoch);
      if (expectedPaymentScope != null) {
        guardPayment(await sessionStore.session());
      }
      return retried;
    } catch (error) {
      failure = error;
      if (error is TimeoutException) {
        networkDiagnostic(ChatDiagnosticError.timeout);
      } else if (error is SocketException ||
          error is HandshakeException ||
          error is http.ClientException) {
        networkDiagnostic(ChatDiagnosticError.network);
      }
      rethrow;
    } finally {
      performanceScope?.finish(failure: failure);
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } on FormatException {
      // Proxy HTML and empty errors must retain their HTTP status without
      // exposing arbitrary response contents to the user.
    }
    if (response.statusCode >= 400) {
      final error = body?['error'];
      final details = error is Map ? error : const <String, dynamic>{};
      throw BusinessApiException(
        statusCode: response.statusCode,
        code: details['code']?.toString() ?? 'BUSINESS_REQUEST_FAILED',
        message: details['message']?.toString() ?? '业务请求失败',
        fieldErrors: _parseFieldErrors(details['fields']),
        retryAfterSeconds: response.statusCode == 429
            ? _retrySeconds(response.headers['retry-after'])
            : null,
      );
    }
    if (body == null) throw const FormatException('Invalid business response');
    return body;
  }

  static int _retrySeconds(String? value) {
    final parsed = int.tryParse(value ?? '');
    return parsed != null && parsed > 0 && parsed <= 86400 ? parsed : 60;
  }

  static Map<String, String> _parseFieldErrors(Object? raw) {
    if (raw is! List) return const {};
    final result = <String, String>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final loc = item['loc'];
      final message = item['msg']?.toString();
      if (loc is List &&
          loc.isNotEmpty &&
          message != null &&
          message.isNotEmpty) {
        final field = loc.last?.toString();
        if (field != null && field != 'body') result[field] = message;
      }
    }
    return result;
  }
}
