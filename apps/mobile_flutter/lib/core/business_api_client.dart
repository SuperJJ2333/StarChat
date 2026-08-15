import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'session_store.dart';
import 'package:uuid/uuid.dart';
import '../features/auth/login_controller.dart';
import '../features/auth/registration_controller.dart';
import '../features/profile/profile_controller.dart';
import '../features/contacts/contact_models.dart';

final class BusinessApiException implements Exception {
  const BusinessApiException(
      {required this.statusCode, required this.code, required this.message});
  final int statusCode;
  final String code;
  final String message;
  @override
  String toString() => message;
}

enum BusinessSessionRestore { absent, authenticated, offline, invalid }

abstract interface class BusinessSessionGateway {
  Future<BusinessSessionRestore> restoreSession();
  Future<String?> currentMatrixUserId();
  Future<void> logout();
}

final class BusinessApiClient
    implements
        BusinessSessionGateway,
        RegistrationGateway,
        DualDomainBusinessGateway,
        ProfileGateway,
        ContactsGateway {
  BusinessApiClient(
      {required this.baseUri, required this.sessionStore, http.Client? client})
      : _client = client ?? http.Client();
  final Uri baseUri;
  final SecureSessionStore sessionStore;
  final http.Client _client;
  final Uuid _uuid = const Uuid();
  String newIdempotencyKey() => _uuid.v4();
  Uri _uri(String path) =>
      baseUri.resolve(path.startsWith('/api/v1/') ? path : '/api/v1$path');
  Future<Map<String, dynamic>> login(
      {required String username,
      required String password,
      required String deviceKey,
      required String deviceName}) async {
    final response = await _client.post(_uri('/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'device_key': deviceKey,
          'device_name': deviceName
        }));
    final body = _decode(response);
    await sessionStore.saveSession(
        accessToken: body['access_token'] as String,
        refreshToken: body['refresh_token'] as String);
    return body;
  }

  @override
  Future<void> loginBusiness(
      {required String username,
      required String password,
      required String deviceKey,
      required String deviceName}) async {
    await login(
        username: username,
        password: password,
        deviceKey: deviceKey,
        deviceName: deviceName);
  }

  @override
  Future<MatrixLoginGrant> issueMatrixLoginToken() async {
    final response = await _authorized((headers) =>
        _client.post(_uri('/auth/matrix-login-token'), headers: headers));
    final body = _decode(response);
    return MatrixLoginGrant(
        loginToken: body['login_token'] as String,
        homeserver: body['homeserver'] as String,
        expiresIn: body['expires_in'] as int);
  }

  @override
  Future<void> bindMatrixUserId(String matrixUserId) async {
    final stored = await sessionStore.session();
    if (stored == null) {
      throw const BusinessApiException(
          statusCode: 401, code: 'AUTH_REQUIRED', message: '需要登录');
    }
    await sessionStore.saveSession(
        accessToken: stored.accessToken,
        refreshToken: stored.refreshToken,
        matrixUserId: matrixUserId);
  }

  @override
  Future<void> logoutBusiness() => logout();
  @override
  Future<bool> validateInvitation(String invitationCode) async {
    final response = await _client.post(_uri('/invitations/validate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'invitation_code': invitationCode}));
    return _decode(response)['valid'] as bool;
  }

  @override
  Future<RegistrationReceipt> register(
      {required String username,
      required String email,
      required String password,
      required String invitationCode}) async {
    final response = await _client.post(_uri('/auth/register'),
        headers: {
          'Content-Type': 'application/json',
          'Idempotency-Key': newIdempotencyKey()
        },
        body: jsonEncode({
          'username': username,
          'email': email,
          'password': password,
          'invitation_code': invitationCode
        }));
    final body = _decode(response);
    return RegistrationReceipt(
        registrationSession: body['registration_session'] as String,
        status: body['status'] as String,
        resendAfterSeconds: body['resend_after_seconds'] as int);
  }

  @override
  Future<void> verifyEmail(
      {required String registrationSession,
      String? code,
      String? token}) async {
    final response = await _client.post(
        _uri('/auth/email-verifications/verify'),
        headers: {
          'Content-Type': 'application/json',
          'Idempotency-Key': newIdempotencyKey()
        },
        body: jsonEncode({
          'registration_session': registrationSession,
          if (code != null) 'code': code,
          if (token != null) 'token': token
        }));
    _decode(response);
  }

  @override
  Future<int> resendVerification(String registrationSession) async {
    final response = await _client.post(
        _uri('/auth/email-verifications/resend'),
        headers: {
          'Content-Type': 'application/json',
          'Idempotency-Key': newIdempotencyKey()
        },
        body: jsonEncode({'registration_session': registrationSession}));
    return _decode(response)['resend_after_seconds'] as int;
  }

  @override
  Future<RegistrationStatusReceipt> registrationStatus(
      String registrationSession) async {
    final response = await _client.get(_uri(
        '/auth/registrations/${Uri.encodeComponent(registrationSession)}'));
    final body = _decode(response);
    return RegistrationStatusReceipt(
        status: body['status'] as String,
        resendAfterSeconds: body['resend_after_seconds'] as int);
  }

  ProfileData _profile(Map<String, dynamic> body) => ProfileData(
      username: body['username'] as String,
      nickname: body['nickname'] as String,
      maskedEmail: body['masked_email'] as String,
      fallbackSeed: body['avatar_fallback_seed'] as String,
      signature: body['signature']?.toString(),
      avatarUrl: body['avatar_url']?.toString());
  @override
  Future<ProfileData> loadProfile() async =>
      _profile(await getJson('/profile/me'));
  @override
  Future<ProfileData> updateProfile(
          {required String nickname, String? signature}) async =>
      _profile(await patchJson(
          '/profile/me', {'nickname': nickname, 'signature': signature},
          idempotencyKey: newIdempotencyKey()));
  @override
  Future<AvatarUploadSession> createAvatarUpload(
      {required String mimeType, required int byteSize}) async {
    final body = await postJson('/profile/avatar/uploads',
        {'mime_type': mimeType, 'byte_size': byteSize},
        idempotencyKey: newIdempotencyKey());
    return AvatarUploadSession(
        uploadId: body['upload_id'] as String,
        uploadUrl: body['upload_url'] as String);
  }

  @override
  Future<void> putAvatar(
      AvatarUploadSession session, AvatarCandidate candidate) async {
    final response = await _authorized((headers) => _client.put(
        baseUri.resolve(session.uploadUrl),
        headers: {...headers, 'Content-Type': candidate.mimeType},
        body: candidate.bytes));
    if (response.statusCode >= 400) _decode(response);
  }

  @override
  Future<ProfileData> completeAvatar(String uploadId) async =>
      _profile(await postJson('/profile/avatar/uploads/$uploadId/complete', {},
          idempotencyKey: newIdempotencyKey()));
  @override
  Future<void> cancelAvatar(String uploadId) async {
    final response = await _authorized((headers) => _client
        .delete(_uri('/profile/avatar/uploads/$uploadId'), headers: headers));
    if (response.statusCode >= 400) _decode(response);
  }

  @override
  Future<void> deleteAvatar() async {
    final response = await _authorized((headers) => _client.delete(
        _uri('/profile/avatar'),
        headers: {...headers, 'Idempotency-Key': newIdempotencyKey()}));
    if (response.statusCode >= 400) _decode(response);
  }

  @override
  Future<BusinessSessionRestore> restoreSession() async {
    final stored = await sessionStore.session();
    if (stored == null) return BusinessSessionRestore.absent;
    try {
      await refreshSession();
      return BusinessSessionRestore.authenticated;
    } on BusinessApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        await sessionStore.clearBusinessSession();
        return BusinessSessionRestore.invalid;
      }
      if (error.statusCode >= 500) return BusinessSessionRestore.offline;
      rethrow;
    } on SocketException {
      return BusinessSessionRestore.offline;
    } on TimeoutException {
      return BusinessSessionRestore.offline;
    } on http.ClientException {
      return BusinessSessionRestore.offline;
    }
  }

  Future<StoredBusinessSession> refreshSession() async {
    final stored = await sessionStore.session();
    if (stored == null) {
      throw const BusinessApiException(
          statusCode: 401, code: 'AUTH_REQUIRED', message: '需要登录');
    }
    final response = await _client.post(
      _uri('/auth/refresh'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': stored.refreshToken}),
    );
    final body = _decode(response);
    final replacement = StoredBusinessSession(
      version: 1,
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String,
      matrixUserId: stored.matrixUserId,
    );
    await sessionStore.saveSession(
      accessToken: replacement.accessToken,
      refreshToken: replacement.refreshToken,
      matrixUserId: replacement.matrixUserId,
    );
    return replacement;
  }

  @override
  Future<void> logout() async {
    final stored = await sessionStore.session();
    try {
      if (stored != null) {
        await _client.post(
          _uri('/auth/logout'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': stored.refreshToken}),
        );
      }
    } finally {
      await sessionStore.clearBusinessSession();
    }
  }

  Future<String?> currentUserId() async {
    final token = (await sessionStore.session())?.accessToken;
    if (token == null) return null;
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    return payload is Map<String, dynamic> ? payload['sub']?.toString() : null;
  }

  @override
  Future<String?> currentMatrixUserId() async =>
      (await sessionStore.session())?.matrixUserId;
  Future<Map<String, dynamic>> caibiBalance() => getJson('/ledger/balances/me');
  Future<Map<String, dynamic>> transferCaibi(
          String receiverId, String amount) =>
      postJson(
          '/ledger/transfers', {'receiver_id': receiverId, 'amount': amount},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> createRedPacket(
          {required String mode,
          required String total,
          required int shareCount,
          String? roomId,
          String? recipientId}) =>
      postJson(
          '/red-packets',
          {
            'mode': mode,
            'total': total,
            'share_count': shareCount,
            if (roomId != null) 'room_id': roomId,
            if (recipientId != null) 'recipient_id': recipientId
          },
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> claimRedPacket(String id) =>
      postJson('/red-packets/$id/claims', {},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> redPacketDetail(String id) =>
      getJson('/red-packets/$id');
  Future<Map<String, dynamic>> listRedPackets({String? roomId}) => getJson(
      '/red-packets${roomId == null ? '' : '?room_id=${Uri.encodeQueryComponent(roomId)}'}');
  Future<Map<String, dynamic>> walletBalance() =>
      getJson('/wallet/balances/me');
  Future<Map<String, dynamic>> walletDepositAddress() =>
      getJson('/wallet/deposit-address');
  Future<Map<String, dynamic>> walletHistory({String? kind}) =>
      getJson('/wallet/transactions${kind == null ? '' : '?kind=$kind'}');
  Future<Map<String, dynamic>> withdrawalStatus(String id) =>
      getJson('/wallet/withdrawals/$id');
  Future<Map<String, dynamic>> friends() => getJson('/friends');
  @override
  Future<List<ContactSummary>> listContacts() async {
    final body = await friends();
    return (body['items'] as List)
        .map((item) => ContactSummary.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> friendRequests() => getJson('/friends/requests');
  Future<Map<String, dynamic>> contactTags() => getJson('/contact-tags');
  Future<Map<String, dynamic>> createContactTag(String name) =>
      postJson('/contact-tags', {'name': name},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> blocks() => getJson('/blocks');
  Future<Map<String, dynamic>> updateContact(String id,
          {String? remark,
          List<String> tags = const [],
          String momentsPermission = 'DEFAULT'}) =>
      patchJson(
          '/friends/$id',
          {
            'remark': remark,
            'tags': tags,
            'moments_permission': momentsPermission
          },
          idempotencyKey: newIdempotencyKey());
  @override
  Future<ContactDetails> updateContactDetails(ContactDetails contact,
      {required String? remark,
      required List<String> tags,
      required String momentsPermission}) async {
    final body = await updateContact(contact.userId,
        remark: remark, tags: tags, momentsPermission: momentsPermission);
    return ContactSummary.fromJson(body).toDetails();
  }

  Future<Map<String, dynamic>> blockUser(String id) =>
      postJson('/blocks', {'user_id': id}, idempotencyKey: newIdempotencyKey());
  @override
  Future<void> blockContact(String userId) async {
    await blockUser(userId);
  }

  @override
  Future<void> deleteContact(String userId) async {
    final response = await _authorized((headers) => _client.delete(
        _uri('/friends/$userId'),
        headers: {...headers, 'Idempotency-Key': newIdempotencyKey()}));
    if (response.statusCode >= 400) _decode(response);
  }

  Future<Map<String, dynamic>> searchUsers(String query) =>
      getJson('/users/search?q=${Uri.encodeQueryComponent(query)}');
  Future<Map<String, dynamic>> requestFriend(String userId,
          {String message = ''}) =>
      postJson(
          '/friends/requests', {'target_user_id': userId, 'message': message},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> acceptFriendRequest(String id) =>
      postJson('/friends/requests/$id/accept', {},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> rejectFriendRequest(String id) =>
      postJson('/friends/requests/$id/reject', {},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> momentsFeed({String mode = 'recommended'}) =>
      getJson('/moments/feed?mode=$mode');
  Future<Map<String, dynamic>> searchMoments(String query) =>
      getJson('/moments/search?q=${Uri.encodeQueryComponent(query)}');
  Future<Map<String, dynamic>> publishMoment(
          {required String text,
          required String visibility,
          List<String> imageUrls = const [],
          List<String> includeUserIds = const [],
          List<String> excludeUserIds = const []}) =>
      postJson(
          '/moments',
          {
            'text': text,
            'visibility': visibility,
            'image_urls': imageUrls,
            'include_user_ids': includeUserIds,
            'exclude_user_ids': excludeUserIds
          },
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> likeMoment(String id) =>
      postJson('/moments/$id/likes', {}, idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> commentMoment(String id, String text) =>
      postJson('/moments/$id/comments', {'text': text},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> momentsPreferences() =>
      getJson('/moments/preferences');
  Future<Map<String, dynamic>> updateMomentsPreferences(
          {required String historyRange, required bool personalized}) =>
      putJson('/moments/preferences', {
        'history_range': historyRange,
        'personalized_recommendations': personalized
      });
  Future<Map<String, dynamic>> requestWithdrawal(
          {required String amount,
          required String address,
          required String clientOrderId,
          required String reasonCode}) =>
      postJson(
          '/wallet/withdrawals',
          {
            'amount': amount,
            'address': address,
            'client_order_id': clientOrderId,
            'reason_code': reasonCode
          },
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> getJson(String path) async {
    final response = await _authorized(
        (headers) => _client.get(_uri(path), headers: headers));
    return _decode(response);
  }

  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body,
      {required String idempotencyKey}) async {
    final response = await _authorized((headers) => _client.post(_uri(path),
        headers: {
          ...headers,
          'Content-Type': 'application/json',
          'Idempotency-Key': idempotencyKey
        },
        body: jsonEncode(body)));
    return _decode(response);
  }

  Future<Map<String, dynamic>> patchJson(String path, Map<String, dynamic> body,
      {required String idempotencyKey}) async {
    final response = await _authorized((headers) => _client.patch(_uri(path),
        headers: {
          ...headers,
          'Content-Type': 'application/json',
          'Idempotency-Key': idempotencyKey
        },
        body: jsonEncode(body)));
    return _decode(response);
  }

  Future<Map<String, dynamic>> putJson(
      String path, Map<String, dynamic> body) async {
    final response = await _authorized((headers) => _client.put(_uri(path),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode(body)));
    return _decode(response);
  }

  Future<http.Response> _authorized(
      Future<http.Response> Function(Map<String, String>) operation) async {
    final initial = await sessionStore.session();
    final response = await operation({
      if (initial != null) 'Authorization': 'Bearer ${initial.accessToken}'
    });
    if (response.statusCode != 401 || initial == null) return response;
    final replacement = await refreshSession();
    return operation({'Authorization': 'Bearer ${replacement.accessToken}'});
  }

  Map<String, dynamic> _decode(http.Response response) {
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw BusinessApiException(
        statusCode: response.statusCode,
        code: body['error']?['code']?.toString() ?? 'BUSINESS_REQUEST_FAILED',
        message: body['error']?['message']?.toString() ?? '业务请求失败',
      );
    }
    return body;
  }
}
