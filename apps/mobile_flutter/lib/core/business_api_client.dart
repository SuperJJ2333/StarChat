import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'session_store.dart';
import 'package:uuid/uuid.dart';
import 'business_api_error.dart';
import 'business_auth_contracts.dart';
import '../features/profile/profile_controller.dart';
import '../features/profile/invite_controller.dart';
import '../features/contacts/contact_models.dart';
import '../features/profile/complaint_models.dart';
import '../features/redpacket/red_packet_controller.dart';

export 'business_api_error.dart';

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
        ContactsGateway,
        AddFriendGateway,
        ComplaintGateway,
        RedPacketViewGateway,
        PersonalInvitationGateway {
  BusinessApiClient(
      {required this.baseUri, required this.sessionStore, http.Client? client})
      : _client = client ?? http.Client();
  final Uri baseUri;
  final SecureSessionStore sessionStore;
  final http.Client _client;
  final Uuid _uuid = const Uuid();
  final Map<String, String> _pendingIdempotencyKeys = {};
  String newIdempotencyKey() => _uuid.v4();
  String _pendingIdempotencyKey(String operation) =>
      _pendingIdempotencyKeys.putIfAbsent(operation, newIdempotencyKey);
  Uri _uri(String path) {
    final url =
        baseUri.resolve(path.startsWith('/api/v1/') ? path : '/api/v1$path');
    _lastRequestUrl = url; // 供 debug 日志记录（不含 query 密钥）
    return url;
  }

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
        refreshToken: body['refresh_token'] as String,
        deviceKey: deviceKey);
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
        expiresIn: body['expires_in'] as int,
        matrixUserId: body['matrix_user_id'] as String);
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
  Future<InvitationValidationResult> validateInvitation(
      String invitationCode) async {
    final response = await _client.post(_uri('/invitations/validate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'invitation_code': invitationCode}));
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

  @override
  Future<RegistrationReceipt> register(
      {required String username,
      String? nickname,
      required String email,
      required String password,
      required String invitationCode}) async {
    final operation =
        'register:${username.trim().toLowerCase()}:${email.trim().toLowerCase()}:$invitationCode';
    final response = await _client.post(_uri('/auth/register'),
        headers: {
          'Content-Type': 'application/json',
          'X-Device-Key': await sessionStore.registrationDeviceKey(),
          'Idempotency-Key': _pendingIdempotencyKey(operation)
        },
        body: jsonEncode({
          'username': username,
          if (nickname != null) 'nickname': nickname,
          'email': email,
          'password': password,
          'invitation_code': invitationCode,
        }));
    final body = _decode(response);
    _pendingIdempotencyKeys.remove(operation);
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
    final operation =
        'verify:$registrationSession:${code != null ? 'code:$code' : 'token:$token'}';
    final response =
        await _client.post(_uri('/auth/email-verifications/verify'),
            headers: {
              'Content-Type': 'application/json',
              'Idempotency-Key': _pendingIdempotencyKey(operation)
            },
            body: jsonEncode({
              'registration_session': registrationSession,
              if (code != null) 'code': code,
              if (token != null) 'token': token
            }));
    _decode(response);
    _pendingIdempotencyKeys.remove(operation);
  }

  @override
  Future<int> resendVerification(String registrationSession) async {
    final operation = 'resend:$registrationSession';
    final response =
        await _client.post(_uri('/auth/email-verifications/resend'),
            headers: {
              'Content-Type': 'application/json',
              'X-Device-Key': await sessionStore.registrationDeviceKey(),
              'Idempotency-Key': _pendingIdempotencyKey(operation)
            },
            body: jsonEncode({'registration_session': registrationSession}));
    final body = _decode(response);
    _pendingIdempotencyKeys.remove(operation);
    return body['resend_after_seconds'] as int;
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
      nudgeSuffix: body['nudge_suffix']?.toString(),
      avatarUrl: body['avatar_url']?.toString());
  @override
  Future<ProfileData> loadProfile() async =>
      _profile(await getJson('/profile/me'));
  @override
  Future<ProfileData> updateProfile(
          {required String nickname,
          String? signature,
          String? nudgeSuffix}) async =>
      _profile(await patchJson(
          '/profile/me',
          {
            'nickname': nickname,
            'signature': signature,
            'nudge_suffix': nudgeSuffix
          },
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

  Future<StoredBusinessSession> _refreshSession() async {
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
      deviceKey: stored.deviceKey,
    );
    await sessionStore.saveSession(
      accessToken: replacement.accessToken,
      refreshToken: replacement.refreshToken,
      matrixUserId: replacement.matrixUserId,
      deviceKey: replacement.deviceKey,
    );
    return replacement;
  }

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
    final response = await _authorized((headers) => _client.post(
          _uri('/presence/heartbeat'),
          headers: {
            ...headers,
            if (session.deviceKey != null) 'X-Device-Key': session.deviceKey!,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            if (clientVersion != null) 'client_version': clientVersion,
          }),
        ));
    if (response.statusCode >= 400) _decode(response);
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
  @override
  Future<Map<String, dynamic>> claimRedPacket(String id) =>
      postJson('/red-packets/$id/claims', {},
          idempotencyKey: newIdempotencyKey());
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) =>
      getJson('/red-packets/$id');
  Future<Map<String, dynamic>> listRedPackets({String? roomId}) => getJson(
      '/red-packets${roomId == null ? '' : '?room_id=${Uri.encodeQueryComponent(roomId)}'}');
  Future<Map<String, dynamic>> redPacketLimits() =>
      getJson('/red-packets/limits');
  Future<Map<String, dynamic>> latestAppUpdate() =>
      getJson('/app-updates/latest');
  Future<Map<String, dynamic>> createChatTransfer(
          {required String receiverId,
          required String amount,
          String? note,
          String? roomId}) =>
      postJson(
          '/chat-transfers',
          {
            'receiver_id': receiverId,
            'amount': amount,
            if (note != null && note.isNotEmpty) 'note': note,
            if (roomId != null) 'room_id': roomId,
          },
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> acceptChatTransfer(String id) =>
      postJson('/chat-transfers/$id/accept', {},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> declineChatTransfer(String id) =>
      postJson('/chat-transfers/$id/decline', {},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> chatTransferDetail(String id) =>
      getJson('/chat-transfers/$id');
  Future<Map<String, dynamic>> walletBalance() =>
      getJson('/wallet/balances/me');
  Future<Map<String, dynamic>> walletDepositAddress() =>
      getJson('/wallet/deposit-address');
  Future<Map<String, dynamic>> walletHistory({String? kind}) =>
      getJson('/wallet/transactions${kind == null ? '' : '?kind=$kind'}');
  Future<Map<String, dynamic>> withdrawalStatus(String id) =>
      getJson('/wallet/withdrawals/$id');
  Future<bool> autoAllowGroupJoin() async =>
      (await getJson('/profile/privacy'))['auto_allow_group_join'] == true;
  Future<bool> setAutoAllowGroupJoin(bool enabled) async =>
      _setAutoAllowGroupJoin(enabled);
  Future<bool> _setAutoAllowGroupJoin(bool enabled) async {
    final response = await _authorized((headers) => _client.put(
          _uri('/profile/privacy/auto-allow-group-join'),
          headers: {...headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'enabled': enabled}),
        ));
    return _decode(response)['auto_allow_group_join'] == true;
  }

  /// BUG2 群二维码：签发入群令牌（群主/管理员；返回 `changliao://g/<token>`）。
  Future<Map<String, dynamic>> issueGroupJoinToken({required String roomId}) =>
      postJson('/groups/$roomId/join-tokens', const {},
          idempotencyKey: newIdempotencyKey());

  /// 扫码后的安全群摘要（不返回 room_id/令牌明文）。
  Future<Map<String, dynamic>> groupJoinInfo({required String token}) =>
      getJson('/groups/join-info?token=${Uri.encodeQueryComponent(token)}');

  /// 兑换令牌入群（直加或转审批，服务端校验）。
  Future<Map<String, dynamic>> redeemGroupJoinToken({required String token}) =>
      postJson('/groups/join-tokens/redeem', {'token': token},
          idempotencyKey: newIdempotencyKey());

  /// 撤销令牌（轮换 = 新签发 + 撤销旧）。
  Future<Map<String, dynamic>> revokeGroupJoinToken({required String token}) =>
      postJson('/groups/join-tokens/${Uri.encodeQueryComponent(token)}/revoke',
          const {},
          idempotencyKey: newIdempotencyKey());

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

  Future<Map<String, dynamic>> friendRequests() => getJson('/friends/requests');
  @override
  Future<Map<String, dynamic>> submitComplaint(
          {required String category, required String description}) =>
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
  Future<Map<String, dynamic>> createContactTag(String name) =>
      postJson('/contact-tags', {'name': name},
          idempotencyKey: newIdempotencyKey());
  @override
  Future<Map<String, dynamic>> renameContactTag(String id, String name) =>
      patchJson('/contact-tags/$id', {'name': name},
          idempotencyKey: newIdempotencyKey());
  @override
  Future<void> deleteContactTag(String id) async {
    final response = await _authorized((headers) => _client.delete(
          _uri('/contact-tags/$id'),
          headers: {...headers, 'Idempotency-Key': newIdempotencyKey()},
        ));
    if (response.statusCode >= 400) _decode(response);
  }

  @override
  Future<void> deleteContactTags(List<String> ids) async {
    final response = await _authorized((headers) => _client.delete(
          _uri('/contact-tags'),
          headers: {
            ...headers,
            'Idempotency-Key': newIdempotencyKey(),
            'Content-Type': 'application/json'
          },
          body: jsonEncode({'tag_ids': ids}),
        ));
    if (response.statusCode >= 400) _decode(response);
  }

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

  @override
  Future<Map<String, dynamic>> searchUsers(String query) =>
      getJson('/users/search?q=${Uri.encodeQueryComponent(query)}');

  /// BUG 2 群成员非好友：按 Matrix ID 反查公开资料与关系状态。
  /// 不存在/拉黑/自己时服务端返回 404（抛 BusinessApiException）。
  Future<Map<String, dynamic>> lookupUserByMatrixId(String matrixUserId) =>
      getJson(
          '/users/lookup?matrix_user_id=${Uri.encodeQueryComponent(matrixUserId)}');

  @override
  Future<Map<String, dynamic>> requestFriend(String userId,
          {String message = '',
          String? remark,
          List<String> tags = const [],
          String momentsPermission = 'DEFAULT'}) =>
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
  Future<Map<String, dynamic>> acceptFriendRequest(String id) =>
      postJson('/friends/requests/$id/accept', {},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> rejectFriendRequest(String id) =>
      postJson('/friends/requests/$id/reject', {},
          idempotencyKey: newIdempotencyKey());

  /// Canonical Direct Conversation（好友系统重构 Phase E）：
  /// 创建私聊前先查询规范房间，存在即复用。
  Future<String?> canonicalDirectRoomId(String peerUserId) async {
    final body =
        await getJson('/direct-conversations?peer_user_id=$peerUserId');
    return body['matrix_room_id']?.toString();
  }

  /// 客户端创建 Matrix Direct Chat 后注册；并发冲突时服务端返回既有行。
  Future<String> registerDirectConversation(
      String peerUserId, String matrixRoomId) async {
    final body = await postJson('/direct-conversations',
        {'peer_user_id': peerUserId, 'matrix_room_id': matrixRoomId},
        idempotencyKey: newIdempotencyKey());
    return body['matrix_room_id']?.toString() ?? matrixRoomId;
  }

  /// BUG 2 状态机：申请人撤销待处理申请（PENDING → CANCELLED）。
  Future<Map<String, dynamic>> cancelFriendRequest(String id) async {
    final response = await _authorized((headers) => _client.delete(
        _uri('/friends/requests/$id'),
        headers: {...headers, 'Idempotency-Key': newIdempotencyKey()}));
    return _decode(response);
  }

  Future<Map<String, dynamic>> momentsFeed({String mode = 'recommended'}) =>
      getJson('/moments/feed?mode=$mode');
  Future<Map<String, dynamic>> searchMoments(String query) =>
      getJson('/moments/search?q=${Uri.encodeQueryComponent(query)}');
  Future<Map<String, dynamic>> publishMoment(
          {required String text,
          required String visibility,
          List<String> imageUrls = const [],
          List<String> includeUserIds = const [],
          List<String> excludeUserIds = const [],
          List<String> includeTagIds = const [],
          List<String> excludeTagIds = const [],
          String? linkUrl}) =>
      postJson(
          '/moments',
          {
            'text': text,
            'visibility': visibility,
            'image_urls': imageUrls,
            'include_user_ids': includeUserIds,
            'exclude_user_ids': excludeUserIds,
            'include_tag_ids': includeTagIds,
            'exclude_tag_ids': excludeTagIds,
            'link_url': linkUrl,
          },
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> likeMoment(String id) =>
      postJson('/moments/$id/likes', {}, idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> commentMoment(String id, String text) =>
      postJson('/moments/$id/comments', {'text': text},
          idempotencyKey: newIdempotencyKey());
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
  Future<Map<String, dynamic>> beginMomentUpload(
          {required String fileName,
          required String mimeType,
          required int byteSize}) =>
      postJson('/moments/media/uploads',
          {'file_name': fileName, 'mime_type': mimeType, 'byte_size': byteSize},
          idempotencyKey: newIdempotencyKey());
  Future<void> putMomentUpload(
      String uploadId, List<int> bytes, String mimeType) async {
    final response = await _authorized((headers) => _client.put(
        _uri('/moments/media/uploads/$uploadId/content'),
        headers: {...headers, 'Content-Type': mimeType},
        body: bytes));
    if (response.statusCode >= 400) _decode(response);
  }

  Future<Map<String, dynamic>> completeMomentUpload(String uploadId) =>
      postJson('/moments/media/uploads/$uploadId/complete', {},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> beginMomentCoverUpload(
          {required String fileName,
          required String mimeType,
          required int byteSize}) =>
      postJson('/moments/cover/uploads',
          {'file_name': fileName, 'mime_type': mimeType, 'byte_size': byteSize},
          idempotencyKey: newIdempotencyKey());
  Future<void> putMomentCoverUpload(
      String uploadId, List<int> bytes, String mimeType) async {
    final response = await _authorized((headers) => _client.put(
        _uri('/moments/cover/uploads/$uploadId/content'),
        headers: {...headers, 'Content-Type': mimeType},
        body: bytes));
    if (response.statusCode >= 400) _decode(response);
  }

  Future<Map<String, dynamic>> completeMomentCoverUpload(String uploadId) =>
      postJson('/moments/cover/uploads/$uploadId/complete', {},
          idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> setMomentCover(String uploadId) => putJson(
        '/moments/cover',
        {'upload_id': uploadId},
        idempotencyKey: newIdempotencyKey(),
      );
  Future<Map<String, dynamic>> personalMoments(String userId) =>
      getJson('/moments/users/$userId');
  Future<Map<String, dynamic>> momentNotifications() =>
      getJson('/moments/notifications');
  Future<Map<String, dynamic>> momentUnreadCount() =>
      getJson('/moments/notifications/unread-count');
  Future<void> markMomentNotificationsRead(List<String> ids) async {
    await postJson('/moments/notifications/read', {'ids': ids},
        idempotencyKey: newIdempotencyKey());
  }

  Future<Map<String, dynamic>> momentsPreferences() =>
      getJson('/moments/preferences');
  Future<Map<String, dynamic>> updateMomentsPreferences(
          {required String historyRange,
          required bool personalized,
          String? coverUrl}) =>
      putJson('/moments/preferences', {
        'history_range': historyRange,
        'personalized_recommendations': personalized,
        if (coverUrl != null) 'cover_url': coverUrl
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

  Future<void> deleteJson(String path) async {
    final response = await _authorized((headers) => _client.delete(_uri(path),
        headers: {...headers, 'Idempotency-Key': newIdempotencyKey()}));
    if (response.statusCode == 204) return;
    _decode(response);
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

  Future<Map<String, dynamic>> putJson(String path, Map<String, dynamic> body,
      {String? idempotencyKey}) async {
    final response = await _authorized((headers) => _client.put(_uri(path),
        headers: {
          ...headers,
          'Content-Type': 'application/json',
          if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
        },
        body: jsonEncode(body)));
    return _decode(response);
  }

  static const _httpTimeout = Duration(seconds: 8);

  /// debug 模式请求观测：只记录 method/URL/HTTP 状态/错误类型，
  /// 绝不输出 header、body、token、密码或完整邀请码。
  void _logRequest(String method, Uri? url, Object outcome) {
    if (!kDebugMode) return;
    debugPrint('[api] $method ${url?.path ?? ''} -> $outcome');
  }

  Future<http.Response> _authorized(
    Future<http.Response> Function(Map<String, String>) operation, {
    Duration timeout = _httpTimeout,
  }) async {
    final initial = await sessionStore.session();
    final requestUrl = _lastRequestUrl;
    http.Response response;
    try {
      response = await operation({
        if (initial != null) 'Authorization': 'Bearer ${initial.accessToken}'
      }).timeout(timeout);
    } catch (error) {
      _logRequest('REQUEST', requestUrl, 'ERROR:${error.runtimeType}');
      rethrow;
    }
    if (response.statusCode >= 400) {
      _logRequest('REQUEST', requestUrl, 'HTTP ${response.statusCode}');
    }
    if (response.statusCode != 401 || initial == null) return response;
    final replacement = await refreshSession();
    return operation({'Authorization': 'Bearer ${replacement.accessToken}'});
  }

  Uri? _lastRequestUrl;

  Map<String, dynamic> _decode(http.Response response) {
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw BusinessApiException(
        statusCode: response.statusCode,
        code: body['error']?['code']?.toString() ?? 'BUSINESS_REQUEST_FAILED',
        message: body['error']?['message']?.toString() ?? '业务请求失败',
        fieldErrors: _parseFieldErrors(body['error']?['fields']),
      );
    }
    return body;
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
