import 'conversation_identity_admission.dart';
import 'logical_conversation_timeline.dart';
import 'matrix_room_display_name.dart' as room_names;
import 'matrix_outgoing_work_coordinator.dart';
import 'conversation_identity_resolver.dart';
import 'conversation_read_state.dart';
import 'direct_room_directory_convergence.dart';
import 'duplicate_room_registry.dart';
export 'matrix_room_timeline_adapter.dart' show changliaoRedPacketMessageType;
import 'call_diagnostics.dart';
import 'call_wakeup_client.dart';
import 'matrix_sync_watchdog.dart';
import 'matrix_notification_event_source.dart';
import '../push/matrix_pusher_service.dart';
import '../contacts/user_display_name_resolver.dart';
import '../../core/notification/badge_service.dart';
import '../../core/notification/notification_coordinator.dart';
import 'group_invitation_auto_join.dart';
import 'direct_invitation_auto_join.dart';
import 'dart:convert';
import 'dart:io';
import 'emoji_preview_cache.dart';
import 'group_room_authority.dart';
import 'group_announcement_service.dart';
import 'group_join_notices.dart';
import 'dart:async';
import 'media_cache.dart';
import 'media_index.dart' show MediaVariantKind;
import 'local_hidden_events.dart';
import 'video_transcode.dart'
    show
        validateGroupVideoSize,
        maxOriginalVideoBytes,
        GroupVideoTooLargeException;
import 'prepared_chat_video.dart';
import 'media_thumbnail.dart' show decodeImageDimensions;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:flutter/foundation.dart';
import '../auth/login_controller.dart' hide LoginState;
import 'avatar_url_resolver.dart';
import 'conversation_preferences.dart';
import 'matrix_control_rooms.dart';
import 'direct_chat_controller.dart';
import '../../core/network_state_manager.dart'
    show
        MessageSendNetworkException,
        networkFailureHttpStatus,
        defaultNetworkFailureClassifier;
import '../../core/chat_diagnostics.dart';
import 'decryption_state_controller.dart';
import 'emoji_vault.dart';
import 'group_chat_controller.dart';
import 'group_chat_info_controller.dart';
import 'matrix_direct_chat_adapter.dart';
import 'matrix_group_chat_adapter.dart';
import 'matrix_media_file.dart';
import 'content_addressed_media.dart';
import 'outgoing_media_thumbnail_cache.dart';
import 'room_mention_store.dart';
import 'unread_mention_tracker.dart';
import 'matrix_call_adapter.dart' hide changliaoCallMessageType;
import 'matrix_emoji_vault.dart';
import 'matrix_message_reminder_backend.dart';
import 'matrix_room_timeline_adapter.dart';
import 'room_history_date_capability.dart';
import 'room_history_day_index.dart';
import 'room_history_day_index_store.dart';
import 'room_timeline_viewport.dart';
import 'matrix_recovery_service.dart';
import 'matrix_security_logger.dart';
import 'matrix_user_avatar.dart';
import 'message_interaction_service.dart';
import 'message_timeline_cache.dart';
import 'nudge_service.dart';
import 'room_timeline_controller.dart';
import '../search/local_message_search_repository.dart';
import '../../ui/chat/flash_photo.dart' show FlashPhotoViewedStore;

const _maxFileSendBytes = 100 * 1024 * 1024;
const _maxOutgoingVideoPosterBytes = 512 * 1024;
const _maxOutgoingVideoReservationBytes =
    maxOriginalVideoBytes + _maxOutgoingVideoPosterBytes;

/// Matrix is the encrypted communications domain. This interface never sends message plaintext or recovery keys to the business API.
abstract interface class MatrixSessionGateway {
  bool get isLoggedIn;
  String? get userId;
  String? get deviceId;
  Future<void> sync();
  Future<void> suspend();
  Future<void> clearLocalChatData();
}

abstract interface class MatrixE2eeClient
    implements
        MatrixSessionGateway,
        MatrixEncryptedMediaGateway,
        DirectChatGateway,
        GroupChatGateway {
  Future<void> login(String userId, String password);
  Future<void> verifyDevice(String deviceId);
  Future<void> backupKeysToEncryptedStore();
  Future<void> initializeCrossSigning({required String recoveryKey});
  Future<void> restoreEncryptedBackup({required String recoveryKey});
  Future<String> sendEncryptedText(String roomId, String plaintext);
}

abstract interface class MatrixRecoveryClient {
  Future<void> unlockSecretStorage(String recoveryKey);
  Future<void> restoreAllInboundSessions();
  Future<bool> backupKeyMatchesCurrentVersion();
  Future<void> uploadPendingInboundSessions();
}

abstract interface class MatrixEncryptedMediaGateway {
  /// The SDK encrypts these local plaintext bytes during upload whenever the
  /// target room is encrypted. Callers must never forward them to business APIs.
  ///
  /// [thumbnailBytes]（可选）为发送端本地生成的压缩演绎版/封面帧（如
  /// media_thumbnail 的 ≤800px/≤100KB 缩略图或视频海报）。SDK 会将其
  /// 一并加密上传并写入事件的 info.thumbnail_file，接收端无需下载完整
  /// 附件即可渲染预览——服务端始终只接触密文。
  Future<String> sendEncryptedMedia(
      String roomId, List<int> plaintext, String mimeType,
      {Map<String, dynamic>? extraContent,
      String? txid,
      String? filename,
      Uint8List? thumbnailBytes,
      int? thumbnailWidth,
      int? thumbnailHeight});
}

/// Read-only progress surface room UIs may observe for queued outgoing work
/// (forwards/prepared media). Never exposes plaintext payloads.
abstract interface class MatrixOutgoingProgressView {
  Listenable get outgoingProgress;
}

/// BUG-35：单房间视频发送工作投影（转码/上传/失败，见协调器同名方法）。
abstract interface class MatrixOutgoingVideoWorkView {
  MatrixRoomVideoWorkSummary videoWorkSummaryForRoom(String roomId);
}

@immutable
final class MatrixClientContinuityMetadata {
  const MatrixClientContinuityMetadata({
    required this.isLoggedIn,
    required this.userId,
    required this.deviceId,
    required this.ed25519Fingerprint,
    required this.databaseGeneration,
  });

  final bool isLoggedIn;
  final String? userId;
  final String? deviceId;
  final String? ed25519Fingerprint;
  final String databaseGeneration;

  /// 真正的连续性锚点是 Matrix 用户、Olm(Ed25519) fingerprint 与本地库代号。
  ///
  /// `deviceId` 不参与比较：它只是服务端设备标签，单设备登录策略会随时轮换它。
  /// 把它算作身份会让一次可恢复的权威轮换被误判成"恢复出另一个身份"，
  /// 从而让 resume 永久失败（L04），并让后续账号切换卡在 account_storage（L07）。
  /// 任何真正的密码学身份变化（用户、fingerprint、库代号）仍然会被拒绝。
  bool hasSameContinuity(MatrixClientContinuityMetadata other) =>
      userId == other.userId &&
      ed25519Fingerprint == other.ed25519Fingerprint &&
      databaseGeneration == other.databaseGeneration;
}

/// 采纳一次经过服务端 token 登录证明的 device id 轮换。
typedef MatrixDeviceRotation = Future<void> Function(
  Client client, {
  required String expectedUserId,
  required String previousDeviceId,
  required String nextDeviceId,
});

/// 上次挂起之后本地库的连续性判定结果。
///
/// 关闭安全与连续性信任必须分开：client 可以（也必须）已安全关闭，同时连续性
/// 处于 [unknown]。任何调用方都不得把 [unknown] 当作已验证。
enum MatrixSuspendedContinuity {
  /// 当前没有已挂起的 client。
  none,

  /// 连续性已验证，可以安全 resume。
  validated,

  /// 已安全关闭，但连续性无法验证：不得据此认为会话可信。
  unknown,
}

abstract interface class MatrixManagedSubscription {
  Future<void> cancel();
}

abstract interface class MatrixManagedResource {
  Future<void> cancel();
}

abstract interface class MatrixSasRequestHandle {
  Future<void> accept();
  Future<void> continueSas();
  Future<void> confirmSas();
  Future<void> reject();
  void dispose();
}

final class _SdkSasRequestHandle implements MatrixSasRequestHandle {
  _SdkSasRequestHandle(this.request);
  final KeyVerification request;

  @override
  Future<void> accept() => request.acceptVerification();
  @override
  Future<void> continueSas() => request.continueVerification(EventTypes.Sas);
  @override
  Future<void> confirmSas() => request.acceptSas();
  @override
  Future<void> reject() => request.rejectVerification();
  @override
  void dispose() => request.dispose();
}

final class _TrackedSasRequestHandle implements MatrixSasRequestHandle {
  _TrackedSasRequestHandle(this._owner, this._delegate);
  final MatrixSdkE2eeClient _owner;
  final MatrixSasRequestHandle _delegate;

  @override
  Future<void> accept() => _owner._withClient((_) => _delegate.accept());
  @override
  Future<void> continueSas() =>
      _owner._withClient((_) => _delegate.continueSas());
  @override
  Future<void> confirmSas() =>
      _owner._withClient((_) => _delegate.confirmSas());
  @override
  Future<void> reject() => _owner._withClient((_) => _delegate.reject());
  @override
  void dispose() => _delegate.dispose();
}

/// Restricted resources AppHome may create from the active Matrix session.
/// The raw SDK client is never exposed to the widget layer.
abstract interface class MatrixAppHomeCapability {
  MatrixCallBackend createCallBackend(
      {CallDiagnostics? diagnostics, CallWakeupClient? wakeup});
  CallWakeupClient createCallWakeupClient(Uri baseUrl);
  SyncWatchdogTarget createSyncWatchdogTarget();
  MatrixPusherGateway createPusherGateway();
  ManagedMatrixNotificationEventSource createNotificationEventSource(
      {UserDisplayNameResolver? displayNameResolver});
  UnreadSnapshotSource createUnreadSnapshotSource();

  /// Task B：本机已有历史的只读搜索来源。
  ///
  /// 只读取**本机 SQLCipher 加密库中已经存在且已解密**的事件，绝不触发
  /// `/messages` 分页或任何网络请求；返回的是用户可见文本正文（闪照/媒体
  /// 永不进入）。
  LocalHistorySearchSource createLocalHistorySearchSource();

  /// 本机加密库中某房间的最近事件（只读、无网络分页）。
  Future<List<Event>> readLocalRoomEvents(String roomId, {required int limit});

  /// 本机会话已知的房间 id（仅本地状态，无网络）。
  List<String> localSearchRoomIds({int? maxRooms});

  /// 某 Matrix 用户的头像 `mxc://`（只读本地 SDK 状态，无网络）。
  Uri? matrixAvatarUriFor(String matrixUserId);
  Future<MatrixMessageReminderBackend> openMessageReminderBackend();
}

final class _SdkAppHomeCapability implements MatrixAppHomeCapability {
  _SdkAppHomeCapability(this._owner, this._client);
  final MatrixSdkE2eeClient _owner;
  final Client _client;
  bool _revoked = false;
  bool _opening = true;

  void revoke() => _revoked = true;

  void _ensureActive() {
    if (_revoked || (!_opening && !identical(_owner._client, _client))) {
      throw StateError('Matrix home capability is revoked');
    }
  }

  @override
  MatrixCallBackend createCallBackend(
      {CallDiagnostics? diagnostics, CallWakeupClient? wakeup}) {
    _ensureActive();
    return MatrixCallBackend(
      _client,
      diagnostics: diagnostics,
      wakeup: wakeup,
      ensureActive: () {
        _ensureActive();
        if (!identical(_owner._client, _client)) {
          throw StateError('Matrix home capability belongs to an old session');
        }
      },
    );
  }

  Future<T> _execute<T>(Future<T> Function(Client client) action) {
    _ensureActive();
    // Resource attachment already owns the lifecycle queue. Its awaited work
    // must use that admission rather than enqueue behind itself.
    if (_opening) return action(_client);
    return _owner._withClient((active) async {
      _ensureActive();
      if (!identical(active, _client)) {
        throw StateError('Matrix home capability belongs to an old session');
      }
      return action(active);
    });
  }

  @override
  CallWakeupClient createCallWakeupClient(Uri baseUrl) {
    _ensureActive();
    return CallWakeupClient(
        baseUrl: baseUrl,
        accessToken: () {
          _ensureActive();
          return _client.accessToken;
        });
  }

  @override
  SyncWatchdogTarget createSyncWatchdogTarget() {
    _ensureActive();
    return _ManagedSyncWatchdogTarget(this);
  }

  @override
  MatrixPusherGateway createPusherGateway() {
    _ensureActive();
    return _ManagedPusherGateway(this);
  }

  @override
  ManagedMatrixNotificationEventSource createNotificationEventSource(
      {UserDisplayNameResolver? displayNameResolver}) {
    _ensureActive();
    return _ManagedNotificationEventSource(
        this,
        MatrixNotificationEventSource(
            client: _client, displayNameResolver: displayNameResolver));
  }

  @override
  UnreadSnapshotSource createUnreadSnapshotSource() {
    _ensureActive();
    return _ManagedUnreadSource(this);
  }

  @override
  LocalHistorySearchSource createLocalHistorySearchSource() {
    _ensureActive();
    return MatrixLocalHistorySearchSource(owner: this);
  }

  @override
  Future<List<Event>> readLocalRoomEvents(String roomId,
      {required int limit}) async {
    _ensureActive();
    if (limit <= 0) return const [];
    final room = _client.getRoomById(roomId);
    if (room == null) return const [];
    final database = _client.database;
    if (database == null) return const [];
    // Local, read-only: reads events already stored in the SQLCipher DB.
    // Never paginates and never performs a network request.
    return database.getEventList(room, limit: limit);
  }

  @override
  List<String> localSearchRoomIds({int? maxRooms}) {
    _ensureActive();
    final rooms =
        _client.rooms.where((room) => room.membership == Membership.join);
    return [
      for (final room in maxRooms == null ? rooms : rooms.take(maxRooms))
        room.id,
    ];
  }

  @override
  Uri? matrixAvatarUriFor(String matrixUserId) {
    _ensureActive();
    if (matrixUserId.isEmpty) return null;
    try {
      for (final room in _client.rooms) {
        final members = room.getParticipants([Membership.join]);
        if (!members.any((member) => member.id == matrixUserId)) continue;
        // 只读本地 SDK 状态（unsafeGetUserFromMemoryOrFallback 不会发网络请求）。
        final avatar =
            room.unsafeGetUserFromMemoryOrFallback(matrixUserId).avatarUrl;
        if (avatar != null) return avatar;
      }
      return null;
    } catch (_) {
      // 未同步到该用户资料：回退到首字头像，绝不影响通话建立。
      return null;
    }
  }

  @override
  Future<MatrixMessageReminderBackend> openMessageReminderBackend() async {
    _ensureActive();
    late MatrixMessageReminderBackend backend;
    await _execute((active) async {
      _ensureActive();
      if (!identical(active, _client)) {
        throw StateError('Matrix home capability belongs to an old session');
      }
      backend = await MatrixMessageReminderBackend.open(
        active,
        ensureActive: () {
          _ensureActive();
          if (!identical(_owner._client, _client)) {
            throw StateError(
              'Matrix home capability belongs to an old session',
            );
          }
        },
      );
    });
    return backend;
  }
}

abstract interface class ManagedMatrixNotificationEventSource
    implements NotificationEventSource {
  Future<void> start();
  Future<void> stop();
}

final class _ManagedNotificationEventSource
    implements ManagedMatrixNotificationEventSource {
  _ManagedNotificationEventSource(this._capability, this._source);
  final _SdkAppHomeCapability _capability;
  final MatrixNotificationEventSource _source;
  @override
  Stream<IncomingNotification> get events => _source.events.where((_) =>
      !_capability._revoked &&
      identical(_capability._owner._client, _capability._client));
  @override
  Future<void> start() => _capability._execute((_) => _source.start());
  @override
  Future<void> stop() => _source.stop();
}

final class _ManagedUnreadSource implements UnreadSnapshotSource {
  _ManagedUnreadSource(this._capability);
  final _SdkAppHomeCapability _capability;
  @override
  Future<List<ConversationUnreadSnapshot>> load() => _capability
      ._execute((client) => MatrixUnreadSnapshotSource(client: client).load());
}

final class _ManagedPusherGateway implements MatrixPusherGateway {
  _ManagedPusherGateway(this._capability);
  final _SdkAppHomeCapability _capability;
  final Set<String> _created = {};
  String _id(PusherId value) =>
      '${value.appId.length}:${value.appId}${value.pushkey}';
  @override
  Future<void> create(Pusher value) => _capability._execute((client) async {
        await client.postPusher(value);
        _created.add(_id(value));
      });
  @override
  Future<void> delete(PusherId id) async {
    if (!_capability._revoked) {
      await _capability._execute((client) => client.deletePusher(id));
    } else {
      // Session shutdown already owns the lifecycle queue. Only revoke an
      // identity created by this handle, on its captured original session.
      if (!_created.contains(_id(id))) {
        throw StateError('Unknown pusher cleanup identity');
      }
      await _capability._client
          .deletePusher(id)
          .timeout(const Duration(seconds: 10));
    }
    _created.remove(_id(id));
  }
}

final class _ManagedSyncWatchdogTarget implements SyncWatchdogTarget {
  _ManagedSyncWatchdogTarget(this._capability);
  final _SdkAppHomeCapability _capability;
  @override
  Stream<SyncStatusUpdate> get syncStatus {
    _capability._ensureActive();
    return _capability._client.onSyncStatus.stream
        .where((_) => !_capability._revoked);
  }

  @override
  Future<void> oneShotSync() =>
      _capability._execute((client) => client.oneShotSync());
  @override
  Future<void> abortSync() =>
      _capability._execute((client) => client.abortSync());
  @override
  set backgroundSync(bool enabled) {
    _capability._ensureActive();
    _capability._client.backgroundSync = enabled;
  }
}

final class MatrixGroupInviteSnapshot {
  const MatrixGroupInviteSnapshot({required this.id, required this.name});
  final String id;
  final String name;
}

enum MatrixConversationMutation {
  markUnread,
  clearUnread,
  togglePin,
  hide,
  delete
}

@immutable
final class MatrixMemberSnapshot {
  const MatrixMemberSnapshot({
    required this.id,
    required this.displayName,
    required this.avatar,
  });
  final String id;
  final String displayName;
  final Uri? avatar;
}

@immutable
final class MatrixEventSnapshot {
  const MatrixEventSnapshot({
    required this.type,
    required this.text,
    required this.body,
    required this.originServerTs,
    required this.senderId,
    required this.sender,
    required this.redacted,
    this.eventId = '',
    this.messageType = '',
    this.content = const {},
    this.decryptionState = MessageDecryptionState.decrypted,
  });
  final String type;
  final String text;
  final String body;
  final DateTime originServerTs;
  final String senderId;
  final MatrixMemberSnapshot sender;
  final bool redacted;
  final String eventId;
  final String messageType;
  final Map<String, Object?> content;
  final MessageDecryptionState decryptionState;
}

@immutable
final class MatrixConversationRoomSnapshot {
  MatrixConversationRoomSnapshot({
    required String id,
    required String displayName,
    required Uri? avatar,
    required bool isDirect,
    required String? directPeerId,
    required List<MatrixMemberSnapshot> members,
    required MatrixEventSnapshot? lastEvent,
    required ConversationPreference preference,
    required int notificationCount,
    required bool notificationsEnabled,
    String name = '',
    bool isJoined = true,
    DateTime? lastActivityAt,
    int duplicateUnreadCount = 0,
  }) : this._trusted(
            id: id,
            displayName: displayName,
            avatar: avatar,
            isDirect: isDirect,
            directPeerId: directPeerId,
            members: List.unmodifiable(members),
            lastEvent: lastEvent,
            preference: preference,
            notificationCount: notificationCount,
            notificationsEnabled: notificationsEnabled,
            name: name,
            isJoined: isJoined,
            lastActivityAt: lastActivityAt,
            duplicateUnreadCount: duplicateUnreadCount);

  const MatrixConversationRoomSnapshot._trusted({
    required this.id,
    required this.displayName,
    required this.avatar,
    required this.isDirect,
    required this.directPeerId,
    required this.members,
    required this.lastEvent,
    required this.preference,
    required this.notificationCount,
    required this.notificationsEnabled,
    required this.name,
    required this.isJoined,
    this.lastActivityAt,
    this.duplicateUnreadCount = 0,
  });
  final String id;
  final String displayName;
  final Uri? avatar;
  final bool isDirect;
  final String? directPeerId;
  final List<MatrixMemberSnapshot> members;
  final MatrixEventSnapshot? lastEvent;
  final ConversationPreference preference;
  final int notificationCount;
  final bool notificationsEnabled;
  final bool isJoined;
  final String name;

  /// 「消息」页排序锚点：可见的最后事件时间；当最后一条事件被「清空聊天记录」
  /// 隐藏时沿用**清空前**的最后活动时间，使该会话在列表中原地不动，而不是
  /// 因为缺少可见事件被排到末尾（用户报的位置变化）。
  final DateTime? lastActivityAt;

  /// 身份解析落选房间（同好友重复房间）并入本行的未读数（方案 A）。
  /// 落选房间不渲染行，其未读不能凭空消失；显示时由 UI 层加到总未读上。
  final int duplicateUnreadCount;
}

@immutable
final class MatrixConversationSnapshot {
  MatrixConversationSnapshot({
    required this.vaultRoomId,
    required this.reminderRoomId,
    required List<MatrixConversationRoomSnapshot> rooms,
    this.unresolvedRoomCount = 0,
  }) : rooms = List.unmodifiable(rooms);
  final String? vaultRoomId;
  final String? reminderRoomId;
  final List<MatrixConversationRoomSnapshot> rooms;

  /// Rooms retained locally while their conversation identity is restored.
  final int unresolvedRoomCount;
}

final class MatrixConversationCapability {
  const MatrixConversationCapability._(this._owner);
  final MatrixSdkE2eeClient _owner;

  Future<void> _savePreference(
      Room room, ConversationPreference preference) async {
    await saveLocalConversationPreference(room, preference);
    _flushPreferences();
  }

  void _flushPreferences() {
    unawaited(_owner
        ._withClient((client) => flushConversationPreferences(client,
            shouldContinue: () => !_owner._accessRevoked))
        .catchError((_) {}));
  }

  Future<void> clearAllUnread() => _owner._withClient((client) async {
        await loadConversationPreferences(client);
        final rooms = client.rooms
            .where((room) => room.membership == Membership.join)
            .toList();
        for (final room in rooms) {
          ConversationReadState.shared()
              .markCleared(room.id, eventId: room.lastEvent?.eventId);
          if (preferenceForRoom(room).manualUnread) {
            await saveLocalConversationPreference(
                room, clearUnreadOnOpen(preferenceForRoom(room)));
          }
        }
        conversationPreferencesChanged.publish();
        _flushPreferences();
        for (final room in rooms) {
          final eventId = room.lastEvent?.eventId;
          if (eventId == null) continue;
          unawaited(_owner._withClient((active) async {
            final activeRoom = active.getRoomById(room.id);
            await activeRoom?.setReadMarker(eventId,
                mRead: eventId, public: false);
          }).catchError((_) {}));
        }
      });

  Future<void> reconcileMetadata() => _owner._withClient((client) async {
        await loadConversationPreferences(client);
        final base = DateTime.now().toUtc();
        var offset = 0;
        for (final room in client.rooms) {
          final preference = preferenceForRoom(room);
          final memberOrder = room.isDirectChat
              ? preference.memberOrderIds
              : reconcileMemberOrder(
                  preference.memberOrderIds,
                  room.getParticipants([Membership.join]).map(
                      (member) => member.id),
                );
          final needsPinTime = preference.pinned && preference.pinnedAt == null;
          final orderChanged = memberOrder.join('\u0000') !=
              preference.memberOrderIds.join('\u0000');
          if (!needsPinTime && !orderChanged) continue;
          try {
            await _savePreference(
              room,
              preference.copyWith(
                pinnedAt: needsPinTime
                    ? base.add(Duration(microseconds: offset++))
                    : preference.pinnedAt,
                memberOrderIds: memberOrder,
              ),
            );
          } catch (_) {
            // A later Matrix sync retries reconciliation.
          }
        }
      });

  Future<void> restoreHidden() => _owner._withClient((client) async {
        await loadConversationPreferences(client);
        final currentUserId = client.userID;
        for (final room in client.rooms) {
          final preference = preferenceForRoom(room);
          final event = room.lastEvent;
          if (!preference.hidden || event == null) continue;
          final restored = restoreForIncomingEvent(
            preference,
            eventAt: event.originServerTs,
            isIncoming: event.senderId != currentUserId,
          );
          if (!restored.hidden) {
            await _savePreference(room, restored);
          }
        }
      });

  Future<MatrixConversationSnapshot> snapshot() =>
      _owner._withClient((client) async {
        final snapshotAccount = client.userID;
        await reconcileConversationPreferences(client);
        _flushPreferences();
        final localHistory = client.userID == null
            ? null
            : await _owner._loadLocalHistory(client);
        _owner._memberProjectionCache.prune({
          for (final room in client.rooms)
            if (room.membership == Membership.join) room.id,
        });
        final selfUserId = client.userID;
        final registry = _owner._duplicateRooms;
        if (selfUserId != null && registry != null) {
          await loadDirectRoomAssociations(client, registry);
        }
        if (client.userID != snapshotAccount) {
          throw StateError('Conversation snapshot account changed');
        }
        final admitted = <MatrixConversationRoomSnapshot>[];
        final observed = <String, String>{};
        final snapshotRooms = client.rooms.toList(growable: false);
        final controlRooms = {
          client.accountData[emojiVaultAccountDataType]?.content['room_id'],
          client
              .accountData[messageReminderAccountDataType]?.content['room_id'],
        };
        for (final room in snapshotRooms) {
          if (room.membership != Membership.join) continue;
          var identity = selfUserId == null || registry == null
              ? null
              : admitConversationIdentity(room, selfUserId, registry);
          if (identity == null &&
              room.partial &&
              selfUserId != null &&
              registry != null) {
            // SDK custom state is lazy. Hydrate only its local database, never
            // wait on /state or /members to render established conversations.
            await room.postLoad();
            if (client.userID != snapshotAccount) {
              throw StateError('Conversation snapshot account changed');
            }
            identity = admitConversationIdentity(room, selfUserId, registry);
          }
          if (identity == null &&
              selfUserId != null &&
              registry != null &&
              (room.summary.mJoinedMemberCount ?? 0) >= 3 &&
              !room.participantListComplete) {
            // postLoad does not hydrate the SDK's separate member table.
            // Reading it is local-only, including after partial becomes false.
            List<User> stored;
            try {
              stored = await client.database?.getUsers(room) ?? const [];
            } catch (_) {
              stored = const [];
            }
            if (client.userID != snapshotAccount) {
              throw StateError('Conversation snapshot account changed');
            }
            for (final member in stored) {
              if (room.getState(EventTypes.RoomMember, member.id) == null) {
                room.setState(member);
              }
            }
            identity = admitConversationIdentity(room, selfUserId, registry);
          }
          if (identity != null) observed[room.id] = identity;
        }
        if (registry != null && selfUserId != null) {
          await registry.rememberLocalIdentities(selfUserId, observed);
        }
        if (client.userID != snapshotAccount) {
          throw StateError('Conversation snapshot account changed');
        }
        var unresolved = 0;
        // No awaits from this point: current evidence and the projected row
        // must be from the same sync state, not a pre-hydration observation.
        for (final room in snapshotRooms) {
          if (room.membership != Membership.join) continue;
          final identity = selfUserId == null || registry == null
              ? null
              : admitConversationIdentity(room, selfUserId, registry);
          if (identity == null && !controlRooms.contains(room.id)) {
            unresolved++;
            continue;
          }
          admitted.add(_reassociateDuplicate(
              _snapshotRoom(room, localHistory), registry, selfUserId,
              admittedIdentity: identity));
        }
        // 身份解析（同一好友一行）在数据源出口统一执行：m.direct 中同一
        // peer 的多个已加入房间（历史房间/旧版本建房/avoidRoomId 新建残留）
        // 不再各自渲染一条。落选房间仅从列表隐藏，绝不 leave。
        final resolution = resolveConversationIdentitiesDetailed(
          admitted,
          selfUserId: selfUserId,
          // 规则一数据源：收敛服务登记的服务端 canonical（未注入登记簿时
          // 自动退回消息数/活跃度规则）。
          primaryRoomIdOf: (registry == null || selfUserId == null)
              ? null
              : (peer) => registry.primaryRoomIdForPeer(selfUserId, peer),
          // 规则二数据源：本会话已解密缓存条数（本地消息量的保守代理）。
          localMessageCountOf: (room) => _owner._decryptedEventCount(room.id),
        );
        // BUG-23 残余自愈：通话中进程被杀 → 重启后尾部是通话终态信令而
        // 服务器未读仍虚增（服务器只见 m.room.encrypted，无法区分信令）。
        // 快照观察到该组合即静默推进一次已读（详见 _healCallSignalingTails）。
        _healCallSignalingTails(
          client: client,
          rooms: {
            ...resolution.representatives,
            ...resolution.duplicatesByRepresentativeId.values
                .expand((rooms) => rooms),
          },
        );
        return MatrixConversationSnapshot(
          unresolvedRoomCount: unresolved,
          vaultRoomId: client
              .accountData[emojiVaultAccountDataType]?.content['room_id']
              ?.toString(),
          reminderRoomId: client
              .accountData[messageReminderAccountDataType]?.content['room_id']
              ?.toString(),
          // 方案 A：落选房间不渲染行，其未读并入主行，不能凭空消失；列表
          // 摘要取身份组内最新事件，落选房间的新消息不因隐藏而在预览中消失。
          rooms: [
            for (final room in resolution.representatives)
              _mergeDuplicateConversationState(
                  room,
                  resolution.duplicatesByRepresentativeId[room.id] ?? const [],
                  selfUserId)
          ],
        );
      });

  /// BUG-23 残余自愈去重：每个 (账号, 房间, 尾部事件) 只推进一次已读。
  // 类暴露 const 构造器，去重状态放静态（键含账号，进程级共享安全）。
  static final Set<String> _callTailHealedMarkers = {};
  static final Set<String> _callTailHealInFlight = {};

  /// invite/candidates/negotiate 不是通话终态——通话可能仍在进行；
  /// 其余 m.call.*（answer/hangup/reject 等）表示这通电话已经收尾。
  static bool _isTerminalCallSignalingType(String? type) {
    if (type == null || !type.startsWith('m.call.')) return false;
    const nonTerminal = {
      'm.call.invite',
      'm.call.candidates',
      'm.call.negotiate',
    };
    return !nonTerminal.contains(type);
  }

  /// 尾部事件为通话终态信令且仍有服务器未读 → 推进一次已读。
  ///
  /// E2EE 房间里信令加密后服务器只见 m.room.encrypted，未读计数被信令
  /// 虚增且服务器无法自行区分；通话页内的 onEnded → markRoomRead 已覆盖
  /// 正常路径，这里补上进程在通话中被杀、重启后不再进入通话页的场景。
  /// 手动未读（BUG-15）与查看中的房间不碰；失败允许下轮快照重试。
  /// 必须在 _withClient 的 client 上下文内调用（内联写入，不再排队）。
  void _healCallSignalingTails({
    required Client client,
    required Iterable<MatrixConversationRoomSnapshot> rooms,
  }) {
    for (final room in rooms) {
      final tail = room.lastEvent;
      if (tail == null || !_isTerminalCallSignalingType(tail.type)) continue;
      if (room.notificationCount <= 0) continue;
      if (room.preference.manualUnread) continue;
      if (ConversationReadState.shared().isRoomOpen(room.id)) continue;
      final key = '${client.userID}|${room.id}|${tail.eventId}';
      if (!_callTailHealedMarkers.add(key)) continue;
      if (!_callTailHealInFlight.add(key)) continue;
      final target = client.getRoomById(room.id);
      final tailEvent = target?.lastEvent;
      if (target == null || tailEvent == null) {
        _callTailHealedMarkers.remove(key);
        _callTailHealInFlight.remove(key);
        continue;
      }
      target
          .setReadMarker(tailEvent.eventId,
              mRead: tailEvent.eventId, public: false)
          .then(
            (_) {},
            onError: (_) => _callTailHealedMarkers.remove(key),
          )
          .whenComplete(() => _callTailHealInFlight.remove(key));
    }
  }

  /// 项2 修正：收敛把旧房间移出 m.direct 后，真实 SDK 计算的
  /// isDirectChat/directPeerId 会丢失——若不补救，旧房间会以"普通房间"
  /// 身份重新出现在列表里。这里用登记簿（duplicateRoomId→peerId）恢复其
  /// 私聊身份，再交给身份解析归并。纯展示投影，不改任何 Matrix 状态。
  MatrixConversationRoomSnapshot _reassociateDuplicate(
    MatrixConversationRoomSnapshot room,
    DuplicateRoomRegistry? registry,
    String? selfUserId, {
    String? admittedIdentity,
  }) {
    if (registry == null || selfUserId == null) return room;
    final isGroup = admittedIdentity == groupConversationIdentity;
    final peer = isGroup
        ? null
        : admittedIdentity ?? registry.peerIdForRoom(selfUserId, room.id);
    if ((!isGroup && (peer == null || peer.isEmpty)) ||
        (room.isDirect == !isGroup && room.directPeerId == peer)) {
      return room;
    }
    return MatrixConversationRoomSnapshot(
      id: room.id,
      displayName: room.displayName,
      avatar: room.avatar,
      isDirect: !isGroup,
      directPeerId: peer,
      members: room.members,
      lastEvent: room.lastEvent,
      preference: room.preference,
      notificationCount: room.notificationCount,
      notificationsEnabled: room.notificationsEnabled,
      name: room.name,
      isJoined: room.isJoined,
      lastActivityAt: room.lastActivityAt,
      duplicateUnreadCount: room.duplicateUnreadCount,
    );
  }

  /// 把落选房间的未读并入主行、列表摘要采用身份组内最新事件。
  MatrixConversationRoomSnapshot _mergeDuplicateConversationState(
    MatrixConversationRoomSnapshot primary,
    List<MatrixConversationRoomSnapshot> duplicates,
    String? selfUserId,
  ) {
    if (duplicates.isEmpty) return primary;
    var merged = 0;
    var newestEvent = primary.lastEvent;
    var newestAt = primary.lastActivityAt;
    for (final duplicate in duplicates) {
      merged += ConversationReadState.shared().unreadCount(
          roomId: duplicate.id,
          serverUnreadCount: duplicate.notificationCount,
          lastEventId: duplicate.lastEvent?.eventId,
          lastEventSenderId: duplicate.lastEvent?.senderId,
          currentUserId: selfUserId,
          manualUnread: duplicate.preference.manualUnread);
      final duplicateAt = duplicate.lastActivityAt;
      if (duplicateAt != null &&
          (newestAt == null || duplicateAt.isAfter(newestAt))) {
        newestAt = duplicateAt;
        newestEvent = duplicate.lastEvent;
      }
    }
    if (merged <= 0 && identical(newestEvent, primary.lastEvent)) {
      return primary;
    }
    return MatrixConversationRoomSnapshot(
      id: primary.id,
      displayName: primary.displayName,
      avatar: primary.avatar,
      isDirect: primary.isDirect,
      directPeerId: primary.directPeerId,
      members: primary.members,
      lastEvent: newestEvent,
      preference: primary.preference,
      notificationCount: primary.notificationCount,
      notificationsEnabled: primary.notificationsEnabled,
      name: primary.name,
      isJoined: primary.isJoined,
      lastActivityAt: newestAt,
      duplicateUnreadCount: merged,
    );
  }

  Future<void> refreshMembers() =>
      _owner._memberRefresh ??= _owner._withClient((client) async {
        _owner._memberRefreshPolicy.bindAccount(client.userID);
        final joinedGroupIds = <String>{};
        final rooms = <Room>[];
        for (final room in client.rooms) {
          if (room.membership != Membership.join || room.isDirectChat) {
            continue;
          }
          joinedGroupIds.add(room.id);
          if (_owner._memberRefreshPolicy.shouldRefresh(room.id)) {
            rooms.add(room);
          }
        }
        _owner._memberRefreshPolicy.prune(joinedGroupIds);
        var nextRoom = 0;
        Future<void> refreshNext() async {
          while (nextRoom < rooms.length) {
            final room = rooms[nextRoom++];
            final revision = _owner._memberRefreshPolicy.beginRefresh(room.id);
            try {
              await room.requestParticipants([Membership.join]);
              _owner._memberRefreshPolicy.markFresh(room.id, revision);
            } catch (_) {
              // Keep cached members offline and retry after a bounded delay.
              _owner._memberRefreshPolicy.markFailed(room.id, revision);
            }
          }
        }

        await Future.wait([
          for (var worker = 0; worker < 3 && worker < rooms.length; worker++)
            refreshNext(),
        ]);
      }).whenComplete(() => _owner._memberRefresh = null);
  Future<List<MatrixGroupInviteSnapshot>> pendingGroupInvites() =>
      _owner._withClient((client) async => [
            for (final room in client.rooms)
              if (room.membership == Membership.invite && !room.isDirectChat)
                MatrixGroupInviteSnapshot(
                    id: room.id, name: room_names.roomDisplayName(room))
          ]);
  Future<void> acceptGroupInvite(String id) =>
      _owner._withClient((client) async {
        await client.joinRoom(id);
        await client.oneShotSync();
      });
  Future<void> declineGroupInvite(String id) =>
      _owner._withClient((client) async {
        final room = client.getRoomById(id);
        if (room == null) return;
        await room.leave();
        await client.oneShotSync();
      });
  Future<GroupInvitationAutoJoinResult> autoJoinGroupInvites(
          Set<String> inFlight) =>
      _owner._withClient((client) async {
        final pending = [
          for (final room in client.rooms)
            if (room.membership == Membership.invite &&
                !room.isDirectChat &&
                !inFlight.contains(room.id))
              room.id
        ];
        inFlight.addAll(pending);
        try {
          final result = await autoJoinInvitedRoomIds(
              invitedRoomIds: pending, joinRoom: client.joinRoom);
          if (result.joinedRoomIds.isNotEmpty) await client.oneShotSync();
          return result;
        } finally {
          inFlight.removeAll(pending);
        }
      });
  Future<Set<String>> autoJoinDirectInvites(
          Set<String> friendMatrixIds, Set<String> inFlight) =>
      _owner._withClient((client) => autoJoinFriendDirectInvites(
          client: client,
          friendMatrixIds: friendMatrixIds,
          inFlight: inFlight));

  /// m.direct 目录收敛：同一 peer 的多个已加入房间重写为单条目（绝不
  /// leave/forget）。canonical 查询由调用方注入（业务 API 权威目录），
  /// [businessUserIdOf] 负责把 m.direct 键（matrixId）转换为业务 userId；
  /// 不可达时回退本地最新活跃规则；失败静默，下次 sync 重试。canonical
  /// 裁决的落选房间登记进 [DuplicateRoomRegistry]。
  Future<void> convergeDirectRoomDirectory(
          {Future<String?> Function(String peerBusinessUserId)?
              canonicalRoomIdOf,
          String? Function(String matrixPeerUserId)? businessUserIdOf,
          Future<DirectRoomAssociations?> Function(String peerBusinessUserId)?
              associationsOf,
          Future<void> Function(
                  String peerBusinessUserId, List<String> roomIds)?
              publishAssociations,
          void Function()? onChanged,
          Iterable<String> knownMatrixPeers = const <String>[]}) =>
      _owner._withClient((client) => convergeDirectDirectory(client,
          canonicalRoomIdOf: canonicalRoomIdOf,
          businessUserIdOf: businessUserIdOf,
          associationsOf: associationsOf,
          publishAssociations: publishAssociations,
          knownMatrixPeers: knownMatrixPeers,
          onChanged: onChanged,
          registry: _owner._duplicateRooms));
  Future<MatrixRoomInfoSnapshot> waitForJoinedRoom(String id) =>
      _owner._withClient((client) async {
        if (client.getRoomById(id)?.membership != Membership.join) {
          await client
              .waitForRoomInSync(id, join: true)
              .timeout(const Duration(seconds: 12));
        }
        final room = client.getRoomById(id);
        if (room == null || room.membership != Membership.join) {
          throw StateError('Matrix room is unavailable');
        }
        return _snapshotRoomInfo(room);
      });

  Future<String> roomDisplayName(String roomId) =>
      _owner._withClient((client) async {
        final room = client.getRoomById(roomId);
        if (room == null) throw StateError('Matrix room is unavailable');
        return room_names.roomDisplayName(room);
      });

  Future<int> totalUnreadCount() => _owner._withClient((client) async {
        await reconcileConversationPreferences(client);
        _flushPreferences();
        final localHistory = client.userID == null
            ? null
            : await _owner._loadLocalHistory(client);
        var count = 0;
        for (final room in client.rooms) {
          // 清空历史与删除会话都把该房间的未读视为已处理。
          final cutoff = localHistory?.lastHistoryCutoff(room.id);
          if (cutoff != null &&
              (room.lastEvent == null ||
                  !room.lastEvent!.originServerTs.isAfter(cutoff))) {
            continue;
          }
          final preference = preferenceForRoom(room);
          count += ConversationReadState.shared().unreadCount(
              roomId: room.id,
              serverUnreadCount: room.notificationCount,
              lastEventId: room.lastEvent?.eventId,
              lastEventSenderId: room.lastEvent?.senderId,
              currentUserId: client.userID,
              manualUnread: preference.manualUnread);
        }
        return count;
      });

  /// BUG-23：通话结束后把会话推进到最新已读（消除通话信令虚增的未读）。
  Future<void> markRoomRead(String roomId) =>
      _owner._withClient((client) async {
        final room = client.getRoomById(roomId);
        if (room == null) return;
        final lastEvent = room.lastEvent;
        if (lastEvent != null) {
          await room.setReadMarker(lastEvent.eventId,
              mRead: lastEvent.eventId, public: false);
        }
        await markReadOnOpen(roomId);
      });

  Future<void> markReadOnOpen(String roomId) =>
      _owner._withClient((client) async {
        final room = client.getRoomById(roomId);
        if (room == null) throw StateError('Matrix room is unavailable');
        await loadConversationPreferences(client);
        final preference = preferenceForRoom(room);
        if (!preference.manualUnread) return;
        try {
          await _savePreference(room, clearUnreadOnOpen(preference));
        } catch (_) {
          // A later sync retries the account-data write.
        }
      });

  Future<void> mutate(String roomId, MatrixConversationMutation mutation) =>
      _owner._withClient((client) async {
        final room = client.getRoomById(roomId);
        if (room == null) throw StateError('Matrix room is unavailable');
        await loadConversationPreferences(client);
        final preference = preferenceForRoom(room);
        switch (mutation) {
          case MatrixConversationMutation.markUnread:
            await _savePreference(room, markUnread(preference));
          case MatrixConversationMutation.clearUnread:
            // BUG-15：手动取消未读（清除 manualUnread 标记）。
            await _savePreference(room, clearUnreadOnOpen(preference));
          case MatrixConversationMutation.togglePin:
            final next = preference.pinned
                ? preference.copyWith(pinned: false, clearPinnedAt: true)
                : preference.copyWith(
                    pinned: true,
                    pinnedAt: DateTime.now().toUtc(),
                  );
            await _savePreference(room, next);
          case MatrixConversationMutation.hide:
            await _savePreference(
              room,
              hideConversation(preference, DateTime.now().toUtc()),
            );
          case MatrixConversationMutation.delete:
            final localHistory = await _owner._loadLocalHistory(client);
            final now = DateTime.now().toUtc();
            final lastEvent = room.lastEvent;
            final latest = lastEvent?.originServerTs;
            if (lastEvent != null) {
              await room.setReadMarker(lastEvent.eventId,
                  mRead: lastEvent.eventId, public: false);
            }
            if (preference.manualUnread) {
              await _savePreference(room, clearUnreadOnOpen(preference));
            }
            await localHistory.clearThrough(
                roomId, latest != null && latest.isAfter(now) ? latest : now);
            await RoomMentionStore.shared.clearForLocalHistory(room,
                boundaryEventId: room.lastEvent?.eventId,
                shouldContinue: () => !_owner._accessRevoked);
            _owner._decryptedTimelineEvents.removeWhere(
                (key, _) => key.$1 == client.userID && key.$2 == roomId);
        }
      });

  /// 「清空聊天记录」：清除本机历史，不改变会话本身的成员关系与可见性。
  ///
  /// 只写 [LocalHistoryClearance] 的截止时间。绝不能写 [LocalClearedHistory]
  /// 的截止时间——那是「删除该聊天」的删除信号，会让会话从消息列表消失。
  Future<void> clearLocalHistory(
    String roomId, {
    required Iterable<String> messageIds,
    required DateTime cutoff,
  }) =>
      _owner._withClient((client) async {
        final store = await _owner._loadLocalHistory(client);
        await store.clearHistoryThrough(roomId, cutoff);
        for (final eventId in messageIds) {
          await store.hide(roomId, eventId);
        }
      });

  MatrixConversationRoomSnapshot _snapshotRoom(
      Room room, SharedPreferencesLocalHiddenEvents? localHistory) {
    final preference = preferenceForRoom(room);
    final originalEvent = room.lastEvent;
    // 两个截止时间语义不同，不能混用：
    // - clearedThrough：「删除该聊天」，连会话一起移出消息列表。
    // - historyClearedThrough：「清空聊天记录」，只隐藏本机历史，
    //   会话本身必须继续留在消息列表里。
    bool coversCutoff(DateTime? cutoff) =>
        cutoff != null &&
        (originalEvent == null ||
            !originalEvent.originServerTs.isAfter(cutoff));
    final locallyDeleted = coversCutoff(localHistory?.clearedThrough(room.id));
    final historyCleared = locallyDeleted ||
        coversCutoff(localHistory?.historyClearedThrough(room.id));
    final cachedEvent = originalEvent == null
        ? null
        : _owner._decryptedTimelineEvents[(
            room.client.userID,
            room.id,
            originalEvent.eventId
          )];
    final candidate =
        cachedEvent == null ? originalEvent : Event.fromJson(cachedEvent, room);
    final event = candidate != null &&
            (localHistory?.isEventHidden(room.id, candidate.eventId,
                    eventTimestamp: candidate.originServerTs) ??
                false)
        ? null
        : candidate;
    final members = _owner._memberProjectionCache.membersFor(room, preference);
    MatrixMemberSnapshot member(User user) => MatrixMemberSnapshot(
          id: user.id,
          displayName: user.calcDisplayname(),
          avatar: user.avatarUrl,
        );
    return MatrixConversationRoomSnapshot._trusted(
      id: room.id,
      displayName: room_names.roomDisplayName(room),
      name: room.name,
      avatar: room.avatar,
      isDirect: room.isDirectChat,
      directPeerId: room.directChatMatrixID,
      members: members,
      lastEvent: event == null
          ? null
          : MatrixEventSnapshot(
              type: event.type,
              eventId: event.eventId,
              messageType: event.messageType,
              content: Map.unmodifiable(event.content),
              text: event.text,
              body: event.body,
              originServerTs: event.originServerTs,
              senderId: event.senderId,
              sender: member(event.senderFromMemoryOrFallback),
              redacted: event.redacted,
              decryptionState: cachedEvent != null
                  ? MessageDecryptionState.decrypted
                  : event.type == EventTypes.Encrypted
                      ? (event.content['can_request_session'] == true
                          ? MessageDecryptionState.missingKey
                          : MessageDecryptionState.decrypting)
                      : MessageDecryptionState.decrypted,
            ),
      preference: locallyDeleted
          ? preference.copyWith(hidden: true, manualUnread: false)
          : preference,
      notificationCount: historyCleared ? 0 : room.notificationCount,
      notificationsEnabled: room.pushRuleState == PushRuleState.notify,
      isJoined: room.membership == Membership.join,
      // 排序锚点用「可见事件时间，否则清空前的最后事件时间」：清空聊天记录只
      // 隐藏本机历史，不得改变该会话在消息列表里的位置。
      lastActivityAt: event?.originServerTs ?? originalEvent?.originServerTs,
    );
  }
}

abstract interface class _ManagedClientResourceBase
    implements MatrixManagedResource {
  bool get canceled;
  set canceled(bool value);
  Future<void> attach(Client client);
  Future<void> detach();
}

final class _ManagedClientResource implements _ManagedClientResourceBase {
  _ManagedClientResource({
    required this.owner,
    required this.open,
    required this.close,
    this.revoke,
  });
  final MatrixSdkE2eeClient owner;
  final Future<void> Function(Client client) open;
  final Future<void> Function() close;
  final void Function()? revoke;
  bool opened = false;
  bool revoked = false;
  @override
  bool canceled = false;

  @override
  Future<void> attach(Client client) async {
    if (canceled || opened) return;
    await open(client);
    opened = true;
    revoked = false;
  }

  void revokeNow() {
    if (!opened || revoked) return;
    revoked = true;
    try {
      revoke?.call();
    } catch (_) {
      owner.securityLogger.record(
        stage: MatrixSecurityStage.lifecycle,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.lifecycleResourceRevokeFailed,
      );
    }
  }

  @override
  Future<void> detach() async {
    if (!opened) return;
    await close();
    opened = false;
  }

  @override
  Future<void> cancel() => owner._cancelManagedResource(this);
}

/// Immutable room data for presentation code. SDK rooms and users remain
/// private to this library so they cannot outlive a managed lease.
@immutable
final class MatrixRoomMemberSnapshot {
  const MatrixRoomMemberSnapshot({
    required this.id,
    required this.displayName,
    required this.avatarUri,
    required this.isJoined,
    this.powerLevel = 0,
  });

  final String id;
  final String displayName;
  final Uri? avatarUri;
  final bool isJoined;
  final int powerLevel;
}

@immutable
final class MatrixRoomInfoSnapshot {
  MatrixRoomInfoSnapshot({
    required this.id,
    required this.name,
    required this.topic,
    required this.isDirect,
    required this.directPeerId,
    required this.currentUserId,
    required this.announcementVersion,
    this.homeserver,
    this.canMentionAll = false,
    required this.preference,
    required List<MatrixRoomMemberSnapshot> members,
  }) : members = List.unmodifiable(members);

  final String id;
  final String name;
  final String topic;
  final bool isDirect;
  final String? directPeerId;
  final String? currentUserId;
  final int announcementVersion;
  final Uri? homeserver;
  final bool canMentionAll;
  final ConversationPreference preference;
  final List<MatrixRoomMemberSnapshot> members;
}

@immutable
final class MatrixForwardDestinationSnapshot {
  MatrixForwardDestinationSnapshot(
      {required this.id,
      required this.displayName,
      this.directPeerId,
      required this.isDirect,
      required this.memberCount,
      this.avatarUri,
      required List<MatrixRoomMemberSnapshot> members})
      : members = List.unmodifiable(members);
  final String id;
  final String displayName;
  final String? directPeerId;
  final bool isDirect;
  final int memberCount;
  final Uri? avatarUri;
  final List<MatrixRoomMemberSnapshot> members;
}

final class MatrixRoomLease
    implements
        _ManagedClientResourceBase,
        MatrixEncryptedMediaGateway,
        MatrixOutgoingProgressView,
        MatrixOutgoingVideoWorkView,
        AvatarMediaCapability,
        NudgeBackend,
        MessageInteractionBackend {
  MatrixRoomLease._(this.owner, this.roomId);
  final MatrixSdkE2eeClient owner;
  final String roomId;
  Room? _room;
  final List<_SdkRoomTimelineCapability> _timelines = [];
  FutureOr<void> Function()? _onRevoked;
  Future<void> Function()? _drainOwner;
  @override
  bool canceled = false;

  Room get _activeRoom =>
      _room ?? (throw StateError('Matrix room lease is not active'));

  Future<T> _withLeaseOperation<T>(
    Future<T> Function(Room room) operation,
  ) =>
      owner._withClient((active) async {
        final room = _activeRoom;
        if (!identical(room.client, active)) {
          throw StateError('Matrix room lease client mismatch');
        }
        return operation(room);
      });

  Future<T> _withLeaseSend<T>(Future<T> Function(Room room) operation) =>
      _withLeaseOperation((room) async {
        await owner._requireRoomSend(room);
        if (canceled || !identical(_activeRoom, room)) {
          throw StateError('Matrix room lease is not active');
        }
        return operation(room);
      });

  /// A non-SDK snapshot valid only while this lease is active.
  MatrixRoomInfoSnapshot get roomInfo {
    final value = _snapshotRoomInfo(_activeRoom);
    final peer =
        owner._duplicateRooms?.peerIdForRoom(value.currentUserId ?? '', roomId);
    if (peer == null) return value;
    return MatrixRoomInfoSnapshot(
        id: value.id,
        name: value.name,
        topic: value.topic,
        isDirect: true,
        directPeerId: peer,
        currentUserId: value.currentUserId,
        announcementVersion: value.announcementVersion,
        homeserver: value.homeserver,
        canMentionAll: value.canMentionAll,
        preference: value.preference,
        members: value.members);
  }

  bool get _mentionsActive => !canceled && !owner._accessRevoked;
  Future<UnreadMentionTracker> openMentions() =>
      _withLeaseOperation((room) => RoomMentionStore.shared
          .open(room, shouldContinue: () => _mentionsActive));
  Future<void> saveMentions() =>
      _withLeaseOperation((room) => RoomMentionStore.shared
          .save(room, shouldContinue: () => _mentionsActive));
  Future<void> scanMentions() =>
      _withLeaseOperation((room) => RoomMentionStore.shared
          .scan(room, shouldContinue: () => _mentionsActive));
  Future<void> ingestMentions() => _withLeaseOperation((room) async {
        for (final timeline in _timelines.toList()) {
          if (!timeline._disposed) {
            await RoomMentionStore.shared.ingest(
                room, timeline._liveTimeline.events,
                shouldContinue: () => _mentionsActive);
          }
        }
      });
  String? get historyToken =>
      _timelines.lastOrNull?.historyToken ?? _activeRoom.prev_batch;
  String? get oldestTimelineEventId =>
      _timelines.lastOrNull?._timeline.events.lastOrNull?.eventId;
  DateTime? get oldestTimelineEventDate =>
      _timelines.lastOrNull?._timeline.events.lastOrNull?.originServerTs;
  DateTime? get creationDate {
    final event = _activeRoom.getState(EventTypes.RoomCreate);
    return event is Event ? event.originServerTs.toLocal() : null;
  }

  Event? _loadedMediaEvent(String eventId) {
    for (final timeline in _timelines.reversed) {
      final event = timeline.eventById(eventId);
      if (event != null) return event;
    }
    return null;
  }

  TrustedMediaHashes? mediaHashes(String eventId) {
    final event = _loadedMediaEvent(eventId);
    return event == null ? null : TrustedMediaHashes.fromEvent(event);
  }

  MediaCacheKey mediaCacheKey(String eventId, {bool thumbnail = false}) {
    final event = _loadedMediaEvent(eventId);
    final hashes = mediaHashes(eventId);
    return MediaCacheKey(
        accountId: _activeRoom.client.userID ?? '',
        roomId: roomId,
        eventId: thumbnail ? 'thumb:$eventId' : eventId,
        contentSha256:
            thumbnail ? hashes?.thumbnailSha256 : hashes?.contentSha256,
        // Phase 2：本地索引 metadata——变体标记 + 媒体族锚点（正文摘要）。
        // 两者都不改变键/去重语义，只让索引知道"这些对象属于同一媒体族"。
        variant: thumbnail ? MediaVariantKind.thumbnail : MediaVariantKind.body,
        familyId: hashes?.contentSha256,
        sourceIdentity: event == null
            ? null
            : matrixMediaSourceIdentity(event.content, thumbnail: thumbnail));
  }

  Future<MatrixRoomInfoSnapshot> refreshRoomInfo() =>
      _withLeaseOperation((room) async {
        await room.requestParticipants([Membership.join]);
        return roomInfo;
      });

  Future<RoomTimelineCapability> openRoomTimeline({
    required void Function() onUpdate,
  }) =>
      _withLeaseOperation((room) async {
        final timeline = await room.getTimeline(onUpdate: onUpdate);
        final capability = _SdkRoomTimelineCapability(this, timeline, onUpdate);
        _timelines.add(capability);
        return capability;
      });

  final Map<String, MatrixRoomLease> _historyLeases = {};
  StreamSubscription<void>? _logicalSync;
  LogicalConversationTimelineCapability? _logicalTimeline;
  Future<void> Function()? _refreshLogicalSources;

  MatrixRoomLease leaseForEvent(String eventId) {
    final hinted = _logicalTimeline?.sourceRoomId(eventId);
    if (hinted != null && _historyLeases.containsKey(hinted)) {
      return _historyLeases[hinted]!;
    }
    for (final lease in _historyLeases.values) {
      if (lease._timelines
          .any((timeline) => timeline.eventById(eventId) != null)) {
        return lease;
      }
    }
    return this;
  }

  Future<void> hintLogicalEventSource(
      String eventId, String sourceRoomId) async {
    await _refreshLogicalSources?.call();
    final timeline = _logicalTimeline;
    if (canceled || timeline == null) {
      throw StateError('Logical timeline unavailable');
    }
    if (sourceRoomId != roomId && !_historyLeases.containsKey(sourceRoomId)) {
      throw StateError('Event source is not associated with this conversation');
    }
    timeline.hintSource(eventId, sourceRoomId);
  }

  Future<RoomTimelineCapability> openLogicalRoomTimeline({
    required void Function() onUpdate,
    String? anchorRoomId,
    String? anchorEventId,
  }) async {
    final primary = await openRoomTimeline(onUpdate: onUpdate);
    late final LogicalConversationTimelineCapability merged;
    merged = LogicalConversationTimelineCapability(
      primaryRoomId: roomId,
      primary: primary,
      sources: {},
      onDispose: () {
        if (!identical(_logicalTimeline, merged)) return;
        _logicalTimeline = null;
        _refreshLogicalSources = null;
        unawaited(_logicalSync?.cancel());
        _logicalSync = null;
        for (final lease in _historyLeases.values.toList()) {
          unawaited(lease.cancel());
        }
        _historyLeases.clear();
      },
    );
    _logicalTimeline = merged;
    Future<void>? attaching;
    bool attachAgain = false;
    Future<void> attachPass() async {
      do {
        attachAgain = false;
        if (canceled || !identical(_logicalTimeline, merged)) return;
        await owner.prepareConversationAssociations();
        for (final sourceId in owner.logicalRoomSourcesSync(roomId)) {
          if (canceled || !identical(_logicalTimeline, merged)) return;
          if (sourceId == roomId || _historyLeases.containsKey(sourceId)) {
            continue;
          }
          final source = await owner.openRoomLease(sourceId);
          try {
            final timeline = await source.openRoomTimeline(onUpdate: onUpdate);
            if (canceled || !identical(_logicalTimeline, merged)) {
              timeline.dispose();
              await source.cancel();
              return;
            }
            merged.addSource(sourceId, timeline);
            _historyLeases[sourceId] = source;
          } catch (_) {
            await source.cancel();
            rethrow;
          }
        }
        if (anchorEventId != null &&
            anchorRoomId != null &&
            (anchorRoomId == roomId ||
                _historyLeases.containsKey(anchorRoomId))) {
          merged.hintSource(anchorEventId, anchorRoomId);
        }
        onUpdate();
      } while (attachAgain);
    }

    Future<void> attachSources() {
      final current = attaching;
      if (current != null) {
        attachAgain = true;
        return current;
      }
      return attaching = attachPass().whenComplete(() => attaching = null);
    }

    _refreshLogicalSources = attachSources;
    try {
      await attachSources();
      if (canceled || !identical(_logicalTimeline, merged)) {
        throw StateError('Logical timeline unavailable');
      }
      _logicalSync = owner.syncEvents.listen((_) {
        unawaited(attachSources().catchError((Object _) {}));
      });
      return merged;
    } catch (_) {
      merged.dispose();
      rethrow;
    }
  }

  Future<MatrixEmojiVaultBackend> openEmojiVaultBackend() async {
    _activeRoom;
    return _SdkEmojiVaultBackend(this);
  }

  GroupChatInfoGateway openGroupChatInfoGateway() =>
      _SdkGroupChatInfoGateway(this);

  Stream<void> get membershipChanges => owner.syncEvents;

  Future<void> updateConversationPreference(
    ConversationPreference preference,
  ) =>
      _withLeaseOperation(
          (room) => writeConversationPreference(room, preference));

  /// 「清空聊天记录」：只清除本机历史，会话本身继续留在消息列表。
  Future<void> clearLocalHistory({
    required Iterable<String> messageIds,
    required DateTime cutoff,
  }) =>
      owner.conversations
          .clearLocalHistory(roomId, messageIds: messageIds, cutoff: cutoff);

  Future<DateTime?> serverNow() => _withLeaseOperation((room) async {
        final homeserver = room.client.homeserver;
        if (homeserver == null) return null;
        try {
          return await MatrixServerClock(
            homeserver: homeserver,
            httpClient: room.client.httpClient,
          ).now();
        } catch (_) {
          return null;
        }
      });

  Future<List<MatrixForwardDestinationSnapshot>> forwardingDestinations() =>
      _withLeaseOperation((room) async {
        final client = room.client;
        // 控制房间过滤统一走 RoomVisibilityPolicy（accountData + roomId），
        // 不再按展示名判定。
        final visibility = roomVisibilityFromAccountData(client);
        final destinations = [
          for (final target in client.rooms)
            if (target.encrypted &&
                target.membership == Membership.join &&
                target.canSendDefaultMessages &&
                visibility.isVisible(target.id))
              MatrixForwardDestinationSnapshot(
                id: target.id,
                displayName: room_names.roomDisplayName(target),
                directPeerId: target.directChatMatrixID,
                isDirect: target.isDirectChat,
                memberCount: target.getParticipants([Membership.join]).length,
                avatarUri: target.avatar,
                members: _snapshotRoomInfo(target).members,
              ),
        ];
        // 转发/分享/群发目标与消息列表共用同一套身份规则：一个私聊关系
        // （userA+userB）只允许一个入口；落选房间仅隐藏，绝不 leave。
        final me = client.userID;
        final registry = owner._duplicateRooms;
        if (me != null && registry != null) await registry.ensureLoaded(me);
        return resolveIdentityRepresentatives<MatrixForwardDestinationSnapshot>(
          destinations,
          selfUserId: me,
          isDirectOf: (destination) => destination.isDirect,
          directPeerIdOf: (destination) => destination.directPeerId,
          roomIdOf: (destination) => destination.id,
          isHiddenOf: (_) => false,
          messageCountOf: (destination) =>
              owner._decryptedEventCount(destination.id),
          lastActivityOf: (_) => null,
          primaryRoomIdOf: (registry == null || me == null)
              ? null
              : (peer) => registry.primaryRoomIdForPeer(me, peer),
        );
      });

  /// Captures this lease's active account before page-owned picker/camera work
  /// returns. The owner later continues independently only after admission.
  _OutgoingSession _outgoingSessionFor(Room room) {
    if (canceled) throw StateError('Matrix room lease is not active');
    final session = owner._captureOutgoingSession();
    if (!identical(room.client, session.client)) {
      throw StateError('Matrix room lease client mismatch');
    }
    return session;
  }

  Future<MatrixOutgoingWorkJob> enqueueVideoFile(
          {required String jobId,
          required MatrixOutgoingVideoFile video,
          required List<String> targetRoomIds}) =>
      owner._enqueueVideoFile(
          jobId: jobId,
          video: video,
          targetRoomIds: targetRoomIds,
          session: _outgoingSessionFor(_activeRoom));

  /// Atomically accepts lightweight gallery-video handles for this lease. The
  /// owner resolves and prepares each handle later under its bounded budget.
  Future<List<MatrixOutgoingWorkJob>> enqueueVideoFiles(
          {required List<MatrixOutgoingVideoFileRequest> requests}) =>
      owner._enqueueVideoFiles(
          requests: requests, session: _outgoingSessionFor(_activeRoom));

  Future<MatrixOutgoingWorkJob> enqueuePreparedMedia(
          {required String jobId,
          required MatrixOutgoingPreparedMedia media,
          required List<String> targetRoomIds}) =>
      owner._enqueuePreparedMedia(
          jobId: jobId,
          media: media,
          targetRoomIds: targetRoomIds,
          session: _outgoingSessionFor(_activeRoom));

  Future<List<MatrixOutgoingWorkJob>> enqueueForward(
          {required String batchId,
          required List<MatrixOutgoingForwardMessage> messages,
          required List<String> targetRoomIds}) =>
      owner._enqueueForward(
          batchId: batchId,
          messages: messages,
          targetRoomIds: targetRoomIds,
          session: _outgoingSessionFor(_activeRoom));

  GroupAnnouncementService openAnnouncementService() =>
      _LeaseAnnouncementService(this);

  bool get canEditAnnouncement =>
      MatrixGroupAnnouncementService(_activeRoom).canEdit;
  Future<GroupAnnouncement> loadAnnouncement() => _withLeaseOperation(
      (room) => MatrixGroupAnnouncementService(room).load());
  Future<void> saveAnnouncement(GroupAnnouncement value) => _withLeaseOperation(
      (room) => MatrixGroupAnnouncementService(room).save(value));
  Future<Uint8List> loadAnnouncementImage(String eventId) =>
      _withLeaseOperation(
          (room) => MatrixGroupAnnouncementService(room).loadImage(eventId));
  Future<String> uploadAnnouncementImage(Uint8List bytes, String name) =>
      _withLeaseOperation((room) =>
          MatrixGroupAnnouncementService(room).uploadImage(bytes, name));
  Future<String> sendMessageContent(Map<String, Object?> content,
          {required String txid}) =>
      _withLeaseSend((room) async =>
          await room.sendEvent(Map<String, dynamic>.from(content),
              txid: txid) ??
          (throw StateError('Matrix room event was not accepted')));

  Future<void> sendEncryptedAttachment({
    required Uint8List bytes,
    required String name,
    required String mimeType,
  }) =>
      _withLeaseSend((room) => room.sendFileEvent(
            MatrixFile.fromMimeType(
              bytes: bytes,
              name: name,
              mimeType: mimeType,
            ),
          ));

  void setOnRevoked(FutureOr<void> Function() callback) =>
      _onRevoked = callback;

  void bindOwnerDrain(Future<void> Function() drain) => _drainOwner = drain;

  @override
  Listenable get outgoingProgress => owner.outgoingWork;
  @override
  MatrixRoomVideoWorkSummary videoWorkSummaryForRoom(String roomId) =>
      owner.outgoingWork.videoWorkSummaryForRoom(roomId);

  /// E2/F3：红包领取成功后由**领取者本机**发送提示事件。
  ///
  /// 事件进入加密房间时间线，但投影层只对红包发起者与领取者成行
  /// （其他成员直接排除，见时间线白名单）。事件只带账号标识与领取者
  /// 房间显示名，不带任何金额/明细。
  Future<void> sendRedPacketClaimNotice(
          {required String packetId, required String ownerMatrixId}) =>
      owner._withClient((client) async {
        final room = client.getRoomById(roomId);
        if (room == null || !room.encrypted) {
          throw StateError('会话加密尚未就绪');
        }
        final me = client.userID;
        if (me == null || me.isEmpty) {
          throw StateError('Matrix account is not active');
        }
        final claimantName =
            room.unsafeGetUserFromMemoryOrFallback(me).calcDisplayname();
        final id = await room.sendEvent({
          'packet_id': packetId,
          'owner_matrix_id': ownerMatrixId,
          'claimant_matrix_id': me,
          'claimant_name': claimantName,
        }, type: changliaoRedPacketClaimedEventType);
        if (id == null) throw StateError('领取提示尚未发送');
      });

  @override
  Future<String> sendEncryptedMedia(
      String requestedRoomId, List<int> plaintext, String mimeType,
      {Map<String, dynamic>? extraContent,
      String? txid,
      String? filename,
      Uint8List? thumbnailBytes,
      int? thumbnailWidth,
      int? thumbnailHeight}) {
    if (requestedRoomId != roomId) {
      return Future<String>.error(
        StateError('Matrix room lease identity mismatch'),
      );
    }
    return owner._sendEncryptedMediaFromLease(this, plaintext, mimeType,
        extraContent: extraContent,
        txid: txid,
        filename: filename,
        thumbnailBytes: thumbnailBytes,
        thumbnailWidth: thumbnailWidth,
        thumbnailHeight: thumbnailHeight);
  }

  @override
  Future<ResolvedAvatarUrl?> resolveAvatar({
    required Uri? avatarUri,
    required double size,
  }) =>
      _withLeaseOperation((room) => MatrixAvatarUrlResolver.resolveForClient(
            avatarUri: avatarUri,
            client: room.client,
            size: size,
          ));

  @override
  Future<void> sendEncrypted(
    String requestedRoomId,
    String type,
    Map<String, Object?> content,
  ) {
    _requireRoomId(requestedRoomId);
    return _sendEvent(content, type: type);
  }

  @override
  Future<void> send(String requestedRoomId, Map<String, Object?> content) {
    _requireRoomId(requestedRoomId);
    return _sendEvent(content);
  }

  Future<void> _sendEvent(
    Map<String, Object?> content, {
    String? type,
  }) =>
      _withLeaseSend((room) async {
        final payload = Map<String, dynamic>.from(content);
        final eventId = type == null
            ? await room.sendEvent(payload)
            : await room.sendEvent(payload, type: type);
        if (eventId == null) {
          throw StateError('Matrix room event was not accepted');
        }
      });

  @override
  Future<void> redact(
    String requestedRoomId,
    String eventId,
    String reason,
  ) {
    _requireRoomId(requestedRoomId);
    return _withLeaseOperation(
      (room) => room.redactEvent(eventId, reason: reason),
    );
  }

  /// Edited pixels use the same encrypted send and content cache as attachments.
  Future<String> sendEditedImageTo(
    String targetRoomId,
    Uint8List bytes, {
    required String transactionId,
  }) =>
      _withLeaseOperation((source) async {
        final target = source.client.getRoomById(targetRoomId);
        if (target == null || !target.encrypted) {
          throw StateError('只能发送到端到端加密会话');
        }
        return owner._sendMedia(
          target,
          bytes,
          'image/png',
          txid: transactionId,
          filename: '编辑图片.png',
          validateLease: () {
            if (!identical(_activeRoom, source)) {
              throw StateError('Matrix source room lease is no longer active');
            }
          },
        );
      });

  @override
  Future<void> forwardEncryptedCopy(
    String sourceRoomId,
    String targetRoomId,
    String eventId,
  ) =>
      _withLeaseOperation((source) async {
        _requireRoomId(sourceRoomId);
        final target = source.client.getRoomById(targetRoomId);
        if (target == null || !target.encrypted) {
          throw StateError('只能转发到端到端加密会话');
        }
        final event = _eventForInteraction(eventId);
        if (event.roomId != null && event.roomId != source.id) {
          throw StateError('消息不属于当前会话');
        }
        if ({
          MessageTypes.Image,
          MessageTypes.File,
          MessageTypes.Audio,
          MessageTypes.Video
        }.contains(event.messageType)) {
          final info = event.content['info'] is Map
              ? event.content['info'] as Map
              : const <String, dynamic>{};
          final mimeType = info['mimetype']?.toString() ??
              switch (event.messageType) {
                MessageTypes.Video => 'video/mp4',
                MessageTypes.Audio => 'audio/mp4',
                MessageTypes.Image => 'image/jpeg',
                _ => 'application/octet-stream',
              };
          final groupVideo = !target.isDirectChat &&
              (event.messageType == MessageTypes.Video ||
                  mimeType.startsWith('video/'));
          final declaredSize = info['size'];
          if (groupVideo &&
              declaredSize is num &&
              declaredSize.isFinite &&
              declaredSize > maxOriginalVideoBytes) {
            throw const GroupVideoTooLargeException();
          }
          final hashes = TrustedMediaHashes.fromEvent(event);
          final bytes = await loadMediaWithCache(
              MediaCacheKey(
                  accountId: source.client.userID ?? '',
                  roomId: source.id,
                  eventId: event.eventId,
                  contentSha256: hashes?.contentSha256,
                  sourceIdentity: matrixMediaSourceIdentity(event.content)),
              () => downloadMediaContent(event));
          if (groupVideo) validateGroupVideoSize(bytes.length);
          Uint8List? thumbnail;
          if (hashes?.thumbnailSha256 != null || event.isThumbnailEncrypted) {
            thumbnail = await loadMediaWithCache(
                MediaCacheKey(
                    accountId: source.client.userID ?? '',
                    roomId: source.id,
                    eventId: 'thumb:${event.eventId}',
                    contentSha256: hashes?.thumbnailSha256,
                    sourceIdentity: matrixMediaSourceIdentity(event.content,
                        thumbnail: true)), () async {
              if (!event.isThumbnailEncrypted) {
                throw const FormatException('Missing encrypted thumbnail');
              }
              return (await event.downloadAndDecryptAttachment(
                      getThumbnail: true))
                  .bytes;
            });
          }
          await owner._sendMedia(target, bytes, mimeType, validateLease: () {
            if (!identical(_activeRoom, source)) {
              throw StateError('Matrix source room lease is no longer active');
            }
          },
              filename: event.body,
              extraContent: {'info': Map<String, dynamic>.from(info)},
              thumbnailBytes: thumbnail,
              thumbnailWidth: (info['thumbnail_info'] is Map)
                  ? info['thumbnail_info']['w'] as int?
                  : null,
              thumbnailHeight: (info['thumbnail_info'] is Map)
                  ? info['thumbnail_info']['h'] as int?
                  : null);
          return;
        }
        if (event.messageType != MessageTypes.Text) {
          throw StateError('该消息类型不能转发');
        }
        await owner._requireRoomSend(target);
        if (canceled || !identical(_activeRoom, source)) {
          throw StateError('Matrix source room lease is no longer active');
        }
        await target.sendEvent({
          'msgtype': MessageTypes.Text,
          'body': event.body,
          if (event.content['format'] != null)
            'format': event.content['format'],
          if (event.content['formatted_body'] != null)
            'formatted_body': event.content['formatted_body'],
        });
      });

  @override
  Future<void> forwardEncryptedText(
    String sourceRoomId,
    String targetRoomId,
    String text,
  ) =>
      _withLeaseOperation((source) async {
        _requireRoomId(sourceRoomId);
        if (text.isEmpty) {
          throw ArgumentError.value(text, 'text', 'must not be empty');
        }
        final target = source.client.getRoomById(targetRoomId);
        if (target == null || !target.encrypted) {
          throw StateError('只能转发到端到端加密会话');
        }
        await owner._requireRoomSend(target);
        if (canceled || !identical(_activeRoom, source)) {
          throw StateError('Matrix source room lease is no longer active');
        }
        final eventId =
            await target.sendEvent({'msgtype': 'm.text', 'body': text});
        if (eventId == null) {
          throw StateError('Matrix room event was not accepted');
        }
      });

  void _requireRoomId(String requestedRoomId) {
    if (requestedRoomId != roomId) {
      throw StateError('Matrix room lease identity mismatch');
    }
  }

  Event _eventForInteraction(String eventId) {
    for (final timeline in _timelines.reversed) {
      final event = timeline.eventById(eventId);
      if (event != null) return event;
    }
    throw StateError('Matrix timeline event is unavailable');
  }

  /// Freezes a selected timeline message while the lease still owns the SDK
  /// event. The returned source is route-independent and may only be admitted
  /// through [enqueueForward] before this lease is released.
  MatrixOutgoingForwardMessage snapshotForwardSource(
    String eventId, {
    String? selectedPlainText,
  }) {
    if (canceled) throw StateError('Matrix room lease is not active');
    final event = _eventForInteraction(eventId);
    if (event.roomId != null && event.roomId != roomId) {
      throw StateError('消息不属于当前会话');
    }
    if (event.messageType == MessageTypes.Text) {
      return MatrixOutgoingForwardText(
        id: event.eventId,
        body: selectedPlainText ?? event.body,
        format: selectedPlainText == null
            ? event.content['format']?.toString()
            : null,
        formattedBody: selectedPlainText == null
            ? event.content['formatted_body']?.toString()
            : null,
      );
    }
    if (!{
      MessageTypes.Image,
      MessageTypes.File,
      MessageTypes.Audio,
      MessageTypes.Video,
    }.contains(event.messageType)) {
      throw StateError('该消息类型不能转发');
    }
    final info = event.content['info'] is Map
        ? event.content['info'] as Map
        : const <String, dynamic>{};
    final mimeType = info['mimetype']?.toString() ??
        switch (event.messageType) {
          MessageTypes.Video => 'video/mp4',
          MessageTypes.Audio => 'audio/mp4',
          MessageTypes.Image => 'image/jpeg',
          _ => 'application/octet-stream',
        };
    final hashes = TrustedMediaHashes.fromEvent(event);
    return MatrixOutgoingForwardMedia._(
      id: event.eventId,
      sourceRoomId: roomId,
      sourceEventId: event.eventId,
      sourceAccountId: _activeRoom.client.userID ?? '',
      sourceClient: _activeRoom.client,
      body: event.body,
      mimeType: mimeType,
      filename: event.body,
      content: event.content,
      wasEncrypted: event.originalSource?.type == EventTypes.Encrypted,
      senderId: event.senderId,
      originServerTs: event.originServerTs,
      contentSha256: hashes?.contentSha256,
      thumbnailSha256: hashes?.thumbnailSha256,
    );
  }

  @override
  Future<void> attach(Client client) async {
    if (canceled) return;
    _room = client.getRoomById(roomId) ??
        (throw StateError('Matrix room is unavailable'));
  }

  void revokeNow() {
    if (_room == null) return;
    _logicalTimeline?.dispose();
    for (final timeline in _timelines.toList(growable: false)) {
      timeline.dispose();
    }
    _timelines.clear();
    unawaited(_logicalSync?.cancel());
    _logicalSync = null;
    for (final source in _historyLeases.values.toList()) {
      unawaited(source.cancel());
    }
    _historyLeases.clear();
    _room = null;
    final callback = _onRevoked;
    if (callback != null) {
      try {
        final result = callback();
        if (result is Future<void>) {
          unawaited(result.catchError((_) {
            owner.securityLogger.record(
              stage: MatrixSecurityStage.roomLeaseDrain,
              outcome: MatrixSecurityOutcome.failure,
              eventCode: MatrixSecurityCode.roomLeaseRevokeCallbackFailed,
            );
          }));
        }
      } catch (_) {
        owner.securityLogger.record(
          stage: MatrixSecurityStage.roomLeaseDrain,
          outcome: MatrixSecurityOutcome.failure,
          eventCode: MatrixSecurityCode.roomLeaseRevokeCallbackFailed,
        );
      }
    }
  }

  @override
  Future<void> detach() async {
    revokeNow();
    final drain = _drainOwner;
    if (drain == null) return;
    try {
      await Future<void>.sync(drain).timeout(owner.lifecycleDrainTimeout);
    } on TimeoutException {
      owner.securityLogger.record(
        stage: MatrixSecurityStage.roomLeaseDrain,
        outcome: MatrixSecurityOutcome.timeout,
        eventCode: MatrixSecurityCode.roomLeaseDrainTimeout,
      );
      throw StateError('E2EE_ROOM_LEASE_DRAIN_TIMEOUT');
    } catch (_) {
      owner.securityLogger.record(
        stage: MatrixSecurityStage.roomLeaseDrain,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.roomLeaseDrainFailed,
      );
      throw StateError('E2EE_ROOM_LEASE_DRAIN_FAILED');
    }
  }

  @override
  Future<void> cancel() => owner._cancelManagedResource(this);
}

MatrixRoomInfoSnapshot _snapshotRoomInfo(Room room) {
  MatrixRoomMemberSnapshot member(User user) => MatrixRoomMemberSnapshot(
        id: user.id,
        displayName: user.calcDisplayname(),
        avatarUri: user.avatarUrl,
        isJoined: user.membership == Membership.join,
        powerLevel: room.getPowerLevelByUserId(user.id),
      );
  final settings = room.roomAccountData[groupChatAccountDataType]?.content;
  final announcementVersion = settings?['announcement_version'];
  return MatrixRoomInfoSnapshot(
    id: room.id,
    name: room.name.trim(),
    topic: room.topic,
    isDirect: room.isDirectChat,
    directPeerId: room.directChatMatrixID,
    currentUserId: room.client.userID,
    homeserver: room.client.homeserver,
    canMentionAll: GroupRoomAuthority(room).canManage,
    announcementVersion:
        announcementVersion is num ? announcementVersion.toInt() : 0,
    preference: preferenceForRoom(room),
    members: [
      for (final id in reconcileMemberOrder(
          preferenceForRoom(room).memberOrderIds,
          room.getParticipants([Membership.join]).map((user) => user.id)))
        member(room.unsafeGetUserFromMemoryOrFallback(id)),
    ],
  );
}

final class _LeaseAnnouncementService implements GroupAnnouncementService {
  _LeaseAnnouncementService(this._lease);
  final MatrixRoomLease _lease;
  @override
  bool get canEdit => _lease.canEditAnnouncement;
  @override
  Stream<void> get changes => _lease.membershipChanges;
  @override
  Future<GroupAnnouncement> load() => _lease.loadAnnouncement();
  @override
  Future<void> save(GroupAnnouncement value) => _lease.saveAnnouncement(value);
  @override
  Future<Uint8List> loadImage(String eventId) =>
      _lease.loadAnnouncementImage(eventId);
  @override
  Future<String> uploadImage(Uint8List bytes, String name) =>
      _lease.uploadAnnouncementImage(bytes, name);
}

final class _SdkRoomTimelineCapability
    implements
        RoomVisibleReadCapability,
        RoomTimelineCapability,
        RoomHistoryStatus,
        RoomFutureHistoryStatus,
        RoomHistoryDateCapability,
        RoomMessageLookupSource,
        RoomWindowedTimelineSource,
        RoomNewestFirstTimelineSource {
  _SdkRoomTimelineCapability(this._lease, Timeline timeline, this._onUpdate)
      : _liveTimeline = timeline {
    _outgoingListener = () {
      if (!_disposed) _onUpdate();
    };
    _outgoingWork = _lease.owner.outgoingWork;
    _outgoingWork.addListener(_outgoingListener);
    // 日期索引 metadata 预热：日历打开时即可读到本地覆盖证据（无网络）。
    unawaited(_ensureDayIndex());
  }

  final MatrixRoomLease _lease;
  final Timeline _liveTimeline;
  Timeline? _contextTimeline;
  int _contextGeneration = 0;
  Completer<void>? _dateCancellation;
  Timeline get _timeline => _contextTimeline ?? _liveTimeline;
  final void Function() _onUpdate;
  late final VoidCallback _outgoingListener;
  late final MatrixOutgoingWorkCoordinator _outgoingWork;
  final Set<String> _retrying = {};
  final List<MatrixOutgoingWorkEcho> _pendingEchoAcknowledgements = [];
  bool _echoAcknowledgementScheduled = false;
  bool _disposed = false;
  final _messageCache =
      <String, (Event, EventStatus, Object?, String?, RoomMessageViewModel)>{};
  List<RoomMessageViewModel> _projectedMessages = const [];
  List<RoomMessageViewModel> _serverMessages = const [];
  List<RoomMessageViewModel> _pendingMessages = const [];
  List<RoomMessageViewModel> _withNotices = const [];
  List<RoomMessageViewModel> _visibleMessages = const [];
  List<GroupJoinNotice> _lastNotices = const [];

  RoomMessageViewModel _cachedMessage(Event event) {
    final cached = _messageCache[event.eventId];
    final redaction = event.unsigned?['redacted_because'];
    final transaction = event.unsigned?['transaction_id'] as String?;
    // The SDK replaces events for sync/history/decryption. Redaction and send
    // status are its in-place mutations and must be checked independently.
    if (cached != null &&
        identical(cached.$1, event) &&
        cached.$2 == event.status &&
        identical(cached.$3, redaction) &&
        cached.$4 == transaction) {
      return cached.$5;
    }
    final message = _message(event);
    _messageCache[event.eventId] =
        (event, event.status, redaction, transaction, message);
    return message;
  }

  bool Function(String, DateTime?)? _windowHiddenFilter;
  @override
  void setHiddenFilter(bool Function(String, DateTime?)? hidden) {
    _windowHiddenFilter = hidden;
  }

  RoomTimelineViewport<Object>? _viewport;
  @override
  void enableWindow() {
    _ensureActive();
    _messageCache.clear();
    _serverMessages = _projectedMessages =
        _pendingMessages = _withNotices = _visibleMessages = const [];
    _viewport = RoomTimelineViewport<Object>(
        idOf: (entry) =>
            entry is Event ? entry.eventId : (entry as GroupJoinNotice).eventId,
        project: (entry) => entry is Event
            ? _message(entry)
            : RoomMessageViewModel(
                id: (entry as GroupJoinNotice).eventId,
                senderId: '',
                text: entry.text,
                isOwn: false,
                deliveryState: RoomDeliveryState.sent,
                timestamp: entry.timestamp,
                kind: RoomMessageKind.system));
    _refreshWindowSource();
  }

  void _refreshWindowSource() {
    final hidden = _lease.owner._localHistoryStore?.readFilter(_lease.roomId);
    final entries = <Object>[];
    final pending = <Event>[];
    for (final event in _timeline.events.reversed) {
      if (!(event.type == EventTypes.Message ||
              (event.type == EventTypes.Encrypted && event.redacted) ||
              event.type == changliaoNudgeEventType ||
              event.type == changliaoFriendAcceptedEventType ||
              (event.type == changliaoRedPacketClaimedEventType &&
                  isRedPacketClaimNoticeParty(event))) ||
          event.messageType == groupAnnouncementMessageType ||
          (hidden?.call(event.eventId, event.originServerTs) ?? false) ||
          (_windowHiddenFilter?.call(event.eventId, event.originServerTs) ??
              false)) {
        continue;
      }
      if (event.status.isSending || event.status.isError) {
        pending.add(event);
      } else {
        entries.add(event);
      }
    }
    for (final event in pending) {
      final at = entries.indexWhere((other) =>
          (other as Event).originServerTs.isAfter(event.originServerTs));
      entries.insert(at < 0 ? entries.length : at, event);
    }
    if (!_lease._activeRoom.isDirectChat) {
      final notices = deriveGroupJoinNotices([
        for (final event in _timeline.events)
          if (event.type == EventTypes.RoomMember) projectMemberEvent(event)
      ],
          resolveName: (id) => _lease._activeRoom
              .unsafeGetUserFromMemoryOrFallback(id)
              .calcDisplayname());
      // Group using the existing policy, then merge without reordering SDK
      // messages. Notices precede messages at equal timestamps, as in the
      // non-windowed timeline. A single cursor avoids rescanning/shifting the
      // entire history for every membership notice.
      final grouped = <GroupJoinNotice>[
        for (final notice in mergeNoticesIntoTimeline(const [], notices))
          if (!(hidden?.call(notice.id, notice.timestamp) ?? false) &&
              !(_windowHiddenFilter?.call(notice.id, notice.timestamp) ??
                  false))
            GroupJoinNotice(
                eventId: notice.id,
                timestamp: notice.timestamp,
                text: notice.text),
      ];
      if (grouped.isNotEmpty) {
        final merged = <Object>[];
        var noticeIndex = 0;
        for (final entry in entries) {
          final timestamp = (entry as Event).originServerTs;
          while (noticeIndex < grouped.length &&
              !grouped[noticeIndex].timestamp.isAfter(timestamp)) {
            merged.add(grouped[noticeIndex++]);
          }
          merged.add(entry);
        }
        while (noticeIndex < grouped.length) {
          merged.add(grouped[noticeIndex++]);
        }
        _viewport!.update(merged);
        return;
      }
    }
    _viewport!.update(entries);
  }

  @override
  bool get hasEarlierWindow => _viewport?.hasEarlier ?? false;
  @override
  bool get hasLaterWindow => _viewport?.hasLater ?? false;
  @override
  int get totalMessages => _viewport?.total ?? snapshot().length;
  @override
  Iterable<RoomMessageViewModel> get allMessages =>
      _viewport?.all ?? snapshot();
  @override
  Iterable<RoomMessageViewModel> get newestFirstMessages =>
      historyNewestFirst();
  @override
  Iterable<RoomMessageViewModel> historyNewestFirst({String? beforeEventId}) {
    final viewport = _viewport;
    if (viewport != null) {
      return viewport.historyNewestFirst(beforeEventId: beforeEventId);
    }
    final source = snapshot();
    final index = beforeEventId == null
        ? -1
        : source.indexWhere((m) => m.id == beforeEventId);
    return source.reversed.skip(index < 0 ? 0 : source.length - index);
  }

  @override
  RoomMessageViewModel? findMessage(String id) =>
      _viewport?.find(id) ??
      _resolvedMessages[id] ??
      MessageTimelineCache.shared
          .lookup(_lease.owner._client?.userID ?? '', _lease.roomId, id);

  /// 已按 event_id 单独解析出来的消息（窗口之外的引用目标）。
  ///
  /// 与 [MessageTimelineCache] 的分工：这里是本会话（同一 RoomLease）
  /// 的即时投影；进程级缓存负责重新进入会话/切换窗口后的复用。
  final _resolvedMessages = <String, RoomMessageViewModel>{};

  @override
  bool get supportsMessageLookup => true;

  @override
  Future<RoomMessageViewModel?> lookupMessage(String eventId) async {
    _ensureActive();
    if (eventId.isEmpty) return null;
    final accountId = _lease.owner._client?.userID ?? '';
    final cached = _resolvedMessages[eventId] ??
        MessageTimelineCache.shared.lookup(accountId, _lease.roomId, eventId);
    if (cached != null) {
      _resolvedMessages[eventId] = cached;
      return cached;
    }
    final event = await _withOperation(() async {
      try {
        // SDK 语义：本 timeline 事件 → timeline 内缓存 → 本地加密库
        // （`Room.getEventById`）→ 服务器单事件查询 + 解密。
        return await _timeline.getEventById(eventId);
      } on MatrixException catch (error) {
        if (error.errcode == 'M_FORBIDDEN' ||
            error.errcode == 'M_UNAUTHORIZED') {
          throw ReplyMessageLookupDenied(error.errcode);
        }
        throw ReplyMessageLookupUnavailable(error.toString());
      } on TimeoutException catch (error) {
        throw ReplyMessageLookupUnavailable(error.toString());
      } on SocketException catch (error) {
        throw ReplyMessageLookupUnavailable(error.message);
      }
    });
    if (event == null) return null;
    final message = _cachedMessage(event);
    _resolvedMessages[eventId] = message;
    MessageTimelineCache.shared.remember(accountId, _lease.roomId, message);
    return message;
  }

  @override
  RoomMessageViewModel? get newestMessage {
    final hidden = _lease.owner._localHistoryStore?.readFilter(_lease.roomId);
    // SDK timelines keep the newest event at the head. Context paging must not
    // make a controller refresh scan the complete live history just to retain
    // this one tail projection.
    for (final event in _liveTimeline.events) {
      if (_visibleDateEvent(event, hidden)) return _cachedMessage(event);
    }
    return null;
  }

  @override
  DateTime? previousTimestamp(String id) => _viewport?.previousTimestamp(id);
  @override
  bool selectAnchor(String id) => _viewport?.anchor(id) ?? false;
  @override
  void selectEarlier() => _viewport?.earlier();
  @override
  void selectLater() => _viewport?.later();
  @override
  void selectLatest() {
    cancelPendingDateLookup();
    _contextTimeline?.cancelSubscriptions();
    _contextTimeline = null;
    _messageCache.clear();
    _viewport?.latest();
    if (!_disposed) _onUpdate();
  }

  @override
  void pinWindow() => _viewport?.pin();

  void _ensureActive() {
    if (_disposed) throw StateError('Matrix timeline capability is disposed');
    _lease._activeRoom;
  }

  Future<T> _withOperation<T>(Future<T> Function() operation) =>
      _lease._withLeaseOperation((_) async {
        _ensureActive();
        return operation();
      });

  Future<T> _withSendOperation<T>(Future<T> Function() operation) =>
      _lease._withLeaseSend((_) async {
        _ensureActive();
        return operation();
      });

  Event? eventById(String eventId) {
    if (_disposed) return null;
    for (final event in _timeline.events) {
      if (event.eventId == eventId) return event;
    }
    final other =
        identical(_timeline, _liveTimeline) ? _contextTimeline : _liveTimeline;
    if (other != null) {
      for (final event in other.events) {
        if (event.eventId == eventId) return event;
      }
    }
    return null;
  }

  @override
  List<RoomMessageViewModel> snapshot() {
    _ensureActive();
    if (_viewport != null) {
      _refreshWindowSource();
      // A background item belongs to the newest conversation state. It must
      // not appear in the middle of an anchored older history window.
      return _mergeAccountOutgoingWork(_viewport!.snapshot(),
          includePending: !_viewport!.hasLater && !isViewingHistoryContext);
    }
    List<RoomMessageViewModel>? changed;
    var index = 0;
    final pending = <RoomMessageViewModel>[];
    for (final event in _timeline.events.reversed) {
      if (!(event.type == EventTypes.Message ||
              (event.type == EventTypes.Encrypted && event.redacted) ||
              event.type == changliaoNudgeEventType ||
              event.type == changliaoFriendAcceptedEventType ||
              (event.type == changliaoRedPacketClaimedEventType &&
                  isRedPacketClaimNoticeParty(event))) ||
          event.messageType == groupAnnouncementMessageType) {
        continue;
      }
      final message = _cachedMessage(event);
      if (event.status.isError || event.status.isSending) {
        pending.add(message);
        continue;
      }
      if (changed == null &&
          (index >= _serverMessages.length ||
              !identical(_serverMessages[index], message))) {
        changed = _serverMessages.take(index).toList();
      }
      changed?.add(message);
      index++;
    }
    if (changed == null && index != _serverMessages.length) {
      changed = _serverMessages.take(index).toList();
    }
    final projectionChanged =
        changed != null || !listEquals(pending, _pendingMessages);
    if (changed != null) _serverMessages = List.unmodifiable(changed);
    if (projectionChanged) {
      _pendingMessages = pending;
      final ordered = List<RoomMessageViewModel>.of(_serverMessages);
      // Only unsent entries are timestamp-positioned. Server rows preserve
      // timeline order rather than sorting across SDK history gaps.
      for (final message in pending) {
        final at =
            ordered.indexWhere((m) => m.timestamp.isAfter(message.timestamp));
        ordered.insert(at < 0 ? ordered.length : at, message);
      }
      _projectedMessages = List.unmodifiable(ordered);
      final retained = {for (final event in _timeline.events) event.eventId};
      _messageCache.removeWhere((id, _) => !retained.contains(id));
    }
    // BUG3：入群系统通知——以真实 Matrix 成员事件为唯一权威，本地推导
    // （invite 配对 join 转变），绝不插入本地临时文本；历史重载一致。
    // 规格§一4：私聊（m.direct）房间绝不推导群聊系统通知——DM 的
    // invite/join 成员事件属建房信令，不是"邀请加入群聊"。
    final notices = _lease._activeRoom.isDirectChat
        ? const <GroupJoinNotice>[]
        : deriveGroupJoinNotices(
            [
              for (final event in _timeline.events)
                if (event.type == EventTypes.RoomMember)
                  projectMemberEvent(event)
            ],
            resolveName: (matrixUserId) => _lease._activeRoom
                .unsafeGetUserFromMemoryOrFallback(matrixUserId)
                .calcDisplayname(),
          );
    var noticesChanged = notices.length != _lastNotices.length;
    if (!noticesChanged) {
      for (var i = 0; i < notices.length; i++) {
        if (notices[i].eventId != _lastNotices[i].eventId ||
            notices[i].timestamp != _lastNotices[i].timestamp ||
            notices[i].text != _lastNotices[i].text) {
          noticesChanged = true;
          break;
        }
      }
    }
    if (projectionChanged || noticesChanged) {
      _lastNotices = notices;
      _withNotices = notices.isEmpty
          ? _projectedMessages
          : List.unmodifiable(
              mergeNoticesIntoTimeline(_projectedMessages, notices));
    }
    final projected = _mergeAccountOutgoingWork(_withNotices);
    final store = _lease.owner._localHistoryStore;
    if (store == null) return projected;
    // Re-check visibility every time so locally deleted/cleared rows never
    // return from the projection cache. Allocate only when visible rows change.
    final hidden = store.readFilter(_lease.roomId);
    List<RoomMessageViewModel>? visible;
    var visibleIndex = 0;
    for (final message in projected) {
      if (hidden(message.id, message.timestamp)) continue;
      if (visible == null &&
          (visibleIndex >= _visibleMessages.length ||
              !identical(_visibleMessages[visibleIndex], message))) {
        visible = _visibleMessages.take(visibleIndex).toList();
      }
      visible?.add(message);
      visibleIndex++;
    }
    if (visible == null && visibleIndex != _visibleMessages.length) {
      visible = _visibleMessages.take(visibleIndex).toList();
    }
    if (visible != null) _visibleMessages = List.unmodifiable(visible);
    return _visibleMessages;
  }

  List<RoomMessageViewModel> _mergeAccountOutgoingWork(
      List<RoomMessageViewModel> timelineMessages,
      {bool includePending = true}) {
    final work = _outgoingWork;
    final outgoing = work.itemsForRoom(_lease.roomId);
    if (outgoing.isEmpty) return timelineMessages;
    _deferMatchingOutgoingEchoAcknowledgements(outgoing);
    if (!includePending) return timelineMessages;
    final pending = <(MatrixOutgoingWorkItem, RoomMessageViewModel)>[
      for (final item in outgoing)
        (
          item,
          RoomMessageViewModel(
            id: 'outgoing:${item.txid}',
            transactionId: item.txid,
            senderId: _lease._activeRoom.client.userID ?? '',
            text: item.presentation.text,
            isOwn: true,
            deliveryState: item.state == MatrixOutgoingWorkState.failed
                ? RoomDeliveryState.failed
                : RoomDeliveryState.sending,
            timestamp: item.presentation.createdAt,
            kind: switch (item.presentation.kind) {
              MatrixOutgoingPresentationKind.image => RoomMessageKind.image,
              MatrixOutgoingPresentationKind.video => RoomMessageKind.video,
              MatrixOutgoingPresentationKind.voice => RoomMessageKind.voice,
              MatrixOutgoingPresentationKind.file => RoomMessageKind.file,
              MatrixOutgoingPresentationKind.text => RoomMessageKind.text,
            },
            mimeType: item.presentation.mimeType,
            voiceDuration:
                item.presentation.voiceDuration ?? const Duration(seconds: 1),
          ),
        ),
    ];
    if (pending.isEmpty) return timelineMessages;
    final existingIds = <String>{
      for (final message in timelineMessages) message.id,
    };
    final existingTransactions = <String>{
      for (final message in timelineMessages)
        if (message.transactionId != null) message.transactionId!,
    };
    final additions = <RoomMessageViewModel>[];
    for (final (item, message) in pending) {
      if (existingTransactions.contains(message.transactionId) ||
          existingIds.contains(message.id) ||
          (item.eventId != null && existingIds.contains(item.eventId))) {
        continue;
      }
      additions.add(message);
    }
    if (additions.isEmpty) return timelineMessages;
    additions.sort((left, right) {
      final time = left.timestamp.compareTo(right.timestamp);
      return time != 0 ? time : left.id.compareTo(right.id);
    });
    final merged = <RoomMessageViewModel>[];
    var additionIndex = 0;
    for (final message in timelineMessages) {
      while (additionIndex < additions.length &&
          !additions[additionIndex].timestamp.isAfter(message.timestamp)) {
        merged.add(additions[additionIndex++]);
      }
      merged.add(message);
    }
    merged.addAll(additions.skip(additionIndex));
    return List.unmodifiable(merged);
  }

  /// A snapshot must have no coordinator side effects: a listener can ask for
  /// another snapshot immediately. Restrict the history pass to identifiers
  /// held by sent work, then acknowledge its matches after this stack unwinds.
  void _deferMatchingOutgoingEchoAcknowledgements(
      List<MatrixOutgoingWorkItem> outgoing) {
    final eventIds = <String>{
      for (final item in outgoing)
        if (item.state == MatrixOutgoingWorkState.sent && item.eventId != null)
          item.eventId!,
    };
    final transactionIds = <String>{
      for (final item in outgoing)
        if (item.state == MatrixOutgoingWorkState.sent) item.txid,
    };
    if (eventIds.isEmpty && transactionIds.isEmpty) return;

    for (final event in _timeline.events) {
      if (!event.status.isSynced) continue;
      final transactionId = event.unsigned?['transaction_id'] as String?;
      if (!eventIds.contains(event.eventId) &&
          (transactionId == null || !transactionIds.contains(transactionId))) {
        continue;
      }
      _pendingEchoAcknowledgements.add(MatrixOutgoingWorkEcho(
        eventId: event.eventId,
        transactionId: transactionId,
      ));
    }
    if (_pendingEchoAcknowledgements.isEmpty || _echoAcknowledgementScheduled) {
      return;
    }
    _echoAcknowledgementScheduled = true;
    scheduleMicrotask(() {
      _echoAcknowledgementScheduled = false;
      if (_disposed) {
        _pendingEchoAcknowledgements.clear();
        return;
      }
      final acknowledgements =
          List<MatrixOutgoingWorkEcho>.of(_pendingEchoAcknowledgements);
      _pendingEchoAcknowledgements.clear();
      _outgoingWork.acknowledgeEchoes(acknowledgements);
    });
  }

  RoomMessageViewModel _message(Event event) {
    final status = event.status.isError
        ? RoomDeliveryState.failed
        : event.status.isSending
            ? RoomDeliveryState.sending
            : RoomDeliveryState.sent;
    final messageType = event.messageType;
    final info = event.content['info'];
    final durationMilliseconds =
        info is Map ? int.tryParse(info['duration']?.toString() ?? '') : null;
    final mimeType = info is Map ? info['mimetype']?.toString() : null;
    final attachmentSize =
        info is Map ? int.tryParse(info['size']?.toString() ?? '') : null;
    final nudge = event.type == changliaoNudgeEventType;
    final friendAccepted = event.type == changliaoFriendAcceptedEventType;
    final claimNotice = event.type == changliaoRedPacketClaimedEventType;
    final nudgeInfo = nudge
        ? NudgeInfo(
            senderId: event.content['sender_id']?.toString() ?? event.senderId,
            senderName:
                event.content['sender_display_name']?.toString() ?? '好友',
            targetUserId: event.content['target_user_id']?.toString() ?? '',
            targetName:
                event.content['target_display_name']?.toString() ?? '好友',
            suffix: event.content['suffix']?.toString() ?? '',
          )
        : null;
    return RoomMessageViewModel(
      id: event.eventId,
      transactionId: event.unsigned?['transaction_id'] as String?,
      // BUG-28：顶层宽高缺失（旧事件）回退 thumbnail_info，占位框宽高比稳定。
      imageWidth: _intValue(info is Map ? info['w'] : null) ??
          _intValue(info is Map && info['thumbnail_info'] is Map
              ? (info['thumbnail_info'] as Map)['w']
              : null),
      imageHeight: _intValue(info is Map ? info['h'] : null) ??
          _intValue(info is Map && info['thumbnail_info'] is Map
              ? (info['thumbnail_info'] as Map)['h']
              : null),
      senderId: event.senderId,
      text: event.redacted
          ? ''
          : friendAccepted
              ? _friendAcceptedBody(event)
              : (nudge
                  ? ''
                  : claimNotice
                      ? _redPacketClaimNoticeBody(
                          event, _lease._activeRoom.client.userID)
                      : event.text),
      isOwn: event.senderId == _lease._activeRoom.client.userID,
      deliveryState: status,
      timestamp: event.originServerTs.toLocal(),
      isSdkLocalEcho: !event.status.isSynced,
      kind: (nudge || friendAccepted || claimNotice)
          ? RoomMessageKind.system
          : switch (messageType) {
              MessageTypes.Image => RoomMessageKind.image,
              MessageTypes.Video => RoomMessageKind.video,
              MessageTypes.Audio => RoomMessageKind.voice,
              MessageTypes.File => RoomMessageKind.file,
              changliaoRedPacketMessageType => RoomMessageKind.redPacket,
              changliaoCallMessageType => RoomMessageKind.call,
              changliaoTransferMessageType => RoomMessageKind.transfer,
              _ => RoomMessageKind.text,
            },
      mimeType: mimeType,
      attachmentSize: attachmentSize,
      packetId: event.content['packet_id']?.toString(),
      greeting: event.content['greeting']?.toString(),
      transferId: event.content['transfer_id']?.toString(),
      transferAmount: event.content['transfer_amount']?.toString(),
      transferNote: event.content['transfer_note']?.toString(),
      transferReceiverId: event.content['transfer_receiver_id']?.toString(),
      transferReceiverMatrixId:
          event.content['transfer_receiver_matrix_id']?.toString(),
      redPacketMode: event.content['red_packet_mode']?.toString(),
      redPacketRecipientId:
          event.content['red_packet_recipient_id']?.toString(),
      redPacketRecipientMatrixId:
          event.content['red_packet_recipient_matrix_id']?.toString(),
      voiceDuration: Duration(milliseconds: durationMilliseconds ?? 1000),
      videoDuration: messageType == MessageTypes.Video
          ? Duration(
              milliseconds: info is Map
                  ? int.tryParse(info['duration']?.toString() ?? '') ?? 0
                  : 0)
          : null,
      callVideo: messageType == changliaoCallMessageType &&
          event.content['call_type']?.toString() == 'video',
      callConnected: messageType == changliaoCallMessageType &&
          event.content['call_connected']?.toString() == 'true',
      callDuration: Duration(
          milliseconds: messageType == changliaoCallMessageType
              ? int.tryParse(event.content['duration_ms']?.toString() ?? '') ??
                  0
              : 0),
      isFlashPhoto: messageType == MessageTypes.Image &&
          event.content['flash']?.toString() == '1',
      isRecalled: event.redacted,
      replyToEventId: ((event.content['m.relates_to'] as Map?)?['m.in_reply_to']
              as Map?)?['event_id']
          ?.toString(),
      replyExcerpt: switch (event.content['io.changliao.selected_quote']) {
        final String value => value,
        _ => null,
      },
      nudge: nudgeInfo,
    );
  }

  /// 好友接受系统消息正文：事件内 body 优先（发送方已拼好），缺失时
  /// 按事件内好友昵称重组。
  /// E2/F3：领取提示文案按查看者身份区分——发起者看到「xxx 领取了你的
  /// 红包」，领取者看到「你领取了红包」；非双方在上游已被排除。
  static String _redPacketClaimNoticeBody(Event event, String? me) {
    final owner = event.content['owner_matrix_id']?.toString();
    final claimantName =
        (event.content['claimant_name']?.toString() ?? '').trim();
    if (me != null && me == owner) {
      return '🧧 ${claimantName.isEmpty ? '有人' : claimantName} 领取了你的红包';
    }
    return '🧧 你领取了红包';
  }

  /// 领取提示是否与当前账号相关（非双方不投影成行）。
  bool isRedPacketClaimNoticeParty(Event event) {
    if (event.type != changliaoRedPacketClaimedEventType) return true;
    final me = _lease._activeRoom.client.userID;
    if (me == null || me.isEmpty) return false;
    final owner = event.content['owner_matrix_id']?.toString();
    final claimant = event.content['claimant_matrix_id']?.toString();
    return me == owner || me == claimant;
  }

  static String _friendAcceptedBody(Event event) {
    final body = event.content['body']?.toString();
    if (body != null && body.isNotEmpty) return body;
    return friendAcceptedSystemMessage(
      event.content['friend_display_name']?.toString() ?? '好友',
    );
  }

  @override
  Future<String> sendText(String text) => _withSendOperation(() async =>
      await _lease._activeRoom.sendTextEvent(text, parseCommands: false) ??
      // SDK 耗尽重试窗口才返回 null（只有网络类错误会走到这里；服务端拒绝
      // 以 MatrixException 抛出）→ 类型化网络异常 → waitingNetwork 自动重发。
      (throw const MessageSendNetworkException('消息发送失败')));

  @override
  Future<String> sendTextWithTransaction(String text, String transactionId) =>
      _withSendOperation(() async =>
          await _lease._activeRoom
              .sendTextEvent(text, txid: transactionId, parseCommands: false) ??
          (throw const MessageSendNetworkException('消息发送失败')));

  @override
  Future<String> sendTransferReference(
          String transferId, String amount, String? note,
          {String? receiverId, String? receiverMatrixId}) =>
      _withSendOperation(() async =>
          await _lease._activeRoom.sendEvent({
            'msgtype': changliaoTransferMessageType,
            'body': '[畅聊点钻转账]',
            'transfer_id': transferId,
            'transfer_amount': amount,
            if (note != null && note.isNotEmpty) 'transfer_note': note,
            // 收款对象仅为账号标识：其他成员在本机解析展示名（备注保密）。
            if (receiverId != null && receiverId.isNotEmpty)
              'transfer_receiver_id': receiverId,
            if (receiverMatrixId != null && receiverMatrixId.isNotEmpty)
              'transfer_receiver_matrix_id': receiverMatrixId,
          }) ??
          (throw const MessageSendNetworkException('转账消息发送失败')));

  @override
  Future<Uint8List?> loadThumbnail(String eventId) => _withOperation(() async {
        final event = eventById(eventId) ??
            (throw StateError('Matrix timeline event is unavailable'));
        final hashes = TrustedMediaHashes.fromEvent(event);
        if (hashes?.thumbnailSha256 == null && !event.hasThumbnail) return null;
        return loadMediaWithCache(
            _lease.mediaCacheKey(eventId, thumbnail: true),
            () => downloadMediaContent(event, thumbnail: true));
      });

  @override
  Future<String> sendRedPacketReference(String packetId, String greeting,
          {String? mode, String? recipientId, String? recipientMatrixId}) =>
      _withSendOperation(() async =>
          await _lease._activeRoom.sendEvent({
            'msgtype': changliaoRedPacketMessageType,
            'body': '[畅聊点钻红包]',
            'packet_id': packetId,
            'greeting': greeting,
            // 类型与专属对象仅为账号标识：其他成员在本机解析展示名。
            if (mode != null && mode.isNotEmpty) 'red_packet_mode': mode,
            if (recipientId != null && recipientId.isNotEmpty)
              'red_packet_recipient_id': recipientId,
            if (recipientMatrixId != null && recipientMatrixId.isNotEmpty)
              'red_packet_recipient_matrix_id': recipientMatrixId,
          }) ??
          (throw const MessageSendNetworkException('红包消息发送失败')));

  @override
  Future<Uint8List> loadAttachment(String eventId) => _withOperation(() async {
        final event = eventById(eventId) ??
            (throw StateError('Matrix timeline event is unavailable'));
        return loadMediaWithCache(
            _lease.mediaCacheKey(eventId), () => downloadMediaContent(event));
      });

  @override
  Future<void> retry(String transactionId) => _withSendOperation(() async {
        if (await _outgoingWork.retryTransaction(transactionId)) return;
        if (!_retrying.add(transactionId)) return;
        try {
          final matches = _timeline.events.where(
            (candidate) => candidate.eventId == transactionId,
          );
          if (matches.isEmpty) return;
          final event = matches.first;
          if (!event.status.isError) return;
          final txid =
              event.unsigned?['transaction_id'] as String? ?? event.eventId;
          // A lost HTTP acknowledgement is still the same Matrix transaction.
          // Recreate the local sending entry at the new attempt time while keeping
          // the wire transaction id, so the homeserver cannot deliver two copies.
          if (_timeline.events.any((candidate) =>
              candidate.status.isSent &&
              candidate.unsigned?['transaction_id'] == txid)) {
            return;
          }
          final media = {
            MessageTypes.Image,
            MessageTypes.Video,
            MessageTypes.Audio,
            MessageTypes.File,
          }.contains(event.messageType);
          final uploaded =
              event.content['url'] != null || event.content['file'] != null;
          // The SDK drops its file cache after upload, even if sending then fails.
          // Retry an uploaded attachment's existing encrypted payload directly.
          // Keep an uncached upload failure visible rather than losing its bubble.
          if (media &&
              !uploaded &&
              !_lease._activeRoom.sendingFilePlaceholders
                  .containsKey(event.eventId)) {
            throw StateError('附件已不可用，请重新选择文件');
          }
          await event.cancelSend();
          final result = media && !uploaded
              ? await event.sendAgain(txid: txid)
              : await _lease._activeRoom.sendEvent(
                  Map<String, dynamic>.from(event.content),
                  type: event.type,
                  txid: txid);
          if (result == null) {
            throw const MessageSendNetworkException('消息发送失败');
          }
        } finally {
          _retrying.remove(transactionId);
        }
      });

  @override
  Future<void> loadHistory() {
    final timeline = _timeline;
    return _withOperation(() => timeline.requestHistory(historyCount: 60));
  }

  @override
  bool get canLoadHistory => !_disposed && _timeline.canRequestHistory;

  @override
  bool get hasFutureHistory => !_disposed && _timeline.canRequestFuture;

  @override
  Future<void> loadFutureHistory() {
    final timeline = _timeline;
    return _withOperation(() => timeline.requestFuture(historyCount: 60));
  }

  String? get historyToken {
    final timeline = _timeline;
    if (!timeline.isFragmentedTimeline) return _lease._activeRoom.prev_batch;
    final token = timeline.chunk.prevBatch;
    return token.isEmpty ? null : token;
  }

  @override
  bool get isViewingHistoryContext => _contextTimeline != null;

  @override
  void cancelPendingDateLookup() {
    // Do not tear down the currently visible context. Only a future adopted
    // context may be cancelled; an SDK network future can still finish late.
    _contextGeneration++;
    final cancellation = _dateCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  @override
  Future<void> markRead() => _withOperation(_liveTimeline.setReadMarker);

  Future<void> _visibleReadTail = Future.value();
  DateTime? _visibleReadThrough;

  @override
  Future<void> markReadVisible(Iterable<String> eventIds) {
    final visible = eventIds.toSet();
    final operation = _visibleReadTail.then((_) => _withOperation(() async {
          Event? newest;
          for (final id in visible) {
            final event = eventById(id);
            if (event == null) continue;
            if (newest == null ||
                event.originServerTs.isAfter(newest.originServerTs)) {
              newest = event;
            }
          }
          if (newest == null) return;
          final currentReceipt =
              _lease._activeRoom.receiptState.global.latestOwnReceipt;
          final acknowledgedEvent =
              currentReceipt == null ? null : eventById(currentReceipt.eventId);
          final acknowledgedAt = acknowledgedEvent?.originServerTs;
          if (acknowledgedAt != null &&
              (_visibleReadThrough == null ||
                  acknowledgedAt.isAfter(_visibleReadThrough!))) {
            _visibleReadThrough = acknowledgedAt;
          }
          if (_visibleReadThrough != null &&
              !newest.originServerTs.isAfter(_visibleReadThrough!)) {
            return;
          }
          await _liveTimeline.setReadMarker(eventId: newest.eventId);
          _visibleReadThrough = newest.originServerTs;
          // Only clear the local aggregate when the actual latest source event was read.
          if (_lease._activeRoom.lastEvent?.eventId == newest.eventId) {
            ConversationReadState.shared()
                .markCleared(_lease.roomId, eventId: newest.eventId);
          }
        }));
    _visibleReadTail = operation.catchError((Object _) {});
    return operation;
  }

  DateTime _localDay(DateTime timestamp) {
    final local = timestamp.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  bool _visibleDateEvent(
      Event event, bool Function(String, DateTime?)? hidden) {
    if (event.type != EventTypes.Message ||
        event.redacted ||
        event.messageType == groupAnnouncementMessageType) {
      return false;
    }
    return !(hidden?.call(event.eventId, event.originServerTs) ?? false) &&
        !(_windowHiddenFilter?.call(event.eventId, event.originServerTs) ??
            false);
  }

  Iterable<Event> get _loadedEvents sync* {
    yield* _liveTimeline.events;
    final context = _contextTimeline;
    if (context != null) yield* context.events;
  }

  @override
  Iterable<RoomHistoryDayMetadata> get loadedDayMetadata {
    _ensureActive();
    final hidden = _lease.owner._localHistoryStore?.readFilter(_lease.roomId);
    final seen = <DateTime>{};
    for (final event in _loadedEvents) {
      if (_visibleDateEvent(event, hidden)) {
        seen.add(_localDay(event.originServerTs));
      }
    }
    return [for (final day in seen) RoomHistoryDayMetadata(day)];
  }

  Event? _eventForDay(Iterable<Event> events, DateTime day,
      bool Function(String, DateTime?)? hidden) {
    Event? earliest;
    for (final event in events) {
      if (_visibleDateEvent(event, hidden) &&
          _localDay(event.originServerTs) == day &&
          (earliest == null ||
              event.originServerTs.isBefore(earliest.originServerTs))) {
        earliest = event;
      }
    }
    return earliest;
  }

  @override
  Future<RoomHistoryDayLocation?> locateDay(DateTime localDay) async {
    _ensureActive();
    cancelPendingDateLookup();
    final generation = _contextGeneration;
    final cancellation = _dateCancellation = Completer<void>();
    final clock = Stopwatch()..start();
    final diagnostics = ChatDiagnostics.instance;
    final diagnosticGeneration = diagnostics.sessionGeneration;
    try {
      return await Future.any([
        _locateDay(localDay, generation),
        cancellation.future.then<RoomHistoryDayLocation?>((_) => null),
      ]).timeout(const Duration(seconds: 13));
    } catch (error) {
      if (generation == _contextGeneration) cancelPendingDateLookup();
      if (identical(diagnostics, ChatDiagnostics.instance) &&
          diagnostics.sessionGeneration == diagnosticGeneration) {
        diagnostics.record(
            stage: ChatDiagnosticStage.dateLocate,
            error: _dateFailureKind(error),
            elapsed: clock.elapsed,
            status: networkFailureHttpStatus(error));
      }
      rethrow;
    } finally {
      if (clock.elapsed > const Duration(seconds: 2) &&
          identical(diagnostics, ChatDiagnostics.instance) &&
          diagnostics.sessionGeneration == diagnosticGeneration) {
        diagnostics.record(
            stage: ChatDiagnosticStage.dateLocate,
            error: ChatDiagnosticError.slow,
            elapsed: clock.elapsed);
      }
    }
  }

  ChatDiagnosticError _dateFailureKind(Object error) =>
      error is TimeoutException
          ? ChatDiagnosticError.timeout
          : error is RoomHistoryLookupIncomplete
              ? ChatDiagnosticError.incomplete
              : networkFailureHttpStatus(error) != null
                  ? ChatDiagnosticError.rejected
                  : defaultNetworkFailureClassifier(error)
                      ? ChatDiagnosticError.network
                      : ChatDiagnosticError.unknown;

  Future<RoomHistoryDayLocation?> _locateDay(
      DateTime localDay, int generation) async {
    final day = DateTime(localDay.year, localDay.month, localDay.day);
    _ensureActive();
    final lookupClock = Stopwatch()..start();
    Duration remainingBudget(Duration cap) {
      final remaining = const Duration(seconds: 13) - lookupClock.elapsed;
      if (remaining <= Duration.zero) return Duration.zero;
      return remaining < cap ? remaining : cap;
    }

    final hidden = _lease.owner._localHistoryStore?.readFilter(_lease.roomId);
    final live = _eventForDay(_liveTimeline.events, day, hidden);
    if (live != null) {
      _contextTimeline?.cancelSubscriptions();
      _contextTimeline = null;
      _messageCache.clear();
      _onUpdate();
      return RoomHistoryDayLocation(eventId: live.eventId, day: day);
    }
    final local =
        _eventForDay(_contextTimeline?.events ?? const [], day, hidden);
    if (local != null) {
      return RoomHistoryDayLocation(eventId: local.eventId, day: day);
    }
    return _withOperation(() async {
      if (_disposed || generation != _contextGeneration) return null;
      final room = _lease._activeRoom;
      final timestampBudget = remainingBudget(const Duration(seconds: 5));
      if (timestampBudget == Duration.zero) {
        throw const RoomHistoryLookupIncomplete();
      }
      final located = await room.client
          .getEventByTimestamp(room.id, day.millisecondsSinceEpoch, Direction.f)
          .timeout(timestampBudget);
      if (_disposed || generation != _contextGeneration) return null;
      final locatedDay = _localDay(
          DateTime.fromMillisecondsSinceEpoch(located.originServerTs));
      if (locatedDay.isAfter(day)) {
        return null;
      }
      if (locatedDay.isBefore(day)) {
        throw const RoomHistoryLookupIncomplete();
      }
      var abandoned = false;
      var adopted = false;
      Timeline? context;
      final contextFuture = room.getTimeline(
          eventContextId: located.eventId,
          onUpdate: () {
            if (adopted && !_disposed && identical(_contextTimeline, context)) {
              _onUpdate();
            }
          });
      // A timeout cannot cancel an SDK future. Dispose a late context before it
      // can retain subscriptions or publish into a newer context generation.
      unawaited(contextFuture.then((late) {
        if (abandoned) late.cancelSubscriptions();
      }).catchError((_) {}));
      final contextBudget = remainingBudget(const Duration(seconds: 5));
      if (contextBudget == Duration.zero) {
        abandoned = true;
        throw const RoomHistoryLookupIncomplete();
      }
      final resolvedContext =
          await contextFuture.timeout(contextBudget, onTimeout: () {
        abandoned = true;
        throw TimeoutException('Matrix event context lookup timed out');
      });
      context = resolvedContext;
      try {
        if (_disposed || generation != _contextGeneration) {
          return null;
        }
        var currentHidden =
            _lease.owner._localHistoryStore?.readFilter(_lease.roomId);
        var event = _eventForDay(resolvedContext.events, day, currentHidden);
        var forwardPages = 0;
        while (event == null) {
          final hasUndecrypted = resolvedContext.events.any(
              (item) => item.type == EventTypes.Encrypted && !item.redacted);
          final crossedDay = resolvedContext.events.any((item) =>
              _visibleDateEvent(item, currentHidden) &&
              _localDay(item.originServerTs).isAfter(day));
          // The first visible later day proves that another forward page cannot
          // contain a displayable event on [day]. An encrypted event on the
          // selected day wins over that boundary: it is not evidence of an empty
          // day until decryption has completed.
          if (crossedDay ||
              !resolvedContext.canRequestFuture ||
              forwardPages >= 3) {
            if (hasUndecrypted ||
                (!crossedDay && resolvedContext.canRequestFuture)) {
              throw const RoomHistoryLookupIncomplete();
            }
            return null;
          }
          final forwardBudget = remainingBudget(const Duration(seconds: 13));
          if (forwardBudget == Duration.zero) {
            throw const RoomHistoryLookupIncomplete();
          }
          await resolvedContext
              .requestFuture(historyCount: 60)
              .timeout(forwardBudget);
          if (_disposed || generation != _contextGeneration) {
            resolvedContext.cancelSubscriptions();
            return null;
          }
          forwardPages++;
          currentHidden =
              _lease.owner._localHistoryStore?.readFilter(_lease.roomId);
          event = _eventForDay(resolvedContext.events, day, currentHidden);
        }
        _contextTimeline?.cancelSubscriptions();
        _contextTimeline = resolvedContext;
        adopted = true;
        _messageCache.clear();
        _onUpdate();
        return RoomHistoryDayLocation(eventId: event.eventId, day: day);
      } finally {
        if (!adopted) resolvedContext.cancelSubscriptions();
      }
    });
  }

  // —— Task A：日期索引 + 月级 metadata 查询 ——
  //
  // 与“聊天正文加载”彻底解耦：索引只保存日期/边界/anchor/覆盖状态；
  // 月查询优先读本地索引，缺覆盖时做**有界**探测（最多 2 次
  // timestamp_to_event），绝不线性扫描历史、绝不加载正文或媒体。

  RoomHistoryDayIndex? _dayIndex;
  final Map<String, RoomHistoryMonthDays> _monthCache = {};
  int _monthGeneration = 0;
  bool _monthLookupCancelled = false;
  Completer<void>? _monthCancellation;

  /// 日期索引的加载 Future 只创建一次：并发调用不得产生两个索引实例，
  /// 否则后完成的空索引会覆盖已填充的那个。
  Future<void>? _dayIndexLoad;

  Future<void> _ensureDayIndex() => _dayIndexLoad ??= _loadDayIndex();

  Future<void> _loadDayIndex() async {
    final accountKey = _lease.owner._client?.userID ?? 'unknown';
    try {
      _dayIndex = await RoomHistoryDayIndexStore.load(accountKey);
    } catch (_) {
      // 持久化不可用（首次运行/测试环境）时退化为内存索引：日期状态一致，
      // 只是重启后丢失本地覆盖证据。
      _dayIndex = RoomHistoryDayIndex();
    }
  }

  void _recordLoadedDaysIntoIndex(RoomHistoryDayIndex index) {
    final hidden = _lease.owner._localHistoryStore?.readFilter(_lease.roomId);
    final events = <({String eventId, DateTime timestamp})>[];
    DateTime? oldest;
    DateTime? newest;
    for (final event in _loadedEvents) {
      if (!_visibleDateEvent(event, hidden)) continue;
      events.add((eventId: event.eventId, timestamp: event.originServerTs));
      if (oldest == null || event.originServerTs.isBefore(oldest)) {
        oldest = event.originServerTs;
      }
      if (newest == null || event.originServerTs.isAfter(newest)) {
        newest = event.originServerTs;
      }
    }
    index.recordVisibleEvents(_lease.roomId, events);
    final createdAt = _lease.creationDate;
    if (createdAt != null) {
      index.recordRoomCreatedAt(_lease.roomId, createdAt);
    }
    // 本机连续分页得到的时间窗是“已覆盖”区间：区间内无事件即可判定为空。
    // 每次加载只**追加**一段区间（相邻/重叠自动合并），区间之间的空档保持
    // unknown —— 旧的单跨度 coveredFrom/coveredTo 会把两次加载之间的空档
    // 谎报成“无消息”。
    if (oldest != null && newest != null) {
      index.recordCoverage(_lease.roomId, from: oldest, to: newest);
    }
  }

  @override
  CalendarMonth? get earliestMonth {
    final earliest = _dayIndex?.earliestKnownDay(_lease.roomId);
    if (earliest != null) return CalendarMonth.of(earliest);
    final createdAt = _lease.creationDate;
    if (createdAt != null) return CalendarMonth.of(createdAt);
    return null; // 不伪造 1970：调用方显示“仍可向前探索”。
  }

  @override
  void cancelMonthLookup() {
    _monthGeneration++;
    _monthLookupCancelled = true;
    final cancellation = _monthCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  @override
  String? anchorForDay(DateTime localDay) {
    if (_disposed) return null;
    final anchor = _dayIndex?.anchorFor(_lease.roomId, localDay);
    return (anchor == null || anchor.isEmpty) ? null : anchor;
  }

  @override
  Future<RoomHistoryMonthDays> loadMonthDays(CalendarMonth month) async {
    _ensureActive();
    cancelMonthLookup();
    final generation = _monthGeneration;
    _monthLookupCancelled = false;
    final cancellation = _monthCancellation = Completer<void>();
    final clock = Stopwatch()..start();
    final diagnostics = ChatDiagnostics.instance;
    final diagnosticGeneration = diagnostics.sessionGeneration;
    try {
      final result = await Future.any([
        _loadMonthDays(month, generation),
        cancellation.future.then((_) => RoomHistoryMonthDays(month: month)),
      ]).timeout(const Duration(seconds: 10));
      if (result.error != null &&
          identical(diagnostics, ChatDiagnostics.instance) &&
          diagnostics.sessionGeneration == diagnosticGeneration) {
        diagnostics.record(
            stage: ChatDiagnosticStage.dateMonth,
            error: _dateFailureKind(result.error!),
            elapsed: clock.elapsed,
            status: networkFailureHttpStatus(result.error!));
      }
      return result;
    } catch (error) {
      if (generation == _monthGeneration) cancelMonthLookup();
      if (identical(diagnostics, ChatDiagnostics.instance) &&
          diagnostics.sessionGeneration == diagnosticGeneration) {
        diagnostics.record(
            stage: ChatDiagnosticStage.dateMonth,
            error: _dateFailureKind(error),
            elapsed: clock.elapsed,
            status: networkFailureHttpStatus(error));
      }
      return RoomHistoryMonthDays(month: month, error: error);
    } finally {
      if (clock.elapsed > const Duration(seconds: 2) &&
          identical(diagnostics, ChatDiagnostics.instance) &&
          diagnostics.sessionGeneration == diagnosticGeneration) {
        diagnostics.record(
            stage: ChatDiagnosticStage.dateMonth,
            error: ChatDiagnosticError.slow,
            elapsed: clock.elapsed);
      }
    }
  }

  Future<RoomHistoryMonthDays> _loadMonthDays(
      CalendarMonth month, int generation) async {
    await _ensureDayIndex();
    if (_disposed || generation != _monthGeneration) {
      return RoomHistoryMonthDays(month: month);
    }
    final index = _dayIndex!;
    final cacheKey = '${_lease.roomId}|${month.key}';
    final cached = _monthCache[cacheKey];
    if (cached != null && !cached.hasUnknown) return cached;

    _recordLoadedDaysIntoIndex(index);
    var result = index.monthDays(_lease.roomId, month);
    if (!result.hasUnknown) {
      return _monthCache[cacheKey] = result;
    }

    try {
      final probes = await _probeMonthRange(month, generation);
      if (probes == null || _disposed || generation != _monthGeneration) {
        return RoomHistoryMonthDays(
            month: month,
            dayStates: result.dayStates,
            anchors: result.anchors,
            coverageComplete: false,
            earliestDay: result.earliestDay);
      }
      final (first, last) = probes;
      final monthStart = month.firstDay;
      final monthEnd = month.lastDay;
      final firstEvent = first;
      final firstDay = firstEvent == null
          ? null
          : DateTime(
              firstEvent.$2.year, firstEvent.$2.month, firstEvent.$2.day);
      if (firstDay == null || firstDay.isAfter(monthEnd)) {
        // 服务端确认：该月起点之后最早的事件已在下个月 → 整月为空。
        for (var day = 1; day <= month.daysInMonth; day++) {
          index.recordDayProbe(
              _lease.roomId, DateTime(month.year, month.month, day),
              present: false, contributeToCoverage: true);
        }
      } else {
        // [monthStart, firstDay) 无事件；firstDay 有事件且带 anchor。
        for (var cursor = monthStart;
            cursor.isBefore(firstDay);
            cursor = cursor.add(const Duration(days: 1))) {
          index.recordDayProbe(_lease.roomId, cursor,
              present: false, contributeToCoverage: true);
        }
        index.recordDayProbe(_lease.roomId, firstDay,
            present: true,
            anchorEventId: firstEvent!.$1,
            anchorTimestamp: firstEvent.$2);
        final lastEvent = last;
        if (lastEvent != null) {
          final lastDay =
              DateTime(lastEvent.$2.year, lastEvent.$2.month, lastEvent.$2.day);
          if (!lastDay.isBefore(monthStart)) {
            index.recordDayProbe(_lease.roomId, lastDay,
                present: true,
                anchorEventId: lastEvent.$1,
                anchorTimestamp: lastEvent.$2);
            for (var cursor = lastDay.add(const Duration(days: 1));
                !cursor.isAfter(monthEnd);
                cursor = cursor.add(const Duration(days: 1))) {
              index.recordDayProbe(_lease.roomId, cursor,
                  present: false, contributeToCoverage: true);
            }
          }
        }
      }
      result = index.monthDays(_lease.roomId, month);
      await _persistDayIndex().timeout(const Duration(seconds: 2));
      if (generation != _monthGeneration) {
        // 已切月/已取消：过期结果不得发布。
        return RoomHistoryMonthDays(month: month);
      }
      if (!result.hasUnknown) _monthCache[cacheKey] = result;
      return result;
    } catch (error) {
      // 预算耗尽/网络失败 ≠ 确认空：保留 unknown，并把月份标记为 error。
      return RoomHistoryMonthDays(
        month: month,
        dayStates: result.dayStates,
        anchors: result.anchors,
        coverageComplete: result.coverageComplete,
        earliestDay: result.earliestDay,
        error: error,
      );
    }
  }

  /// 两次有界探测：该月起点之后的首个事件、该月终点之前的末个事件。
  /// 返回 null 表示查询被取消（generation 失效）。
  Future<((String, DateTime)?, (String, DateTime)?)?> _probeMonthRange(
      CalendarMonth month, int generation) async {
    const budget = Duration(seconds: 5);
    final room = _lease._activeRoom;
    Future<(String, DateTime)?> probe(DateTime at, Direction direction) async {
      try {
        final event = await room.client
            .getEventByTimestamp(room.id, at.millisecondsSinceEpoch, direction)
            .timeout(budget);
        if (_disposed || generation != _monthGeneration) return null;
        return (
          event.eventId,
          // 日期索引按设备本地日历日建键（与气泡日期一致）：这里必须转成
          // 本地时间再取年月日，否则 UTC 边界会造成整体错一天。
          DateTime.fromMillisecondsSinceEpoch(event.originServerTs)
        );
      } on MatrixException catch (error) {
        if (error.error == MatrixError.M_NOT_FOUND) return null;
        rethrow;
      }
    }

    if (_monthLookupCancelled) return null;
    final forward = await probe(month.firstDay, Direction.f);
    if (_disposed || generation != _monthGeneration) return null;
    final backward = await probe(month.lastDay, Direction.b);
    if (_disposed || generation != _monthGeneration) return null;
    return (forward, backward);
  }

  Future<void> _persistDayIndex() async {
    final index = _dayIndex;
    if (index == null) return;
    final accountKey = _lease.owner._client?.userID ?? 'unknown';
    try {
      await RoomHistoryDayIndexStore.save(accountKey, index);
    } catch (_) {
      // 索引持久化失败不得影响查询结果。
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    cancelMonthLookup();
    cancelPendingDateLookup();
    _disposed = true;
    _outgoingWork.removeListener(_outgoingListener);
    _liveTimeline.cancelSubscriptions();
    _contextTimeline?.cancelSubscriptions();
    _lease._timelines.remove(this);
  }
}

final class _SdkEmojiVaultBackend
    implements
        MatrixEmojiVaultBackend,
        MatrixEmojiVaultContentLoader,
        MatrixEmojiVaultMetadataBackend,
        MatrixEmojiVaultCacheIdentity {
  _SdkEmojiVaultBackend(this._lease);

  final MatrixRoomLease _lease;

  late final _metadata = EncryptedEmojiPreviewStore(
      '${_client.homeserver}|${_client.userID}|vault-metadata-v1');
  final _knownEvents = <String, EmojiVaultEvent>{};
  Future<void> _metadataWrites = Future.value();

  @override
  Future<List<EmojiVaultEvent>?> readCachedEvents(String roomId) =>
      _withOperation((_) async {
        final bytes = await _metadata.read(roomId);
        if (bytes == null) return null;
        final raw = jsonDecode(utf8.decode(bytes)) as List;
        final events = raw
            .map((value) {
              final map = Map<String, Object?>.from(value as Map);
              return _decodeContent(
                  map['type']! as String,
                  Map<String, Object?>.from(map['content']! as Map),
                  '',
                  DateTime.utc(1970));
            })
            .whereType<EmojiVaultEvent>()
            .toList();
        for (final event in events) {
          _knownEvents[event.eventId] = event;
        }
        return events;
      });

  Future<void> _persistEvents(
      String roomId, Iterable<EmojiVaultEvent> events) async {
    for (final event in events) {
      _knownEvents[event.eventId] = event;
    }
    final write = _metadataWrites.then((_) async {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode([
        for (final event in _knownEvents.values)
          {'type': event.matrixType, 'content': event.toJson()},
      ])));
      await _metadata.write(roomId, bytes);
    });
    _metadataWrites =
        write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    try {
      await write;
    } catch (_) {/* Sync remains usable if disk is unavailable. */}
  }

  @override
  String get cacheIdentity => '${_client.homeserver}|${_client.userID}';

  Client get _client => _lease._activeRoom.client;

  Future<T> _withOperation<T>(Future<T> Function(Client client) operation) =>
      _lease._withLeaseOperation((_) => operation(_client));

  @override
  String? readStoredRoomId() =>
      _client.accountData[emojiVaultAccountDataType]?.content['room_id']
          as String?;

  @override
  Future<String> createEncryptedVaultRoom() => _withOperation((client) async {
        final roomId = await client.createGroupChat(
          groupName: '畅聊表情仓库',
          enableEncryption: true,
          invite: const [],
          preset: CreateRoomPreset.privateChat,
          visibility: Visibility.private,
          waitForSync: true,
        );
        var room = client.getRoomById(roomId);
        if (room == null) {
          throw StateError('Matrix did not create the emoji vault room');
        }
        if (!room.encrypted) {
          await room.enableEncryption();
          await client.oneShotSync();
          room = client.getRoomById(roomId);
        }
        if (room == null || !room.encrypted) {
          throw StateError(
              'Matrix did not create an encrypted emoji vault room');
        }
        // 创建即登记：accountData 对本机可读之前的窗口内，房间也必须保持
        // 不可见/不可打开（身份用房间号，不用展示名）。
        ControlRoomRegistry.register(roomId);
        return roomId;
      });

  @override
  Future<void> storeRoomId(String roomId) => _withOperation((client) async {
        final userId = client.userID;
        if (userId == null) throw StateError('Matrix client is not logged in');
        await client.setAccountData(
          userId,
          emojiVaultAccountDataType,
          {'room_id': roomId},
        );
        await client.oneShotSync();
      });

  Future<Room> _room(Client client, String roomId) async {
    var room = client.getRoomById(roomId);
    if (room == null) {
      await client.sync();
      room = client.getRoomById(roomId);
    }
    if (room == null) throw StateError('Emoji vault room is not joined');
    return room;
  }

  @override
  Future<bool> isRoomEncrypted(String roomId) =>
      _withOperation((client) async => (await _room(client, roomId)).encrypted);

  @override
  Future<Map<String, Object?>> uploadEncrypted(
    String roomId,
    Uint8List bytes,
    String mimeType,
  ) =>
      _withOperation((client) async {
        final room = await _room(client, roomId);
        if (!room.encrypted) {
          throw StateError('Emoji media upload requires an encrypted room');
        }
        final encrypted = await MatrixFile(
          bytes: bytes,
          name: '畅聊加密表情',
          mimeType: mimeType,
        ).encrypt();
        final uri = await client.uploadContent(
          encrypted.data,
          filename: 'emoji.ciphertext',
          contentType: 'application/octet-stream',
        );
        return {
          'url': uri.toString(),
          'mimetype': mimeType,
          'v': 'v2',
          'key': {
            'alg': 'A256CTR',
            'ext': true,
            'k': encrypted.k,
            'key_ops': ['encrypt', 'decrypt'],
            'kty': 'oct',
          },
          'iv': encrypted.iv,
          'hashes': {'sha256': encrypted.sha256},
        };
      });

  @override
  Future<void> sendEncryptedEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) =>
      _withOperation((client) async {
        final room = await _room(client, roomId);
        if (!room.encrypted || !client.encryptionEnabled) {
          throw StateError('Emoji metadata requires Matrix E2EE');
        }
        final eventId = await room.sendEvent(Map<String, dynamic>.from(content),
            type: type);
        if (eventId == null) {
          throw StateError('Emoji vault event was not accepted');
        }
        final event =
            _decodeContent(type, content, eventId, DateTime.now().toUtc());
        if (event != null) await _persistEvents(roomId, [event]);
      });

  @override
  Future<List<EmojiVaultEvent>> loadEvents(String roomId) =>
      _withOperation((client) async {
        final room = await _room(client, roomId);
        final timeline = await room.getTimeline();
        try {
          final all = await loadCompleteEmojiHistory<Event>(
              events: () => timeline.events,
              canRequestHistory: () => timeline.canRequestHistory,
              cursor: () => room.prev_batch ?? '',
              requestHistory: () => timeline.requestHistory(historyCount: 100));
          final events = all
              .map(_decodeEvent)
              .whereType<EmojiVaultEvent>()
              .toList(growable: false);
          await _persistEvents(roomId, events);
          return _knownEvents.values.toList(growable: false);
        } finally {
          timeline.cancelSubscriptions();
        }
      });

  @override
  Future<Uint8List> loadContent(String roomId, EmojiVaultItem item) =>
      _withOperation((client) async {
        final room = await _room(client, roomId);
        if (!room.encrypted || !client.encryptionEnabled) {
          throw StateError('Emoji media download requires Matrix E2EE');
        }
        return loadMediaWithCache(
          MediaCacheKey(
            accountId: client.userID ?? '',
            roomId: roomId,
            eventId: 'emoji:${item.id}',
            contentSha256: item.sha256,
          ),
          () => downloadAndDecrypt(roomId, item.encryptedFile),
        );
      });

  @override
  Future<Uint8List> downloadAndDecrypt(
    String roomId,
    Map<String, Object?> encryptedFile,
  ) =>
      _withOperation((client) async {
        final room = await _room(client, roomId);
        if (!room.encrypted || !client.encryptionEnabled) {
          throw StateError('Emoji media download requires Matrix E2EE');
        }
        final url = encryptedFile['url']?.toString();
        final key = encryptedFile['key'];
        final hashes = encryptedFile['hashes'];
        if (url == null || key is! Map || hashes is! Map) {
          throw StateError('Encrypted emoji descriptor is invalid');
        }
        final uri = Uri.parse(url);
        var ciphertext = await client.database?.getFile(uri);
        if (ciphertext == null) {
          final downloadUri = await uri.getDownloadUri(client);
          final response = await client.httpClient.get(
            downloadUri,
            headers: {'authorization': 'Bearer ${client.accessToken}'},
          );
          if (response.statusCode != 200) {
            throw StateError('Emoji download failed');
          }
          ciphertext = response.bodyBytes;
          // Cache ciphertext, never the decrypted original or its keys.
          final database = client.database;
          if (database != null && ciphertext.length <= database.maxFileSize) {
            await database.storeFile(
                uri, ciphertext, DateTime.now().millisecondsSinceEpoch);
          }
        }
        final plaintext = await client.nativeImplementations.decryptFile(
          EncryptedFile(
            data: ciphertext,
            k: key['k']!.toString(),
            iv: encryptedFile['iv']!.toString(),
            sha256: hashes['sha256']!.toString(),
          ),
        );
        if (plaintext == null) {
          throw StateError('Encrypted emoji integrity failed');
        }
        return plaintext;
      });

  EmojiVaultEvent? _decodeEvent(Event event) {
    if (!event.type.startsWith('com.changliao.emoji.') ||
        event.redacted ||
        event.originalSource?.type != EventTypes.Encrypted) {
      return null;
    }
    final content = Map<String, Object?>.from(event.content);
    return _decodeContent(
        event.type, content, event.eventId, event.originServerTs.toUtc());
  }

  EmojiVaultEvent? _decodeContent(String type, Map<String, Object?> content,
      String eventId, DateTime fallbackAt) {
    final at = DateTime.tryParse(content['at']?.toString() ?? '')?.toUtc() ??
        fallbackAt;
    final stableId = content['event_id']?.toString() ?? eventId;
    switch (type) {
      case 'com.changliao.emoji.add':
        final rawItem = content['item'];
        if (rawItem is! Map) return null;
        return EmojiVaultEvent.add(
          eventId: stableId,
          at: at,
          item: EmojiVaultItem.fromJson(
            Map<String, Object?>.from(rawItem),
          ),
        );
      case 'com.changliao.emoji.remove':
        final itemId = content['item_id']?.toString();
        if (itemId == null) return null;
        return EmojiVaultEvent.remove(
          eventId: stableId,
          at: at,
          itemId: itemId,
        );
      case 'com.changliao.emoji.recents':
        final rawIds = content['item_ids'];
        if (rawIds is! List) return null;
        return EmojiVaultEvent.recent(
          eventId: stableId,
          at: at,
          itemIds: rawIds.map((value) => value.toString()).toList(),
        );
      default:
        return null;
    }
  }
}

final class _SdkGroupChatInfoGateway
    implements
        GroupChatInfoGateway,
        GroupOwnershipGateway,
        GroupAnnouncementGateway,
        GroupChatInfoReloadGateway {
  @override
  GroupAnnouncementService get announcementService =>
      _lease.openAnnouncementService();
  _SdkGroupChatInfoGateway(this._lease);
  final MatrixRoomLease _lease;
  Room get room => _lease._activeRoom;
  Future<T> _withOperation<T>(Future<T> Function() operation) =>
      _lease._withLeaseOperation((_) => operation());

  @override
  String? get roomId => room.id;
  final _preferenceOverlay = GroupPreferenceOverlay();
  Future<void> _preferenceWrites = Future.value();

  Map<String, Object?> get _settings => _preferenceOverlay.read(
        room.roomAccountData[conversationPreferenceType]?.content ??
            room.roomAccountData[groupChatAccountDataType]?.content ??
            const <String, Object?>{},
      );

  @override
  Future<GroupChatInfoSnapshot> load() => _withOperation(() async {
        await GroupRoomAuthority(room).refresh();
        final localJoined = room.getParticipants([Membership.join]).length;
        final users = await room.requestParticipants([Membership.join]);
        final invited = await room.requestParticipants([Membership.invite]);
        debugPrint(
          '[GroupMembers] local_joined=$localJoined '
          'server_joined=${users.length} server_invited=${invited.length}',
        );
        final settings = _settings;
        final followed = settings['followed_member_ids'];
        final storedOrder = settings['member_order_ids'];
        // BUG1：人数与成员列表只认真正 join；invite 是待确认邀请，绝不合并
        // 进 members（不再出现"人数增加了但对方没有真正进群"的假象）。
        final order = reconcileMemberOrder(
          storedOrder is List
              ? storedOrder.map((value) => value.toString())
              : const <String>[],
          users.map((user) => user.id),
        );
        final userById = {for (final user in users) user.id: user};
        final invitedOrder = reconcileMemberOrder(
          const <String>[],
          invited.map((user) => user.id),
        );
        final invitedById = {for (final user in invited) user.id: user};
        final authority = GroupRoomAuthority(room);
        final ownerId = authority.ownerId;
        final adminIds = users
            .where((user) =>
                user.id != ownerId && room.getPowerLevelByUserId(user.id) >= 50)
            .map((user) => user.id)
            .toList();
        final shared =
            room.getState(groupSettingsStateType)?.content ?? const {};
        final orderedUsers = [for (final id in order) userById[id]!];
        final activeIds = orderedUsers.map((user) => user.id).toSet();
        return GroupChatInfoSnapshot(
          name: room.name.trim(),
          announcement: await _announcementPreview(),
          remark: settings['remark']?.toString() ?? '',
          muted: settings['muted'] == true,
          attention: settings['attention'] == true,
          pinned: settings['pinned'] == true,
          saved: settings['saved'] == true,
          folded: settings['folded'] == true,
          notifyMentionMe: settings['notify_mention_me'] != false,
          notifyMentionAll: settings['notify_mention_all'] != false,
          notifyAnnouncement: settings['notify_announcement'] != false,
          followedMemberIds: followed is List
              ? followed
                  .map((value) => value.toString())
                  .where(activeIds.contains)
                  .take(4)
                  .toList()
              : const [],
          ownerId: ownerId,
          adminIds: adminIds,
          qrJoinEnabled: shared['qr_join_enabled'] != false,
          joinApprovalRequired: shared['join_approval_required'] == true,
          onlyManagersCanRename: authority.onlyManagersCanRename,
          currentUserId: room.client.userID,
          roomId: room.id,
          members: orderGroupMembers(members: [
            for (final user in orderedUsers) await _member(user),
          ], ownerId: ownerId, adminIds: adminIds.toSet()),
          invitedMembers: [
            for (final id in invitedOrder)
              if (invitedById[id] != null) await _member(invitedById[id]!),
          ],
        );
      });

  Future<String> _announcementPreview() => _withOperation(() async {
        try {
          return (await MatrixGroupAnnouncementService(room).load()).preview;
        } catch (_) {
          return '公告暂不可用，点击重试';
        }
      });

  Future<GroupChatMember> _member(User user) => _withOperation(() async {
        final avatar = MatrixAvatarUrlResolver.resolveImmediately(
          avatarUri: user.avatarUrl,
          homeserver: room.client.homeserver,
          accessToken: room.client.accessToken,
          size: 48,
        );
        return GroupChatMember(
          matrixUserId: user.id,
          displayName: user.calcDisplayname(),
          avatarUrl: avatar?.url,
          avatarHeaders: avatar?.headers ?? const {},
          matrixAvatarUri: user.avatarUrl,
          membership: user.membership == Membership.join
              ? GroupMemberMembership.joined
              : GroupMemberMembership.invited,
        );
      });

  @override
  @override
  Future<void> withdrawInvite(String matrixUserId) =>
      _withOperation(() => room.kick(matrixUserId));

  @override
  Future<void> invite(String matrixUserId) =>
      _withOperation(() => room.invite(matrixUserId));

  @override
  Future<void> leave() => _withOperation(() => room.leave());

  @override
  Future<void> removeMembers(List<String> matrixUserIds) =>
      _withOperation(() async {
        final authority = GroupRoomAuthority(room);
        await authority.refresh();
        authority.requireManager();
        for (final userId in matrixUserIds) {
          if (userId == authority.ownerId ||
              room.getPowerLevelByUserId(userId) >= room.ownPowerLevel) {
            throw StateError('不能移除群主或同级管理员');
          }
          await room.kick(userId);
        }
      });

  @override
  Future<void> setAdminIds(List<String> matrixUserIds) =>
      _withOperation(() async {
        final authority = GroupRoomAuthority(room);
        await authority.refresh();
        authority.requireOwner();
        if (matrixUserIds.toSet().length > 3 ||
            matrixUserIds.contains(authority.ownerId)) {
          throw StateError('最多设置3位管理员');
        }
        final members = await room.requestParticipants([Membership.join]);
        if (matrixUserIds.any((id) => !members.any((user) => user.id == id))) {
          throw StateError('请选择已加入的成员');
        }
        await authority.protectState(protectRoles: true);
        final current = Map<String, dynamic>.from(
            room.getState(EventTypes.RoomPowerLevels)?.content ?? {});
        final users = Map<String, dynamic>.from(current['users'] as Map? ?? {});
        for (final member in members) {
          if (member.id == authority.ownerId) continue;
          if (matrixUserIds.contains(member.id)) {
            users[member.id] = 50;
          } else if (room.getPowerLevelByUserId(member.id) >= 50) {
            users[member.id] = 0;
          }
        }
        await room.client.setRoomStateWithKey(room.id,
            EventTypes.RoomPowerLevels, '', {...current, 'users': users});
      });

  @override
  Future<void> transferOwnership(String userId) => _withOperation(() async {
        final authority = GroupRoomAuthority(room);
        await authority.refresh();
        authority.requireOwner();
        final members = await room.requestParticipants([Membership.join]);
        if (userId == authority.ownerId ||
            !members.any((user) => user.id == userId)) {
          throw StateError('请选择其他已加入的成员');
        }
        await authority.protectState(protectRoles: true);
        final current = Map<String, dynamic>.from(
            room.getState(EventTypes.RoomPowerLevels)?.content ?? {});
        final users = Map<String, dynamic>.from(current['users'] as Map? ?? {});
        users[userId] = 100;
        users[authority.ownerId] = 0;
        await room.client.setRoomStateWithKey(room.id,
            EventTypes.RoomPowerLevels, '', {...current, 'users': users});
      });

  @override
  Future<void> dissolve() => _withOperation(() async {
        final authority = GroupRoomAuthority(room);
        await authority.refresh();
        authority.requireOwner();
        await setGroupSetting('qr_join_enabled', false);
        final members = await room
            .requestParticipants([Membership.join, Membership.invite]);
        // Stop on failure: never report dissolution after a partial removal.
        for (final member in members) {
          if (member.id != authority.ownerId) await room.kick(member.id);
        }
        await room.leave();
      });

  @override
  Future<void> setGroupSetting(String key, Object value) =>
      _withOperation(() async {
        final authority = GroupRoomAuthority(room);
        await authority.refresh();
        authority.requireManager();
        if (!{
              'qr_join_enabled',
              'join_approval_required',
              'only_managers_can_rename'
            }.contains(key) ||
            value is! bool) {
          throw ArgumentError('不支持的群设置');
        }
        await authority.protectState();
        if (key == 'only_managers_can_rename') {
          final current = Map<String, dynamic>.from(
              room.getState(EventTypes.RoomPowerLevels)?.content ?? {});
          final events =
              Map<String, dynamic>.from(current['events'] as Map? ?? {});
          events[EventTypes.RoomName] = value ? 50 : 0;
          await room.client.setRoomStateWithKey(room.id,
              EventTypes.RoomPowerLevels, '', {...current, 'events': events});
        } else {
          await room.client.setRoomStateWithKey(
              room.id,
              groupSettingsStateType,
              '',
              {...?room.getState(groupSettingsStateType)?.content, key: value});
        }
      });

  @override
  Future<void> rename(String name) => _withOperation(() async {
        if (!room.canChangeStateEvent(EventTypes.RoomName)) {
          throw StateError('没有修改群名权限');
        }
        await room.setName(name);
      });

  @override
  Future<void> setAnnouncement(String announcement) => _withOperation(() async {
        await MatrixGroupAnnouncementService(room)
            .save(GroupAnnouncement([AnnouncementBlock.text(announcement)]));
      });

  @override
  Future<void> setPreference(
    GroupChatPreference preference,
    bool value,
  ) =>
      _withOperation(() async {
        await _writeSetting(
          switch (preference) {
            GroupChatPreference.muted => 'muted',
            GroupChatPreference.attention => 'attention',
            GroupChatPreference.pinned => 'pinned',
            GroupChatPreference.saved => 'saved',
            GroupChatPreference.folded => 'folded',
            GroupChatPreference.notifyMentionMe => 'notify_mention_me',
            GroupChatPreference.notifyMentionAll => 'notify_mention_all',
            GroupChatPreference.notifyAnnouncement => 'notify_announcement',
          },
          value,
        );
        if (preference == GroupChatPreference.pinned) {
          await _writeSetting(
            'pinned_at',
            value ? DateTime.now().toUtc().toIso8601String() : '',
          );
        }
      });

  @override
  Future<void> setFollowedMemberIds(List<String> matrixUserIds) =>
      _writeSetting('followed_member_ids', matrixUserIds.take(4).toList());

  @override
  Future<void> setRemark(String remark) => _writeSetting('remark', remark);

  Future<void> _writeSetting(String key, Object value) =>
      _withOperation(() async {
        final operation = _preferenceWrites.then((_) async {
          final userId = room.client.userID;
          if (userId == null) throw StateError('Matrix 账号尚未登录');
          final next = {..._settings, key: value};
          final baseline = _preferenceOverlay.remoteIdentity;
          await room.client.setAccountDataPerRoom(
              userId, room.id, conversationPreferenceType, next);
          _preferenceOverlay.wrote(key, value, baseline: baseline);
        });
        _preferenceWrites = operation.catchError((Object _) {});
        return operation;
      });
}

abstract interface class _ManagedClientStreamBase
    implements MatrixManagedSubscription {
  bool get canceled;
  set canceled(bool value);
  Future<void> attach(Client client);
  Future<void> detach();
}

final class _ManagedClientStream<T> implements _ManagedClientStreamBase {
  _ManagedClientStream({
    required this.owner,
    required this.streamFor,
    required this.onData,
  });

  final MatrixSdkE2eeClient owner;
  final Stream<T> Function(Client client) streamFor;
  final void Function(T event) onData;
  StreamSubscription<T>? _subscription;
  @override
  bool canceled = false;

  @override
  Future<void> attach(Client client) async {
    if (canceled) return;
    await detach();
    _subscription = streamFor(client).listen(onData);
  }

  @override
  Future<void> detach() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  @override
  Future<void> cancel() => owner._cancelManagedSubscription(this);
}

final class _MemberRefreshPolicy {
  _MemberRefreshPolicy({
    required this.now,
    required this.freshness,
    required this.retryDelay,
  });

  final DateTime Function() now;
  final Duration freshness;
  final Duration retryDelay;
  final Map<String, _MemberRefreshState> _rooms = {};

  bool shouldRefresh(String roomId) {
    final state = _rooms[roomId];
    if (state == null) return true;
    final current = now();
    final retryAt = state.retryAt;
    if (retryAt != null) return !current.isBefore(retryAt);
    if (state.dirty) return true;
    final refreshedAt = state.refreshedAt;
    return refreshedAt == null || current.difference(refreshedAt) >= freshness;
  }

  void markDirty(String roomId) {
    final state = _rooms[roomId] ??= _MemberRefreshState();
    state
      ..dirty = true
      ..revision = state.revision + 1;
  }

  String? _accountId;
  void bindAccount(String? accountId) {
    if (_accountId == accountId) return;
    reset();
    _accountId = accountId;
  }

  int beginRefresh(String roomId) =>
      (_rooms[roomId] ??= _MemberRefreshState()).revision;

  void markFresh(String roomId, int revision) {
    final state = _rooms[roomId] ??= _MemberRefreshState();
    if (state.revision != revision) return;
    state
      ..dirty = false
      ..refreshedAt = now()
      ..retryAt = null;
  }

  void markFailed(String roomId, int revision) {
    final state = _rooms[roomId] ??= _MemberRefreshState();
    state.retryAt = now().add(retryDelay);
    if (state.revision == revision) state.dirty = false;
  }

  void prune(Set<String> joinedGroupIds) =>
      _rooms.removeWhere((roomId, _) => !joinedGroupIds.contains(roomId));

  void reset() {
    _rooms.clear();
    _accountId = null;
  }
}

final class _MemberRefreshState {
  bool dirty = true;
  int revision = 0;
  DateTime? refreshedAt;
  DateTime? retryAt;
}

final class _ConversationMemberProjectionCache {
  final Map<String, _ConversationMemberProjection> _entries = {};
  StreamSubscription<({String roomId, StrippedStateEvent state})>? _changes;
  String? _accountId;

  void attach(Client client) {
    _changes?.cancel();
    _entries.clear();
    _accountId = client.userID;
    _changes = client.onRoomState.stream.listen((update) {
      if (update.state.type == EventTypes.RoomMember) {
        _entries[update.roomId]?.dirty = true;
      }
    });
  }

  Future<void> detach() async {
    await _changes?.cancel();
    _changes = null;
    _entries.clear();
    _accountId = null;
  }

  List<MatrixMemberSnapshot> membersFor(
      Room room, ConversationPreference preference) {
    if (_accountId != room.client.userID) {
      _entries.clear();
      _accountId = room.client.userID;
    }
    final existing = _entries[room.id];
    if (existing != null &&
        identical(existing.room, room) &&
        !existing.dirty &&
        listEquals(existing.memberOrderIds, preference.memberOrderIds)) {
      return existing.members;
    }
    final joined = room.getParticipants([Membership.join]);
    final byId = {for (final user in joined) user.id: user};
    final order = reconcileMemberOrder(preference.memberOrderIds, byId.keys);
    final members = List<MatrixMemberSnapshot>.unmodifiable([
      for (final id in order)
        if (byId[id] case final user?)
          MatrixMemberSnapshot(
              id: user.id,
              displayName: user.calcDisplayname(),
              avatar: user.avatarUrl),
    ]);
    _entries[room.id] = _ConversationMemberProjection(
        room: room,
        memberOrderIds: List<String>.unmodifiable(preference.memberOrderIds),
        members: members);
    return members;
  }

  void prune(Set<String> joinedRoomIds) =>
      _entries.removeWhere((roomId, _) => !joinedRoomIds.contains(roomId));
}

final class _ConversationMemberProjection {
  _ConversationMemberProjection(
      {required this.room,
      required this.memberOrderIds,
      required this.members});
  final Room room;
  final List<String> memberOrderIds;
  final List<MatrixMemberSnapshot> members;
  bool dirty = false;
}

/// Frozen plaintext forwarding snapshot. The owner copies these scalar fields
/// before admission so later selection or SDK Event map mutations cannot alter
/// the queued payload.
sealed class MatrixOutgoingForwardMessage {
  const MatrixOutgoingForwardMessage();
  String get id;
}

final class MatrixOutgoingForwardText extends MatrixOutgoingForwardMessage {
  MatrixOutgoingForwardText({
    required this.id,
    required this.body,
    this.format,
    this.formattedBody,
  });

  @override
  final String id;
  final String body;
  final String? format;
  final String? formattedBody;
}

/// A frozen existing attachment. Its source event is reconstructed from these
/// immutable facts after batch admission, so page/lease lifetime never owns a
/// download, decrypt, upload, or retry.
final class MatrixOutgoingForwardMedia extends MatrixOutgoingForwardMessage {
  MatrixOutgoingForwardMedia._({
    required this.id,
    required this.sourceRoomId,
    required this.sourceEventId,
    required this.sourceAccountId,
    required this.sourceClient,
    required this.body,
    required this.mimeType,
    required this.filename,
    required Map<String, dynamic> content,
    required this.wasEncrypted,
    required this.senderId,
    required this.originServerTs,
    this.contentSha256,
    this.thumbnailSha256,
  }) : _content = _freezeJsonMap(content);

  @override
  final String id;
  final String sourceRoomId;
  final String sourceEventId;
  final String sourceAccountId;
  final Client sourceClient;
  final String body;
  final String mimeType;
  final String filename;
  final bool wasEncrypted;
  final String senderId;
  final DateTime originServerTs;
  final String? contentSha256;
  final String? thumbnailSha256;
  final Map<String, dynamic> _content;

  Map<String, dynamic> content() => _mutableJsonMap(_content);
  Map<String, dynamic> get extraContent => _content['info'] is Map
      ? {'info': _mutableJson(_content['info'])}
      : const {};

  Map? get _info => _content['info'] is Map ? _content['info'] as Map : null;

  int? get declaredContentBytes {
    final value = _info?['size'];
    if (value is! num || !value.isFinite || value < 0) return null;
    return value.toInt();
  }

  bool get hasEncryptedThumbnail => _info?['thumbnail_file'] is Map;

  Map? get _thumbnailInfo {
    final value = _info?['thumbnail_info'];
    return value is Map ? value : null;
  }

  int? get thumbnailWidth => _intValue(_thumbnailInfo?['w']);
  int? get thumbnailHeight => _intValue(_thumbnailInfo?['h']);

  Duration? get voiceDuration {
    if (_content['msgtype'] != MessageTypes.Audio &&
        !mimeType.startsWith('audio/')) {
      return null;
    }
    final milliseconds = _intValue(_info?['duration']);
    return milliseconds == null ? null : Duration(milliseconds: milliseconds);
  }

  int get downloadLimitBytes => declaredContentBytes ?? _maxFileSendBytes;
  int get reservationBytes =>
      downloadLimitBytes +
      (thumbnailSha256 == null && !hasEncryptedThumbnail
          ? 0
          : _maxOutgoingVideoPosterBytes);
  MatrixOutgoingPresentationKind get presentationKind =>
      mimeType.startsWith('video/')
          ? MatrixOutgoingPresentationKind.video
          : mimeType.startsWith('image/')
              ? MatrixOutgoingPresentationKind.image
              : mimeType.startsWith('audio/') ||
                      _content['msgtype'] == MessageTypes.Audio
                  ? MatrixOutgoingPresentationKind.voice
                  : MatrixOutgoingPresentationKind.file;
}

int? _intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

/// Prepared plaintext media handed to the account owner. It is copied at
/// admission and then released with the shared source after terminal delivery.
final class MatrixOutgoingPreparedMedia {
  MatrixOutgoingPreparedMedia({
    required this.id,
    required List<int> bytes,
    required this.mimeType,
    required this.filename,
    required this.body,
    this.thumbnailBytes,
    this.thumbnailWidth,
    this.thumbnailHeight,
    Map<String, dynamic> extraContent = const {},
  })  : _bytes = Uint8List.fromList(bytes),
        extraContent = _freezeJsonMap(extraContent);

  final String id;
  Uint8List? _bytes;
  bool _admitted = false;
  final String mimeType;
  final String filename;
  final String body;
  final Uint8List? thumbnailBytes;
  final int? thumbnailWidth;
  final int? thumbnailHeight;
  final Map<String, dynamic> extraContent;

  int get retainedBytes =>
      (_bytes?.length ?? 0) + (thumbnailBytes?.length ?? 0);

  void _markAdmitted() {
    if (_admitted || _bytes == null) {
      throw StateError('Outgoing media was already admitted');
    }
    _admitted = true;
  }

  /// Transfers the frozen copy only after coordinator admission. A rejected
  /// capacity check leaves this object intact for a caller retry.
  Uint8List _takeBytes() {
    if (!_admitted) throw StateError('Outgoing media was not admitted');
    final result = _bytes;
    if (result == null) throw StateError('Outgoing media was already admitted');
    _bytes = null;
    return result;
  }

  Future<void> _releaseAdmitted() async {
    if (_admitted) _bytes = null;
  }
}

/// One local-video job submitted by a page after it has captured its lease.
final class MatrixOutgoingVideoFileRequest {
  const MatrixOutgoingVideoFileRequest({
    required this.jobId,
    required this.video,
    required this.targetRoomIds,
  });

  final String jobId;
  final MatrixOutgoingVideoFile video;
  final List<String> targetRoomIds;
}

/// Controlled local video input that becomes coordinator-owned only after
/// admission. It deliberately contains no page, lease, or BuildContext.
final class MatrixOutgoingVideoFile {
  MatrixOutgoingVideoFile({
    required this.id,
    File? source,
    Future<File?> Function()? resolveSource,
    required this.filename,
    required this.body,
    required this.deleteSourceWhenDone,
  })  : _source = source,
        _resolveSource = resolveSource,
        _prepareMedia = null,
        _sourceCost = null,
        assert(source != null || resolveSource != null);

  @visibleForTesting
  MatrixOutgoingVideoFile.forTesting({
    required this.id,
    required File source,
    required this.filename,
    required this.body,
    required this.deleteSourceWhenDone,
    required Future<MatrixOutgoingPreparedMedia> Function(File source)
        prepareMedia,
    Future<int> Function(File source)? sourceCost,
  })  : _source = source,
        _resolveSource = null,
        _prepareMedia = prepareMedia,
        _sourceCost = sourceCost;

  final String id;
  final File? _source;
  final Future<File?> Function()? _resolveSource;
  File? _resolvedSource;
  final String filename;
  final String body;
  final bool deleteSourceWhenDone;
  final Future<MatrixOutgoingPreparedMedia> Function(File source)?
      _prepareMedia;
  final Future<int> Function(File source)? _sourceCost;

  /// BUG-35：转码进度回报（由 _buildVideoJob 注入协调器上报）。
  void Function(double progress)? _progressSink;
  bool _admitted = false;

  void _markAdmitted() {
    if (_admitted) throw StateError('Outgoing video was already admitted');
    _admitted = true;
  }

  Future<int> sourceCost() {
    final source = _source;
    if (source == null) {
      throw StateError('Outgoing video source is resolved after admission');
    }
    return _sourceCost?.call(source) ?? source.length();
  }

  Future<void> _waitForSourceMetadata() async {
    // The test seam models a held picker-side metadata read. Production never
    // derives admission capacity from the raw file length.
    final source = _source;
    if (source != null) await _sourceCost?.call(source);
  }

  Future<File> _sourceForPreparation() async {
    final cached = _resolvedSource ?? _source;
    final source = cached ?? await _resolveSource?.call();
    if (source == null) {
      throw StateError('Selected video is no longer available');
    }
    _resolvedSource ??= source;
    if (await source.length() <= 0) {
      throw ArgumentError.value(source, 'video.source', 'must be non-empty');
    }
    return source;
  }

  Future<MatrixOutgoingPreparedMedia> _prepare() async {
    if (!_admitted) throw StateError('Outgoing video was not admitted');
    final source = await _sourceForPreparation();
    final testPreparation = _prepareMedia;
    if (testPreparation != null) return testPreparation(source);
    // Keep an app-owned capture through preparation failures so retry uses the
    // same original. Terminal source release owns deletion instead.
    final prepared = await prepareLocalChatVideo(source,
        deleteSourceWhenDone: false,
        onProgress: (progress) => _progressSink?.call(progress));
    final poster = prepared.poster?.lengthInBytes == null ||
            prepared.poster!.lengthInBytes > _maxOutgoingVideoPosterBytes
        ? null
        : prepared.poster;
    final dimensions =
        poster == null ? null : await decodeImageDimensions(poster);
    return MatrixOutgoingPreparedMedia(
      id: id,
      bytes: prepared.bytes,
      mimeType: 'video/mp4',
      filename: filename.endsWith('.mp4') ? filename : '$filename.mp4',
      body: body,
      thumbnailBytes: poster,
      thumbnailWidth: dimensions?.$1,
      thumbnailHeight: dimensions?.$2,
      extraContent: prepared.durationMs == null
          ? const {}
          : {
              'info': {'duration': prepared.durationMs}
            },
    );
  }

  Future<void> _release() async {
    final source = _resolvedSource ?? _source;
    if (source == null) return;
    if (deleteSourceWhenDone && await source.exists()) {
      await source.delete();
    }
  }
}

final class _OwnedOutgoingMediaSnapshot {
  _OwnedOutgoingMediaSnapshot(MatrixOutgoingPreparedMedia input)
      : _bytes = input._takeBytes(),
        mimeType = input.mimeType,
        filename = input.filename,
        body = input.body,
        thumbnailBytes = input.thumbnailBytes,
        thumbnailWidth = input.thumbnailWidth,
        thumbnailHeight = input.thumbnailHeight,
        extraContent = input.extraContent;

  Uint8List? _bytes;
  final String mimeType;
  final String filename;
  final String body;
  final Uint8List? thumbnailBytes;
  final int? thumbnailWidth;
  final int? thumbnailHeight;
  final Map<String, dynamic> extraContent;

  Uint8List bytes() => _bytes ?? (throw StateError('Outgoing media released'));
  Future<void> release() async => _bytes = null;
}

final class _DeferredOutgoingMediaSnapshot {
  _DeferredOutgoingMediaSnapshot(this._input);

  final MatrixOutgoingPreparedMedia _input;
  _OwnedOutgoingMediaSnapshot? _owned;

  Future<void> prepare(MatrixOutgoingWorkAttempt attempt) async {
    attempt.ensureActive();
    _owned ??= _OwnedOutgoingMediaSnapshot(_input);
    attempt.ensureActive();
  }

  Uint8List bytes() =>
      _owned?.bytes() ?? (throw StateError('Outgoing media was not prepared'));
  String get mimeType => _input.mimeType;
  String get filename => _input.filename;
  String get body => _input.body;
  Map<String, dynamic> get extraContent => _input.extraContent;
  Uint8List? get thumbnailBytes => _owned?.thumbnailBytes;
  int? get thumbnailWidth => _owned?.thumbnailWidth;
  int? get thumbnailHeight => _owned?.thumbnailHeight;

  Future<void> release() async {
    final owned = _owned;
    if (owned != null) {
      await owned.release();
    } else {
      await _input._releaseAdmitted();
    }
  }
}

/// Defers file compression until the account coordinator has admitted the
/// source. A successful rendition is retained once for all target retries.
final class _DeferredOutgoingVideoSnapshot {
  _DeferredOutgoingVideoSnapshot(this._video);

  final MatrixOutgoingVideoFile _video;
  _OwnedOutgoingMediaSnapshot? _owned;

  Future<void> prepare(MatrixOutgoingWorkAttempt attempt) async {
    attempt.ensureActive();
    if (_owned == null) {
      final media = await _video._prepare();
      attempt.ensureActive();
      media._markAdmitted();
      _owned = _OwnedOutgoingMediaSnapshot(media);
    }
    attempt.ensureActive();
  }

  Uint8List bytes() =>
      _owned?.bytes() ?? (throw StateError('Outgoing video was not prepared'));
  String get mimeType => _owned?.mimeType ?? 'video/mp4';
  String get filename => _owned?.filename ?? _video.filename;
  Map<String, dynamic> get extraContent => _owned?.extraContent ?? const {};
  Uint8List? get thumbnailBytes => _owned?.thumbnailBytes;
  int? get thumbnailWidth => _owned?.thumbnailWidth;
  int? get thumbnailHeight => _owned?.thumbnailHeight;

  Future<void> release() async {
    await _owned?.release();
    await _video._release();
  }
}

final class _DeferredOutgoingForwardMediaSnapshot {
  _DeferredOutgoingForwardMediaSnapshot(this.media);

  final MatrixOutgoingForwardMedia media;
  Uint8List? _bytes;
  Uint8List? _thumbnail;

  Uint8List bytes() =>
      _bytes ?? (throw StateError('Forwarded media was not prepared'));
  Uint8List? get thumbnail => _thumbnail;

  Future<void> release() async {
    _bytes = null;
    _thumbnail = null;
  }
}

Map<String, dynamic> _freezeJsonMap(Map<String, dynamic> source) =>
    Map.unmodifiable({
      for (final entry in source.entries) entry.key: _freezeJson(entry.value),
    });

Object? _freezeJson(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Map) {
    return Map.unmodifiable({
      for (final entry in value.entries)
        entry.key.toString(): _freezeJson(entry.value),
    });
  }
  if (value is List) return List.unmodifiable(value.map(_freezeJson));
  throw ArgumentError.value(value, 'extraContent', 'must contain JSON values');
}

Map<String, dynamic> _mutableJsonMap(Map<String, dynamic> source) => {
      for (final entry in source.entries) entry.key: _mutableJson(entry.value),
    };

Object? _mutableJson(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _mutableJson(entry.value),
    };
  }
  if (value is List) return value.map(_mutableJson).toList();
  return value;
}

final class _OutgoingSession {
  const _OutgoingSession({
    required this.client,
    required this.accountId,
    required this.deviceId,
    required this.coordinator,
  });

  final Client client;
  final String accountId;
  final String? deviceId;
  final MatrixOutgoingWorkCoordinator coordinator;
}

final class MatrixSdkE2eeClient
    implements
        MatrixE2eeClient,
        MatrixRecoveryClient,
        MatrixRecoveryBackend,
        MatrixTokenLoginGateway,
        MatrixAccountSelectionGateway,
        AvatarMediaCapability {
  Future<void>? _memberRefresh;
  late final _MemberRefreshPolicy _memberRefreshPolicy;
  late final _ConversationMemberProjectionCache _memberProjectionCache;

  /// 历史孤儿房间登记簿（primary 规则数据源）。生产在组合根注入；测试
  /// 不注入时解析器自动退回消息数/活跃度规则（保持用例封闭）。
  final DuplicateRoomRegistry? _duplicateRooms;
  StreamSubscription<EventUpdate>? _memberRefreshListener;
  SharedPreferencesLocalHiddenEvents? _localHistoryStore;

  Future<SharedPreferencesLocalHiddenEvents> _loadLocalHistory(
      Client client) async {
    final accountId = client.userID;
    if (accountId == null) throw StateError('Matrix client is not logged in');
    final store = SharedPreferencesLocalHiddenEvents(
        preferences: await SharedPreferences.getInstance(),
        accountId: accountId);
    _localHistoryStore = store;
    return store;
  }

  MatrixSdkE2eeClient(
    Client client, {
    required this.homeserver,
    Future<void> Function(Client client)? suspendClient,
    Future<Client> Function()? resumeClient,
    Future<void> Function(String homeserver, String userId)?
        selectClientAccount,
    Future<void> Function(Client? client)? clearClientData,
    Future<MatrixClientContinuityMetadata> Function(Client client)?
        readContinuityMetadata,
    MatrixDeviceRotation? rotateDeviceBinding,
    MatrixDiagnosticHasher? diagnosticHasher,
    MatrixSecurityLogger? securityLogger,
    MatrixOutgoingWorkCoordinator Function(String accountId)?
        outgoingWorkFactory,
    this.lifecycleDrainTimeout = const Duration(seconds: 5),
    DateTime Function()? memberRefreshNow,
    Duration memberRefreshTtl = const Duration(minutes: 10),
    Duration memberRefreshRetryDelay = const Duration(seconds: 15),
    DuplicateRoomRegistry? duplicateRooms,
  })  : _client = client,
        _suspendClient = suspendClient ?? _defaultSuspend,
        _resumeClient = resumeClient,
        _selectClientAccount = selectClientAccount,
        _clearClientData = clearClientData ?? _defaultClear,
        _readContinuityMetadata =
            readContinuityMetadata ?? _unconfiguredContinuityMetadata,
        _rotateDeviceBinding = rotateDeviceBinding,
        _diagnosticHasher = diagnosticHasher,
        _memberRefreshPolicy = _MemberRefreshPolicy(
          now: memberRefreshNow ?? DateTime.now,
          freshness: memberRefreshTtl,
          retryDelay: memberRefreshRetryDelay,
        ),
        _memberProjectionCache = _ConversationMemberProjectionCache(),
        _duplicateRooms = duplicateRooms ?? DuplicateRoomRegistry(),
        _outgoingWorkFactory = outgoingWorkFactory ??
            ((accountId) =>
                MatrixOutgoingWorkCoordinator(accountId: accountId)),
        securityLogger = securityLogger ??
            MatrixSecurityLogger.create(sink: (line) => debugPrint(line)) {
    _outgoingWork = _newOutgoingWork(client.userID ?? '');
    _attachOutgoingEchoListener(client);
    _attachDecryptionListener(client);
    _attachMemberRefreshListener(client);
  }
  Client? _client;

  Future<bool> Function(String accountId, String roomId, String? peerId)?
      authorizeRoomSend;

  Future<bool> authorizeSendToRoom(String roomId) =>
      _withClient((active) async {
        final room = active.getRoomById(roomId);
        if (room == null) throw StateError('Matrix room is unavailable');
        return _authorizeRoom(room);
      });

  /// Admission only: existing transactions and encrypted payloads never call this.
  Object get sendPreparationIdentity => (
        _client,
        _client?.userID,
        _client?.deviceID,
        _outgoingWork,
        _accessRevoked
      );

  Future<String> Function(String accountId, String roomId, String peerId)?
      prepareRoomSend;

  Future<String> prepareNewSendToRoom(String roomId) =>
      _withClient((client) async {
        final account = client.userID;
        final room = client.getRoomById(roomId);
        if (account == null || room == null) {
          throw StateError('Conversation unavailable');
        }
        await _duplicateRooms?.ensureLoaded(account);
        _requireLifecycleAccess();
        if (!identical(_client, client) || client.userID != account) {
          throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
        }
        final peer = _duplicateRooms?.peerIdForRoom(account, roomId) ??
            room.directChatMatrixID;
        final prepare = prepareRoomSend;
        if (peer == null || prepare == null) return roomId;
        final target = await prepare(account, roomId, peer);
        _requireLifecycleAccess();
        if (!identical(_client, client) ||
            client.userID != account ||
            !identical(client.getRoomById(roomId), room)) {
          throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
        }
        final targetRoom = client.getRoomById(target);
        if (targetRoom == null) {
          throw StateError('Conversation is still synchronizing');
        }
        final targetPeer = _duplicateRooms?.peerIdForRoom(account, target) ??
            targetRoom.directChatMatrixID;
        if (targetPeer != peer) {
          throw StateError('Resolved conversation identity mismatch');
        }
        return target;
      });

  Future<List<String>> _prepareNewTargets(
      List<String> roomIds, _OutgoingSession session) async {
    if (roomIds.any((id) => id.isEmpty) ||
        roomIds.toSet().length != roomIds.length) {
      throw ArgumentError('Targets must be non-empty and unique');
    }
    final targets = <String>[];
    for (final roomId in roomIds) {
      targets.add(await prepareNewSendToRoom(roomId));
      _ensureOutgoingSessionCurrent(session);
    }
    return List<String>.unmodifiable(targets.toSet());
  }

  Future<bool> _authorizeRoom(Room room) async {
    final client = room.client;
    final account = client.userID;
    void validate() {
      _requireLifecycleAccess();
      if (!identical(_client, client) ||
          account != client.userID ||
          !identical(client.getRoomById(room.id), room)) {
        throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
      }
    }

    validate();
    final authorize = authorizeRoomSend;
    if (authorize == null) return true;
    if (account == null || account.isEmpty) return false;
    await _duplicateRooms?.ensureLoaded(account);
    validate();
    final peer = _duplicateRooms?.peerIdForRoom(account, room.id) ??
        room.directChatMatrixID;
    final allowed = await authorize(account, room.id, peer);
    validate();
    if (!allowed ||
        room.membership != Membership.join ||
        !room.encrypted ||
        !room.canSendDefaultMessages) {
      return false;
    }
    if (peer != null) {
      final members = room
          .getParticipants([Membership.join, Membership.invite])
          .map((member) => member.id)
          .toSet();
      if (!room.participantListComplete ||
          members.length != 2 ||
          !members.contains(account) ||
          !members.contains(peer)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _requireRoomSend(Room room) async {
    if (!await _authorizeRoom(room)) {
      throw StateError('当前会话不允许发送消息');
    }
  }

  /// BUG-11 回归：Matrix 忽略列表投影（被拉黑账号的消息在同步层过滤，
  /// 不再送达本机）。委托给当前登录的 SDK client。
  List<String> get ignoredUsers => _client?.ignoredUsers ?? const [];

  Future<void> ignoreUser(String userId) {
    final client = _client;
    if (client == null) return Future<void>.value();
    return client.ignoreUser(userId);
  }

  Future<void> unignoreUser(String userId) {
    final client = _client;
    if (client == null) return Future<void>.value();
    return client.unignoreUser(userId);
  }

  final MatrixOutgoingWorkCoordinator Function(String accountId)
      _outgoingWorkFactory;
  late MatrixOutgoingWorkCoordinator _outgoingWork;
  Client? _pendingCloseClient;
  final Future<void> Function(Client client) _suspendClient;
  final Future<Client> Function()? _resumeClient;
  final Future<void> Function(String homeserver, String userId)?
      _selectClientAccount;
  final Future<void> Function(Client? client) _clearClientData;
  final Future<MatrixClientContinuityMetadata> Function(Client client)
      _readContinuityMetadata;
  final MatrixDeviceRotation? _rotateDeviceBinding;
  final MatrixDiagnosticHasher? _diagnosticHasher;
  final MatrixSecurityLogger securityLogger;
  Future<void> _lifecycleTail = Future.value();
  final Duration lifecycleDrainTimeout;
  int _inFlightClientOperations = 0;
  Completer<void>? _clientOperationsDrained;
  bool _accessRevoked = false;
  MatrixClientContinuityMetadata? _suspendedMetadata;

  /// 挂起时直接从 SDK client 观察到的身份标签（客户端事实，不是连续性验证）。
  /// 它让登录流程在连续性无法验证时仍然能识别"本地仍是同一账号"，从而不会
  /// 误走账号切换路径；连续性是否可信只由 [_suspendedMetadata] 决定。
  ({String? userId, String? deviceId, bool isLoggedIn})? _suspendedIdentity;
  MatrixSuspendedContinuity _suspendedContinuity =
      MatrixSuspendedContinuity.none;
  bool _clearFailed = false;
  bool _freshLoginAfterClear = false;
  bool _activeContinuityValidated = false;
  bool _credentialsInvalid = false;
  Future<void> _accountSelectionQueue = Future<void>.value();
  final Uri homeserver;
  final StreamController<void> _syncEvents = StreamController.broadcast();
  final StreamController<MatrixDecryptionUpdate> _decryptionUpdates =
      StreamController.broadcast();
  final Map<(String?, String, String), Map<String, dynamic>>
      _decryptedTimelineEvents = {};
  MatrixClientContinuityMetadata? _decryptionCacheContinuity;
  StreamSubscription<EventUpdate>? _decryptionSubscription;
  StreamSubscription<EventUpdate>? _outgoingEchoSubscription;
  final List<_ManagedClientStreamBase> _managedSubscriptions = [];
  final List<_ManagedClientResourceBase> _managedResources = [];
  late final MatrixConversationCapability conversations =
      MatrixConversationCapability._(this);
  @visibleForTesting
  int get debugDecryptedPreviewCount => _decryptedTimelineEvents.length;

  /// 规则二数据源：本会话已解密消息缓存条数（"本地消息数量"的保守代理）。
  /// 只读内存映射，零 SDK 副作用；仅在同一身份出现多个候选房间时参与比较。
  int _decryptedEventCount(String roomId) =>
      _decryptedTimelineEvents.keys.where((key) => key.$2 == roomId).length;

  /// 逻辑会话归并出口（缺陷 0919 项 3）：roomId 是登记在案的重复房间时
  /// 返回其 primary 房间号，否则 null。内存同步查询（登记簿由收敛路径
  /// ensureLoaded）；搜索/通知入口在打开前据此归一化为只读定位。
  Future<void> prepareConversationAssociations() => _withClient((client) async {
        final registry = _duplicateRooms;
        if (registry != null) {
          await loadDirectRoomAssociations(client, registry);
        }
      });

  String? logicalPrimaryRoomIdSync(String roomId) {
    final client = _client;
    final self = client?.userID;
    if (client == null || self == null) return null;
    final registry = _duplicateRooms;
    final peer = registry?.peerIdForRoom(self, roomId) ??
        client.getRoomById(roomId)?.directChatMatrixID;
    if (peer == null) return null;
    // Display preferences may select a visible list representative, but cannot
    // change the server's sending destination (including hidden primaries).
    final confirmed = registry?.primaryRoomIdForPeer(self, peer);
    if (confirmed != null &&
        client.getRoomById(confirmed)?.membership == Membership.join) {
      return confirmed;
    }

    final candidates = [
      for (final id in logicalRoomSourcesSync(roomId))
        if (client.getRoomById(id) case final Room room)
          conversations._reassociateDuplicate(
              conversations._snapshotRoom(room, _localHistoryStore),
              registry,
              self)
    ];
    final representatives = resolveConversationIdentities(candidates,
        selfUserId: self,
        primaryRoomIdOf: (peerId) =>
            registry?.primaryRoomIdForPeer(self, peerId),
        localMessageCountOf: (room) => _decryptedEventCount(room.id));
    return representatives.firstOrNull?.id;
  }

  String logicalConversationKeySync(String roomId) {
    final client = _client;
    final self = client?.userID;
    final peer = self == null
        ? null
        : _duplicateRooms?.peerIdForRoom(self, roomId) ??
            client?.getRoomById(roomId)?.directChatMatrixID;
    return peer == null || peer.isEmpty ? 'room:$roomId' : 'dm:$peer';
  }

  Set<String> logicalRoomSourcesSync(String roomId) {
    final client = _client;
    final self = client?.userID;
    if (client == null || self == null) return {roomId};
    final registry = _duplicateRooms;
    final peer = registry?.peerIdForRoom(self, roomId) ??
        client.getRoomById(roomId)?.directChatMatrixID;
    if (peer == null) return {roomId};
    return {
      roomId,
      if (registry?.primaryRoomIdForPeer(self, peer) case final String primary)
        primary,
      ...?(client.directChats[peer] as List?)?.whereType<String>(),
      for (final entry
          in (registry?.localDirectPeers(self) ?? <String, String>{}).entries)
        if (entry.value == peer) entry.key,
      for (final old in registry?.entries(self) ?? <DuplicateRoomEntry>[])
        if (old.peerId == peer) ...[old.duplicateRoomId, old.primaryRoomId],
    }.where((id) {
      final source = client.getRoomById(id);
      return source?.membership == Membership.join &&
          (registry == null ||
              admitConversationIdentity(source!, self, registry) == peer);
    }).toSet();
  }

  String? duplicateRoomPrimaryIdSync(String roomId) {
    final registry = _duplicateRooms;
    if (registry == null) return null;
    final self = _client?.userID;
    if (self == null) return null;
    return registry.primaryRoomIdForDuplicate(self, roomId);
  }

  /// 逻辑会话归并（缺陷 0919 项 3）：roomId 是登记在案的重复房间时返回
  /// 其 primary 房间号，否则 null（含登记簿 ensureLoaded）。
  Future<String?> primaryRoomIdForDuplicateRoom(String roomId) =>
      _withClient((client) async {
        final registry = _duplicateRooms;
        final self = client.userID;
        if (registry == null || self == null) return null;
        await loadDirectRoomAssociations(client, registry);
        return registry.primaryRoomIdForDuplicate(self, roomId);
      });
  @visibleForTesting
  int get debugManagedResourceCount => _managedResources.length;
  @visibleForTesting
  bool get debugHasActiveClient => _client != null;
  @visibleForTesting
  MatrixSuspendedContinuity get debugSuspendedContinuity =>
      _suspendedContinuity;

  MatrixDiagnosticIdentity? _identity({
    String? matrixUserId,
    String? deviceId,
    String? previousDeviceId,
    String? databaseGeneration,
    String? fingerprint,
  }) =>
      _diagnosticHasher?.of(
        matrixUserId: matrixUserId,
        deviceId: deviceId,
        previousDeviceId: previousDeviceId,
        databaseGeneration: databaseGeneration,
        fingerprint: fingerprint,
      );

  /// Account-owned in-process outgoing work. It is replaced whenever the
  /// Matrix session identity changes and never belongs to a room lease.
  MatrixOutgoingWorkCoordinator get outgoingWork => _outgoingWork;

  /// Admits an immutable, multi-message text forwarding batch. The returned
  /// jobs are local pending state only; this never waits for a Matrix request.
  Future<List<MatrixOutgoingWorkJob>> enqueueForward({
    required String batchId,
    required List<MatrixOutgoingForwardMessage> messages,
    required List<String> targetRoomIds,
  }) =>
      _enqueueForward(
        batchId: batchId,
        messages: messages,
        targetRoomIds: targetRoomIds,
        session: _captureOutgoingSession(),
      );

  Future<List<MatrixOutgoingWorkJob>> _enqueueForward({
    required String batchId,
    required List<MatrixOutgoingForwardMessage> messages,
    required List<String> targetRoomIds,
    required _OutgoingSession session,
  }) async {
    if (batchId.isEmpty || messages.isEmpty || targetRoomIds.isEmpty) {
      throw ArgumentError('Forwarding requires a batch, messages, and targets');
    }
    final existing = [
      for (var i = 0; i < messages.length; i++)
        session.coordinator.job('$batchId-$i')
    ];
    if (existing.every((job) => job != null)) {
      return existing.cast<MatrixOutgoingWorkJob>();
    }
    if (existing.any((job) => job != null)) {
      throw StateError('Forward batch already partially admitted');
    }
    final targets = await _prepareNewTargets(targetRoomIds, session);
    if (targets.any((target) => target.isEmpty) ||
        targets.toSet().length != targets.length) {
      throw ArgumentError('Forwarding targets must be non-empty and unique');
    }
    _ensureOutgoingSessionCurrent(session);
    for (final targetRoomId in targets) {
      final target = session.client.getRoomById(targetRoomId);
      if (target == null || !target.encrypted) {
        throw StateError('只能发送到端到端加密会话');
      }
      if (target.membership != Membership.join ||
          !target.canSendDefaultMessages) {
        throw StateError('当前会话不可发送消息');
      }
    }
    final ids = <String>{};
    final jobs = <MatrixOutgoingWorkJob>[];
    for (var sourceIndex = 0; sourceIndex < messages.length; sourceIndex++) {
      final message = messages[sourceIndex];
      if (message.id.isEmpty || !ids.add(message.id)) {
        throw ArgumentError(
            'Forwarding message ids must be non-empty and unique');
      }
      if (message is MatrixOutgoingForwardMedia &&
          (message.sourceAccountId != session.accountId ||
              !identical(message.sourceClient, session.client))) {
        throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
      }
      if (message is MatrixOutgoingForwardMedia &&
          message.downloadLimitBytes > _maxFileSendBytes) {
        throw const MatrixOutgoingFileTooLargeException();
      }
      final createdAt = DateTime.now();
      final text = message is MatrixOutgoingForwardText ? message : null;
      final media = message is MatrixOutgoingForwardMedia ? message : null;
      final body = switch (message) {
        MatrixOutgoingForwardText(:final body) => body,
        MatrixOutgoingForwardMedia(:final body) => body,
      };
      final content = text != null
          ? Map<String, dynamic>.unmodifiable({
              'msgtype': MessageTypes.Text,
              'body': body,
              if (text.format != null) 'format': text.format,
              if (text.formattedBody != null)
                'formatted_body': text.formattedBody,
            })
          : null;
      final mediaSnapshot =
          media == null ? null : _DeferredOutgoingForwardMediaSnapshot(media);
      jobs.add(MatrixOutgoingWorkJob(
        id: '$batchId-$sourceIndex',
        createdAt: createdAt,
        source: MatrixOutgoingWorkSource(
          id: 'forward:$batchId:$sourceIndex',
          retainedBytes: media?.reservationBytes ?? 0,
          prepare: mediaSnapshot == null
              ? null
              : (attempt) => _prepareForwardMedia(
                  session: session, snapshot: mediaSnapshot, attempt: attempt),
          release: mediaSnapshot?.release,
        ),
        items: [
          for (var targetIndex = 0; targetIndex < targets.length; targetIndex++)
            MatrixOutgoingWorkItem(
              id: '${message.id}:$targetIndex',
              targetRoomId: targets[targetIndex],
              txid: 'outgoing-$batchId-$sourceIndex-$targetIndex',
              presentation: MatrixOutgoingWorkPresentation(
                kind: media?.presentationKind ??
                    MatrixOutgoingPresentationKind.text,
                text: body,
                mimeType: media?.mimeType,
                filename: media?.filename,
                voiceDuration: media?.voiceDuration,
                createdAt: createdAt,
              ),
              send: (attempt) => mediaSnapshot == null
                  ? _sendOutgoingText(
                      session: session,
                      targetRoomId: targets[targetIndex],
                      content: content!,
                      attempt: attempt,
                    )
                  : _sendOutgoingForwardMedia(
                      session: session,
                      targetRoomId: targets[targetIndex],
                      snapshot: mediaSnapshot,
                      attempt: attempt,
                    ),
            ),
        ],
      ));
    }
    _ensureOutgoingSessionCurrent(session);
    return session.coordinator.enqueueBatch(jobs);
  }

  /// Admits one prepared camera/file media source for multiple targets. The
  /// plaintext copy is owned by the account coordinator until terminal cleanup.
  Future<MatrixOutgoingWorkJob> enqueuePreparedMedia({
    required String jobId,
    required MatrixOutgoingPreparedMedia media,
    required List<String> targetRoomIds,
  }) =>
      _enqueuePreparedMedia(
        jobId: jobId,
        media: media,
        targetRoomIds: targetRoomIds,
        session: _captureOutgoingSession(),
      );

  Future<MatrixOutgoingWorkJob> _enqueuePreparedMedia({
    required String jobId,
    required MatrixOutgoingPreparedMedia media,
    required List<String> targetRoomIds,
    required _OutgoingSession session,
  }) async {
    if (jobId.isEmpty || media.id.isEmpty || targetRoomIds.isEmpty) {
      throw ArgumentError('Media forwarding requires an id and targets');
    }
    final existing = session.coordinator.job(jobId);
    if (existing != null) return existing;
    final targets = await _prepareNewTargets(targetRoomIds, session);
    if (targets.any((target) => target.isEmpty) ||
        targets.toSet().length != targets.length) {
      throw ArgumentError(
          'Media forwarding targets must be non-empty and unique');
    }
    final snapshot = _DeferredOutgoingMediaSnapshot(media);
    final createdAt = DateTime.now();
    final job = MatrixOutgoingWorkJob(
      id: jobId,
      createdAt: createdAt,
      source: MatrixOutgoingWorkSource(
        id: 'media:$jobId:${media.id}',
        retainedBytes: media.retainedBytes,
        prepare: snapshot.prepare,
        release: snapshot.release,
      ),
      items: [
        for (var targetIndex = 0; targetIndex < targets.length; targetIndex++)
          MatrixOutgoingWorkItem(
            id: '${media.id}:$targetIndex',
            targetRoomId: targets[targetIndex],
            txid: 'outgoing-$jobId-0-$targetIndex',
            presentation: MatrixOutgoingWorkPresentation(
              kind: media.mimeType.startsWith('video/')
                  ? MatrixOutgoingPresentationKind.video
                  : MatrixOutgoingPresentationKind.image,
              text: media.body,
              mimeType: media.mimeType,
              filename: media.filename,
              createdAt: createdAt,
            ),
            send: (attempt) => _sendOutgoingMedia(
              session: session,
              targetRoomId: targets[targetIndex],
              snapshot: snapshot,
              attempt: attempt,
            ),
          ),
      ],
    );
    _ensureOutgoingSessionCurrent(session);
    return session.coordinator.enqueue(job, onAccepted: media._markAdmitted);
  }

  /// Admits an uncompressed local video before compression begins. The account
  /// owns the file lifecycle and uses the process-wide encoding queue only
  /// when the coordinator reaches its bounded preparation slot.
  Future<MatrixOutgoingWorkJob> enqueueVideoFile({
    required String jobId,
    required MatrixOutgoingVideoFile video,
    required List<String> targetRoomIds,
  }) =>
      _enqueueVideoFile(
        jobId: jobId,
        video: video,
        targetRoomIds: targetRoomIds,
        session: _captureOutgoingSession(),
      );

  Future<List<MatrixOutgoingWorkJob>> enqueueVideoFiles({
    required List<MatrixOutgoingVideoFileRequest> requests,
  }) =>
      _enqueueVideoFiles(
        requests: requests,
        session: _captureOutgoingSession(),
      );

  Future<MatrixOutgoingWorkJob> _enqueueVideoFile({
    required String jobId,
    required MatrixOutgoingVideoFile video,
    required List<String> targetRoomIds,
    required _OutgoingSession session,
  }) async {
    if (jobId.isEmpty || video.id.isEmpty || targetRoomIds.isEmpty) {
      throw ArgumentError('Video forwarding requires an id and targets');
    }
    if (video._admitted) {
      throw ArgumentError('Video forwarding source was already admitted');
    }
    final existing = session.coordinator.job(jobId);
    if (existing != null) return existing;
    final targets =
        _freezeVideoTargets(await _prepareNewTargets(targetRoomIds, session));
    await video._waitForSourceMetadata();
    _ensureOutgoingSessionCurrent(session);
    final job = _buildVideoJob(
      jobId: jobId,
      video: video,
      targetRoomIds: targets,
      session: session,
    );
    return session.coordinator.enqueue(job, onAccepted: video._markAdmitted);
  }

  /// Atomically accepts several deferred gallery handles. No media-library
  /// callback is invoked here; each is resolved only when its owner job gains
  /// a bounded preparation slot.
  Future<List<MatrixOutgoingWorkJob>> _enqueueVideoFiles({
    required List<MatrixOutgoingVideoFileRequest> requests,
    required _OutgoingSession session,
  }) async {
    if (requests.isEmpty) return const [];
    final ids = <String>{};
    final videos = <MatrixOutgoingVideoFile>{};
    final frozen = <MatrixOutgoingVideoFileRequest>[];
    for (final request in requests) {
      if (request.jobId.isEmpty ||
          request.video.id.isEmpty ||
          request.targetRoomIds.isEmpty ||
          !ids.add(request.jobId) ||
          !videos.add(request.video) ||
          request.video._admitted ||
          session.coordinator.job(request.jobId) != null) {
        throw ArgumentError('Video forwarding requires new jobs and sources');
      }
      frozen.add(MatrixOutgoingVideoFileRequest(
        jobId: request.jobId,
        video: request.video,
        targetRoomIds: _freezeVideoTargets(
            await _prepareNewTargets(request.targetRoomIds, session)),
      ));
    }
    await Future.wait([
      for (final request in frozen) request.video._waitForSourceMetadata(),
    ]);
    _ensureOutgoingSessionCurrent(session);
    final jobs = [
      for (final request in frozen)
        _buildVideoJob(
          jobId: request.jobId,
          video: request.video,
          targetRoomIds: request.targetRoomIds,
          session: session,
        ),
    ];
    return session.coordinator.enqueueBatch(jobs, onAccepted: () {
      for (final request in frozen) {
        request.video._markAdmitted();
      }
    });
  }

  List<String> _freezeVideoTargets(List<String> targetRoomIds) {
    final targets = List<String>.unmodifiable(List<String>.from(targetRoomIds));
    if (targets.any((target) => target.isEmpty) ||
        targets.toSet().length != targets.length) {
      throw ArgumentError(
          'Video forwarding targets must be non-empty and unique');
    }
    return targets;
  }

  MatrixOutgoingWorkJob _buildVideoJob({
    required String jobId,
    required MatrixOutgoingVideoFile video,
    required List<String> targetRoomIds,
    required _OutgoingSession session,
  }) {
    final targets = _freezeVideoTargets(targetRoomIds);
    final snapshot = _DeferredOutgoingVideoSnapshot(video);
    final createdAt = DateTime.now();
    return MatrixOutgoingWorkJob(
      id: jobId,
      createdAt: createdAt,
      source: MatrixOutgoingWorkSource(
        id: 'video:$jobId:${video.id}',
        retainedBytes: 0,
        preparationBytes: _maxOutgoingVideoReservationBytes,
        prepare: snapshot.prepare,
        release: snapshot.release,
      ),
      items: [
        for (var targetIndex = 0; targetIndex < targets.length; targetIndex++)
          MatrixOutgoingWorkItem(
            id: '${video.id}:$targetIndex',
            targetRoomId: targets[targetIndex],
            txid: 'outgoing-$jobId-0-$targetIndex',
            presentation: MatrixOutgoingWorkPresentation(
              kind: MatrixOutgoingPresentationKind.video,
              text: video.body,
              mimeType: 'video/mp4',
              filename: video.filename,
              createdAt: createdAt,
            ),
            send: (attempt) => _sendOutgoingVideo(
              session: session,
              targetRoomId: targets[targetIndex],
              snapshot: snapshot,
              attempt: attempt,
            ),
          ),
      ],
    );
  }

  _OutgoingSession _captureOutgoingSession() {
    final active = _client;
    final accountId = active?.userID;
    if (_accessRevoked ||
        active == null ||
        accountId == null ||
        accountId.isEmpty ||
        !_outgoingWork.isActive ||
        _outgoingWork.accountId != accountId) {
      throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
    }
    return _OutgoingSession(
      client: active,
      accountId: accountId,
      deviceId: active.deviceID,
      coordinator: _outgoingWork,
    );
  }

  void _ensureOutgoingSession(
      _OutgoingSession session, MatrixOutgoingWorkAttempt attempt) {
    attempt.ensureActive();
    _ensureOutgoingSessionCurrent(session);
  }

  void _ensureOutgoingSessionCurrent(_OutgoingSession session) {
    if (_accessRevoked ||
        !identical(_client, session.client) ||
        !identical(_outgoingWork, session.coordinator) ||
        session.client.userID != session.accountId ||
        session.client.deviceID != session.deviceId) {
      throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
    }
  }

  Future<String> _sendOutgoingText({
    required _OutgoingSession session,
    required String targetRoomId,
    required Map<String, dynamic> content,
    required MatrixOutgoingWorkAttempt attempt,
  }) =>
      _withClient((active) async {
        _ensureOutgoingSession(session, attempt);
        if (!identical(active, session.client)) {
          throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
        }
        final target = active.getRoomById(targetRoomId);
        if (target == null || !target.encrypted) {
          throw StateError('只能发送到端到端加密会话');
        }
        if (target.membership != Membership.join ||
            !target.canSendDefaultMessages) {
          throw StateError('当前会话不可发送消息');
        }
        await _requireRoomSend(target);
        _ensureOutgoingSession(session, attempt);
        final eventId = await target.sendEvent(
          Map<String, dynamic>.from(content),
          txid: attempt.txid,
        );
        _ensureOutgoingSession(session, attempt);
        return eventId ??
            (throw StateError('Matrix room event was not accepted'));
      });

  Future<String> _sendOutgoingMedia({
    required _OutgoingSession session,
    required String targetRoomId,
    required _DeferredOutgoingMediaSnapshot snapshot,
    required MatrixOutgoingWorkAttempt attempt,
  }) =>
      _withClient((active) async {
        _ensureOutgoingSession(session, attempt);
        if (!identical(active, session.client)) {
          throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
        }
        final target = active.getRoomById(targetRoomId);
        if (target == null) throw StateError('Matrix room is not joined');
        _ensureOutgoingSession(session, attempt);
        final eventId = await _sendMedia(
          target,
          snapshot.bytes(),
          snapshot.mimeType,
          extraContent: _mutableJsonMap(snapshot.extraContent),
          txid: attempt.txid,
          filename: snapshot.filename,
          thumbnailBytes: snapshot.thumbnailBytes,
          thumbnailWidth: snapshot.thumbnailWidth,
          thumbnailHeight: snapshot.thumbnailHeight,
        );
        _ensureOutgoingSession(session, attempt);
        return eventId;
      });

  Future<String> _sendOutgoingVideo({
    required _OutgoingSession session,
    required String targetRoomId,
    required _DeferredOutgoingVideoSnapshot snapshot,
    required MatrixOutgoingWorkAttempt attempt,
  }) =>
      _withClient((active) async {
        _ensureOutgoingSession(session, attempt);
        if (!identical(active, session.client)) {
          throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
        }
        final target = active.getRoomById(targetRoomId);
        if (target == null) throw StateError('Matrix room is not joined');
        _ensureOutgoingSession(session, attempt);
        final eventId = await _sendMedia(
          target,
          snapshot.bytes(),
          snapshot.mimeType,
          extraContent: _mutableJsonMap(snapshot.extraContent),
          txid: attempt.txid,
          filename: snapshot.filename,
          thumbnailBytes: snapshot.thumbnailBytes,
          thumbnailWidth: snapshot.thumbnailWidth,
          thumbnailHeight: snapshot.thumbnailHeight,
        );
        _ensureOutgoingSession(session, attempt);
        return eventId;
      });

  Future<void> _prepareForwardMedia({
    required _OutgoingSession session,
    required _DeferredOutgoingForwardMediaSnapshot snapshot,
    required MatrixOutgoingWorkAttempt attempt,
  }) async {
    _ensureOutgoingSession(session, attempt);
    final source = session.client.getRoomById(snapshot.media.sourceRoomId);
    if (source == null ||
        !source.encrypted ||
        source.membership != Membership.join) {
      throw StateError('Matrix source room is not joined');
    }
    final media = snapshot.media;
    final original = media.wasEncrypted
        ? MatrixEvent(
            type: EventTypes.Encrypted,
            content: const {},
            senderId: media.senderId,
            eventId: media.sourceEventId,
            originServerTs: media.originServerTs,
          )
        : null;
    final event = Event(
      type: EventTypes.Message,
      content: media.content(),
      senderId: media.senderId,
      room: source,
      eventId: media.sourceEventId,
      originServerTs: media.originServerTs,
      originalSource: original,
    );
    final bytes = await loadMediaWithCache(
      MediaCacheKey(
        accountId: session.accountId,
        roomId: media.sourceRoomId,
        eventId: media.sourceEventId,
        contentSha256: media.contentSha256,
        sourceIdentity: matrixMediaSourceIdentity(event.content),
      ),
      () => downloadMediaContentBounded(
        event,
        maxDownloadBytes: media.downloadLimitBytes,
      ),
    );
    if (bytes.length > snapshot.media.downloadLimitBytes) {
      throw const MatrixOutgoingFileTooLargeException();
    }
    Uint8List? thumbnail;
    if (media.thumbnailSha256 != null || event.isThumbnailEncrypted) {
      try {
        thumbnail = await loadMediaWithCache(
          MediaCacheKey(
            accountId: session.accountId,
            roomId: media.sourceRoomId,
            eventId: 'thumb:${media.sourceEventId}',
            contentSha256: media.thumbnailSha256,
            sourceIdentity:
                matrixMediaSourceIdentity(event.content, thumbnail: true),
          ),
          () => downloadMediaContentBounded(
            event,
            thumbnail: true,
            maxDownloadBytes: _maxOutgoingVideoPosterBytes,
          ),
        );
        if (thumbnail.lengthInBytes > _maxOutgoingVideoPosterBytes) {
          thumbnail = null;
        }
      } on MediaContentLimitException {
        thumbnail = null;
      }
    }
    _ensureOutgoingSession(session, attempt);
    snapshot
      .._bytes = bytes
      .._thumbnail = thumbnail;
  }

  Future<String> _sendOutgoingForwardMedia({
    required _OutgoingSession session,
    required String targetRoomId,
    required _DeferredOutgoingForwardMediaSnapshot snapshot,
    required MatrixOutgoingWorkAttempt attempt,
  }) =>
      _withClient((active) async {
        _ensureOutgoingSession(session, attempt);
        if (!identical(active, session.client)) {
          throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
        }
        final target = active.getRoomById(targetRoomId);
        if (target == null) throw StateError('Matrix room is not joined');
        final media = snapshot.media;
        final eventId = await _sendMedia(
          target,
          snapshot.bytes(),
          media.mimeType,
          extraContent: _mutableJsonMap(media.extraContent),
          txid: attempt.txid,
          filename: media.filename,
          thumbnailBytes: snapshot.thumbnail,
          thumbnailWidth: media.thumbnailWidth,
          thumbnailHeight: media.thumbnailHeight,
        );
        _ensureOutgoingSession(session, attempt);
        return eventId;
      });

  @visibleForTesting
  String? get debugActiveClientName => _client?.clientName;
  String? _lastRecoveryKey;

  /// Recovery key is exposed only to the caller so it can be written to the
  /// platform secure store; it is never sent to the business API.
  String? get lastRecoveryKey => _lastRecoveryKey;
  @override
  bool get isLoggedIn =>
      _client?.isLogged() ??
      _suspendedMetadata?.isLoggedIn ??
      _suspendedIdentity?.isLoggedIn ??
      false;

  /// 语义：本地保留/恢复出来的 Matrix token 目前不可信，必须先经过 broker
  /// token 刷新才能使用。它不等于"已登出"——恢复已有账号后
  /// [selectAccount] 会把它置为 true，正是为了让随后的保留身份刷新路径
  /// （`loginWithToken`）接管并换发新 token；刷新成功后必须复位为 false。
  @override
  bool get credentialsInvalid =>
      _credentialsInvalid ||
      _client?.onLoginStateChanged.value == LoginState.softLoggedOut;
  @override
  String? get userId {
    final active = _client;
    if (active != null) return active.userID;
    return _suspendedMetadata?.userId ?? _suspendedIdentity?.userId;
  }

  @override
  String? get deviceId {
    final active = _client;
    if (active != null) return active.deviceID;
    return _suspendedMetadata?.deviceId ?? _suspendedIdentity?.deviceId;
  }

  @override
  Future<void> login(String userId, String password) =>
      _withClient((active) async {
        await active.checkHomeserver(homeserver);
        await active.login('m.login.password',
            identifier: AuthenticationUserIdentifier(user: userId),
            password: password,
            initialDeviceDisplayName: '畅聊移动端');
        await _persistLoggedInContinuity(active);
      }, authorizeAccess: true, freshLogin: true);

  @override
  Future<void> loginWithToken(
          {required String loginToken,
          required Uri homeserver,
          String? deviceId}) =>
      _withClient((active) async {
        await active.checkHomeserver(homeserver);
        if (active.userID != null && active.deviceID != null) {
          _credentialsInvalid = true;
          final expectedUserId = active.userID;
          final expectedDeviceId = active.deviceID;
          if (expectedUserId == null || expectedDeviceId == null) {
            throw StateError('Matrix continuity identity is unavailable');
          }
          // 调用方传进来的 device id 只是"保留身份"的提示。它来自挂起时的观察值，
          // 而本机库可能已经在上一次轮换里被服务端改写。真正能刷新的设备是本进程
          // 持有的这个 client，因此以它为权威；把陈旧提示当成硬失败会让账号
          // 永久卡在 L04（重启才会自愈）。
          if (deviceId != null && deviceId != expectedDeviceId) {
            securityLogger.record(
              stage: MatrixSecurityStage.deviceRotation,
              outcome: MatrixSecurityOutcome.success,
              eventCode: MatrixSecurityCode.deviceRotationDetected,
              identity: _identity(
                matrixUserId: expectedUserId,
                deviceId: expectedDeviceId,
                previousDeviceId: deviceId,
              ),
            );
          }
          final response = await MatrixApi(
            homeserver: homeserver,
            httpClient: active.httpClient,
          ).login(
            'm.login.token',
            token: loginToken,
            deviceId: expectedDeviceId,
            initialDeviceDisplayName: active.deviceName ?? '畅聊移动端',
          );
          if (response.userId != expectedUserId) {
            throw StateError('Matrix credential refresh identity mismatch');
          }
          // 单设备策略下服务端可能轮换 device id（本机在别处登录后旧设备
          // 被顶掉，典型：iOS 覆盖安装后强制重登）。token 已证明账号归属，
          // 此时采纳服务端权威 device id 并继续；拒绝会造成无法恢复的 L04。
          // LoginResponse.deviceId is non-null per spec; keep the fallback
          // off the analyzer's dead-null path by using it directly.
          final adoptedDeviceId = response.deviceId;
          active.onLoginStateChanged.add(LoginState.softLoggedOut);
          await active.init(
            newToken: response.accessToken,
            newTokenExpiresAt: response.expiresInMs == null
                ? null
                : DateTime.now().add(
                    Duration(milliseconds: response.expiresInMs!),
                  ),
            newRefreshToken: response.refreshToken,
            newHomeserver: homeserver,
            newUserID: expectedUserId,
            newDeviceID: adoptedDeviceId,
            newDeviceName: active.deviceName ?? '畅聊移动端',
          );
          // 刷新前的 softLoggedOut 过渡标记在凭据采纳后恢复 loggedIn，
          // 否则 credentialsInvalid 恒为 true（登录页会一直显示 L04）。
          active.onLoginStateChanged.add(LoginState.loggedIn);
          // Revoking a remote device removes its public keys. Re-register the
          // retained identity, without generating a replacement Olm account.
          final encryption = active.encryption;
          if (encryption != null &&
              !await encryption.olmManager.uploadKeys(
                  uploadDeviceKeys: true,
                  oldKeyCount: null,
                  unusedFallbackKey: null)) {
            throw StateError('Matrix device key registration failed');
          }
          // 服务端已通过 token 登录证明账号归属，因此这次 device 轮换是权威的。
          // 必须把 ChatFlow 自己维护的 MatrixLocalBinding 一起原子迁移，否则
          // 紧接着的 continuity 校验会看到
          // client.deviceID=device-NEW / binding.deviceId=device-OLD 而抛错（L04），
          // 并把本机库留在"库已新、绑定仍旧"的状态上，让下一次 selectAccount
          // 也永久失败（L07）。
          if (adoptedDeviceId != expectedDeviceId) {
            final rotate = _rotateDeviceBinding;
            if (rotate != null) {
              await rotate(
                active,
                expectedUserId: expectedUserId,
                previousDeviceId: expectedDeviceId,
                nextDeviceId: adoptedDeviceId,
              );
            }
          }
        } else {
          await active.login(
            'm.login.token',
            token: loginToken,
            deviceId: deviceId,
            initialDeviceDisplayName: '畅聊移动端',
          );
        }
        _credentialsInvalid = false;
        await _persistLoggedInContinuity(active);
      }, authorizeAccess: true, freshLogin: true);

  Future<void> _persistLoggedInContinuity(Client active) async {
    _activeContinuityValidated = false;
    _bindDecryptionCache(await _readContinuityMetadata(active));
    _ensureOutgoingWorkIdentity(active);
    _activeContinuityValidated = true;
  }

  Stream<void> get syncEvents => _syncEvents.stream;
  Stream<MatrixDecryptionUpdate> get decryptionUpdates =>
      _decryptionUpdates.stream;

  void _bindDecryptionCache(MatrixClientContinuityMetadata next) {
    final previous = _decryptionCacheContinuity;
    if (previous != null && !previous.hasSameContinuity(next)) {
      _decryptedTimelineEvents.clear();
      _lastRecoveryKey = null;
    }
    _decryptionCacheContinuity = next;
  }

  void _attachDecryptionListener(Client client) {
    _decryptionSubscription?.cancel();
    _decryptionSubscription = client.onEvent.stream.listen((update) {
      if (_accessRevoked || !identical(client, _client)) return;
      final eventId = update.content['event_id']?.toString();
      if (eventId == null || eventId.isEmpty) return;
      final type = update.content['type']?.toString();
      if (update.type == EventUpdateType.decryptedTimelineQueue &&
          type != EventTypes.Encrypted) {
        _decryptedTimelineEvents[(client.userID, update.roomID, eventId)] =
            Map<String, dynamic>.from(update.content);
      }
      final state = type != EventTypes.Encrypted
          ? MessageDecryptionState.decrypted
          : (update.content['can_request_session'] == true
              ? MessageDecryptionState.missingKey
              : MessageDecryptionState.decrypting);
      _decryptionUpdates.add(MatrixDecryptionUpdate(eventId, state));
      _syncEvents.add(null);
    });
  }

  void _attachOutgoingEchoListener(Client client) {
    _outgoingEchoSubscription?.cancel();
    final work = _outgoingWork;
    final userId = client.userID;
    final deviceId = client.deviceID;
    _outgoingEchoSubscription = client.onEvent.stream.listen((update) {
      if (_accessRevoked ||
          !identical(client, _client) ||
          !identical(work, _outgoingWork) ||
          client.userID != userId ||
          client.deviceID != deviceId) {
        return;
      }
      if (!{
        EventUpdateType.timeline,
        EventUpdateType.history,
        EventUpdateType.decryptedTimelineQueue,
      }.contains(update.type)) {
        return;
      }
      final content = update.content;
      final type = content['type']?.toString();
      final isDecryptedMessage = type == EventTypes.Message;
      final isEncryptedTimeline = type == EventTypes.Encrypted &&
          update.type != EventUpdateType.decryptedTimelineQueue;
      // Encrypted rows may be the first stored representation of our event;
      // their decrypted queue update arrives separately. Never inspect media
      // or plaintext here: identifiers and sender are sufficient.
      if ((!isDecryptedMessage && !isEncryptedTimeline) ||
          content['sender']?.toString() != userId) {
        return;
      }
      final unsigned = content['unsigned'];
      final localStatus = content['status'] ??
          (unsigned is Map ? unsigned[messageSendingStatusKey] : null);
      // A local optimistic row has a negative sending/error status. Only a
      // synced SDK fact (or a status-less server event) can settle work.
      if (localStatus is num &&
          localStatus.toInt() != EventStatus.synced.intValue) {
        return;
      }
      final eventId = content['event_id']?.toString();
      if (eventId == null || eventId.isEmpty || !eventId.startsWith(r'$')) {
        return;
      }
      final transactionId =
          unsigned is Map ? unsigned['transaction_id']?.toString() : null;
      final pending = work.itemsForRoom(update.roomID);
      if (pending.isEmpty) return;
      final matches = pending.any((item) =>
          item.txid == transactionId ||
          item.eventId == eventId ||
          (transactionId == null &&
              item.state == MatrixOutgoingWorkState.sending));
      if (!matches) return;
      scheduleMicrotask(() {
        // Give the timeline subscriber a turn first. The capture also makes a
        // same-Client re-login unable to acknowledge the replacement owner.
        if (_accessRevoked ||
            !identical(client, _client) ||
            !identical(work, _outgoingWork) ||
            client.userID != userId ||
            client.deviceID != deviceId ||
            !work.isActive) {
          return;
        }
        work.acknowledgeEchoes([
          MatrixOutgoingWorkEcho(
            roomId: update.roomID,
            eventId: eventId,
            transactionId: transactionId,
          ),
        ]);
      });
    });
  }

  void _attachMemberRefreshListener(Client client) {
    _memberRefreshListener?.cancel();
    _memberRefreshPolicy.reset();
    _memberProjectionCache.attach(client);
    // onEvent excludes local participant-cache hydration; TTL reconciliation
    // covers member state changes that do not arrive through an SDK sync event.
    _memberRefreshListener = client.onEvent.stream.listen((update) {
      if (identical(client, _client) &&
          (update.type == EventUpdateType.state ||
              update.type == EventUpdateType.timeline) &&
          update.content['type'] == EventTypes.RoomMember) {
        _memberRefreshPolicy.bindAccount(client.userID);
        _memberRefreshPolicy.markDirty(update.roomID);
      }
    });
  }

  Future<void> _detachMemberRefreshListener() async {
    await _memberRefreshListener?.cancel();
    _memberRefreshListener = null;
    _memberRefreshPolicy.reset();
    await _memberProjectionCache.detach();
  }

  @override
  Future<void> sync() => _withClient(_syncActiveClient, authorizeAccess: true);

  /// Background work may sync only while the session is already authorized.
  Future<void> syncIfActive() => _withClient(_syncActiveClient);

  Future<void> _syncActiveClient(Client active) async {
    try {
      await active.sync();
      await active.encryption?.keyManager
          .uploadInboundGroupSessions(skipIfInProgress: true);
      _syncEvents.add(null);
    } on MatrixException catch (error) {
      if (error.errcode == 'M_UNKNOWN_TOKEN' ||
          error.errcode == 'M_FORBIDDEN') {
        _credentialsInvalid = true;
      }
      rethrow;
    }
  }

  @override
  Future<RecoveryBootstrapResult> bootstrapOnlineBackup(
          {String? recoveryKey}) =>
      _withClient((active) async {
        final encryption = active.encryption;
        if (encryption == null) {
          throw StateError('Matrix encryption is not enabled');
        }
        if (recoveryKey != null) {
          final handle = encryption.ssss.open();
          await handle.unlock(recoveryKey: recoveryKey);
          await handle.maybeCacheAll();
        }
        return await encryption.keyManager.isCached()
            ? RecoveryBootstrapResult.reused
            : RecoveryBootstrapResult.needsSecretStorageUnlock;
      });

  @override
  Future<void> unlockSecretStorage(String recoveryKey) =>
      _withClient((active) async {
        final encryption = active.encryption;
        if (encryption == null) {
          throw StateError('Matrix encryption is not enabled');
        }
        final handle = encryption.ssss.open();
        await handle.unlock(recoveryKey: recoveryKey);
        await handle.maybeCacheAll();
      });

  @override
  Future<bool> backupKeyMatchesCurrentVersion() => _withClient((active) async {
        final encryption = active.encryption;
        if (encryption == null) return false;
        return encryption.keyManager.isCached();
      });

  @override
  Future<void> restoreAllInboundSessions() => _withClient((active) async {
        final encryption = active.encryption;
        if (encryption == null) {
          throw StateError('Matrix encryption is not enabled');
        }
        await encryption.keyManager.loadAllKeys();
      });

  @override
  Future<void> uploadPendingInboundSessions() => _withClient((active) async {
        await active.encryption?.keyManager
            .uploadInboundGroupSessions(skipIfInProgress: true);
      });

  @override
  Future<void> suspend() {
    _beginSuspensionRevocation();
    return _serializeLifecycle(_suspendWithinLifecycle);
  }

  /// 同步撤销对外能力。必须在进入串行区之前完成，避免等待期间被继续使用。
  void _beginSuspensionRevocation() {
    _accessRevoked = true;
    _outgoingWork.revoke('Matrix session suspended');
    _revokeManagedResources();
  }

  /// 挂起是一次安全关闭，必须必达。
  ///
  /// 顺序固定为：撤销访问 → 尽力 drain → 尽力读取 continuity（失败只记录）
  /// → detach → dispose → 清空 [_client] → 记录观察到的身份与连续性判定。
  ///
  /// 只有底层 client 自己的 dispose 失败才允许中断关闭；诊断与可选的 continuity
  /// 读取都不得阻止它。此前 continuity 读取失败会让整个 suspend 抛错，留下
  /// 「`_accessRevoked=true` 而 client 未关闭、数据库仍打开」的半挂起态，之后
  /// 每一次 selectAccount 都再次失败，表现为 account_storage 阶段 L07。
  /// 关闭安全与连续性信任必须分开：关闭失败 → 抛错保留句柄以便重试；
  /// continuity 读取失败 → 记录为 [MatrixSuspendedContinuity.unknown]，绝不假装已验证。
  Future<void> _suspendWithinLifecycle() async {
    final active = _client;
    if (active == null) return;
    securityLogger.beginLifecycleOperation();
    securityLogger.record(
      stage: MatrixSecurityStage.lifecycle,
      outcome: MatrixSecurityOutcome.success,
      eventCode: MatrixSecurityCode.lifecycleSuspendBegin,
    );
    try {
      await _waitForClientOperationsToDrain();
    } on TimeoutException {
      securityLogger.record(
        stage: MatrixSecurityStage.lifecycle,
        outcome: MatrixSecurityOutcome.timeout,
        eventCode: MatrixSecurityCode.lifecycleSuspendDrainTimeout,
      );
    } catch (_) {
      securityLogger.record(
        stage: MatrixSecurityStage.lifecycle,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.lifecycleDrainTimeout,
      );
    }
    // Reopening the retained store can restore the old token from disk.
    // Keep its invalid status after the SDK object and stream are disposed.
    _credentialsInvalid = credentialsInvalid;
    _decryptedTimelineEvents.clear();
    _lastRecoveryKey = null;
    final identity = (
      userId: active.userID,
      deviceId: active.deviceID,
      isLoggedIn: active.isLogged(),
    );
    MatrixClientContinuityMetadata? metadata;
    var continuity = MatrixSuspendedContinuity.unknown;
    try {
      metadata = await _readContinuityMetadata(active);
      continuity = MatrixSuspendedContinuity.validated;
    } catch (_) {
      // 关闭照常继续；这里只记下"连续性未能验证"。
      securityLogger.record(
        stage: MatrixSecurityStage.lifecycle,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.lifecycleContinuityReadFailed,
        identity: _identity(
          matrixUserId: identity.userId,
          deviceId: identity.deviceId,
        ),
      );
    }
    try {
      await _detachMemberRefreshListener();
      await _detachManagedSubscriptions();
      await _detachManagedResources();
    } catch (error, stackTrace) {
      // 资源撤销失败：底层组件已经记录了自己的事件，这里恢复句柄以便重试，
      // 并且不再尝试关闭——否则会在资源仍在使用时关闭数据库。
      _attachMemberRefreshListener(active);
      await _attachManagedResources(active);
      await _attachManagedSubscriptions(active);
      Error.throwWithStackTrace(error, stackTrace);
    }
    securityLogger.record(
      stage: MatrixSecurityStage.lifecycle,
      outcome: MatrixSecurityOutcome.success,
      eventCode: MatrixSecurityCode.lifecycleClientDisposeBegin,
      identity: _identity(
        matrixUserId: identity.userId,
        deviceId: identity.deviceId,
      ),
    );
    try {
      await _suspendClient(active);
    } catch (error, stackTrace) {
      // 只有这里才允许中断挂起：client 自身关闭失败必须保留句柄并让调用方看到，
      // 以便重试；绝不能假装已经挂起。
      securityLogger.record(
        stage: MatrixSecurityStage.lifecycle,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: metadata == null
            ? MatrixSecurityCode.lifecycleSuspendCloseFailed
            : MatrixSecurityCode.lifecycleClientDisposeFailed,
        identity: _identity(
          matrixUserId: identity.userId,
          deviceId: identity.deviceId,
        ),
      );
      await _attachManagedResources(active);
      await _attachManagedSubscriptions(active);
      _attachMemberRefreshListener(active);
      Error.throwWithStackTrace(error, stackTrace);
    }
    _client = null;
    _suspendedIdentity = identity;
    _suspendedMetadata = metadata;
    _suspendedContinuity = continuity;
    securityLogger.record(
      stage: MatrixSecurityStage.lifecycle,
      outcome: MatrixSecurityOutcome.success,
      eventCode: MatrixSecurityCode.lifecycleSuspendCompleted,
      identity: _identity(
        matrixUserId: identity.userId,
        deviceId: identity.deviceId,
      ),
    );
  }

  @override
  Future<void> selectAccount(String matrixUserId, Uri selectedHomeserver) {
    final operation = _accountSelectionQueue
        .then((_) => _selectAccount(matrixUserId, selectedHomeserver));
    _accountSelectionQueue =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  /// 账号切换是一个临界区：撤销旧能力、关闭旧 client、切换安全存储 scope、
  /// 打开目标账号的库、校验连续性，全部串行完成。
  ///
  /// 若把 suspend 留在临界区之外，bootstrap/后台恢复的并发 suspend 就可能插进
  /// 「A 已关闭、B 尚未打开」之间，或让 scope 已经切到 B 而 client 仍属于 A。
  Future<void> _selectAccount(
      String matrixUserId, Uri selectedHomeserver) async {
    final select = _selectClientAccount;
    final resume = _resumeClient;
    if (select == null || resume == null || selectedHomeserver != homeserver) {
      throw StateError('Retained account storage is not configured');
    }
    _beginSuspensionRevocation();
    securityLogger.beginLifecycleOperation();
    securityLogger.record(
      stage: MatrixSecurityStage.accountSelection,
      outcome: MatrixSecurityOutcome.success,
      eventCode: MatrixSecurityCode.accountSelectBegin,
      identity: _identity(matrixUserId: matrixUserId),
    );
    await _serializeLifecycle(() async {
      await _suspendWithinLifecycle();
      // Old UI capabilities must never be rebound to another identity.
      for (final registration in _managedSubscriptions) {
        registration.canceled = true;
      }
      for (final resource in _managedResources) {
        resource.canceled = true;
      }
      _managedSubscriptions.clear();
      _managedResources.clear();
      _suspendedMetadata = null;
      _suspendedIdentity = null;
      _suspendedContinuity = MatrixSuspendedContinuity.none;
      _activeContinuityValidated = false;
      try {
        await select(selectedHomeserver.toString(), matrixUserId);
      } catch (error, stackTrace) {
        securityLogger.record(
          stage: MatrixSecurityStage.accountSelection,
          outcome: MatrixSecurityOutcome.failure,
          eventCode: MatrixSecurityCode.accountSelectResumeFailed,
          identity: _identity(matrixUserId: matrixUserId),
        );
        Error.throwWithStackTrace(error, stackTrace);
      }
      final next = await resume();
      try {
        if (next.userID != null && next.userID != matrixUserId) {
          throw StateError(
              'Stored Matrix identity does not match authenticated account');
        }
        final metadata = await _readContinuityMetadata(next);
        _client = next;
        _replaceOutgoingWork(next);
        _suspendedMetadata = metadata;
        _activeContinuityValidated = true;
        // 语义：刚从库里恢复出来的 token 不可信，必须先经过 broker token 刷新
        // （保留身份刷新路径）。它不是"已登出"，刷新成功后会被复位为 false。
        _credentialsInvalid = next.isLogged();
        _freshLoginAfterClear = false;
        _localHistoryStore = null;
        _decryptedTimelineEvents.clear();
        _lastRecoveryKey = null;
        _bindDecryptionCache(metadata);
        _attachOutgoingEchoListener(next);
        _attachDecryptionListener(next);
        _attachMemberRefreshListener(next);
      } catch (error, stackTrace) {
        // 目标账号的连续性未能确认：绝不发布这个 client，也不留下
        // "scope 已切换但没有任何身份"的半成品状态。
        _client = null;
        _suspendedMetadata = null;
        _suspendedIdentity = null;
        _activeContinuityValidated = false;
        securityLogger.record(
          stage: MatrixSecurityStage.accountSelection,
          outcome: MatrixSecurityOutcome.failure,
          eventCode: MatrixSecurityCode.accountSelectContinuityMismatch,
          identity: _identity(
            matrixUserId: next.userID ?? matrixUserId,
            deviceId: next.deviceID,
          ),
        );
        try {
          await _suspendClient(next);
        } catch (_) {
          _pendingCloseClient = next;
          securityLogger.record(
            stage: MatrixSecurityStage.accountSelection,
            outcome: MatrixSecurityOutcome.failure,
            eventCode: MatrixSecurityCode.lifecycleClientDisposeFailed,
            identity: _identity(
              matrixUserId: next.userID ?? matrixUserId,
              deviceId: next.deviceID,
            ),
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
  }

  Future<({String token, String deviceId})> currentSessionCredentials() =>
      _withClient((client) async {
        final token = client.accessToken;
        final deviceId = client.deviceID;
        if (token == null || deviceId == null) {
          throw StateError('Matrix session is unavailable');
        }
        return (token: token, deviceId: deviceId);
      });

  String? _localPreferenceAccountIdToClear;

  /// 闪照 tombstone 的账号 key 与 `RoomPage` 保持同源（`matrix:<userId>`）。
  static String _flashViewedAccountKey(String matrixUserId) =>
      'matrix:$matrixUserId';

  /// Destructively removes this device's Matrix session and encrypted store.
  /// Only a separately confirmed local-clear flow may call it.
  @override
  Future<void> clearLocalChatData() {
    _accessRevoked = true;
    _outgoingWork.revoke('Matrix local data cleared');
    _decryptedTimelineEvents.clear();
    _decryptionCacheContinuity = null;
    _lastRecoveryKey = null;
    _revokeManagedResources();
    // 账号级资源：控制房间登记不得跨账号累积（房间号全局唯一，泄漏本身
    // 无害，但登出/清库是唯一正确的清理点）。
    ControlRoomRegistry.clear();
    return _serializeLifecycle(() async {
      final target = _client ?? _pendingCloseClient;
      _localPreferenceAccountIdToClear ??=
          target?.userID ?? _suspendedMetadata?.userId;
      await _waitForClientOperationsToDrain();
      _decryptedTimelineEvents.clear();
      _lastRecoveryKey = null;
      try {
        await _detachMemberRefreshListener();
        await _detachManagedSubscriptions();
        await _detachManagedResources();
      } catch (error, stackTrace) {
        if (target != null) {
          _attachMemberRefreshListener(target);
          await _attachManagedResources(target);
          await _attachManagedSubscriptions(target);
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      for (final registration in _managedSubscriptions) {
        registration.canceled = true;
      }
      _managedSubscriptions.clear();
      for (final resource in _managedResources) {
        resource.canceled = true;
      }
      _managedResources.clear();
      _client = null;
      _pendingCloseClient = target;
      _clearFailed = true;
      if (_localPreferenceAccountIdToClear != null) {
        await MediaCache.clearAccount(_localPreferenceAccountIdToClear!);
        // 本地加密库被整体删除 = 闪照消息本身不再存在于设备上。
        // 这是 tombstone 唯一的账号级真实清理点：清空后重新登录不会因为
        // 旧的「已查看」标记而误锁一条全新的闪照。
        // 注意：普通登出（suspend）明确保留加密库，**不得**走这条路径。
        await FlashPhotoViewedStore.clearAccount(
            _flashViewedAccountKey(_localPreferenceAccountIdToClear!));
      }
      await clearLocalConversationPreferences(
          _localPreferenceAccountIdToClear, target);
      await _clearClientData(target);
      _localPreferenceAccountIdToClear = null;
      _pendingCloseClient = null;
      _suspendedMetadata = null;
      _suspendedIdentity = null;
      _suspendedContinuity = MatrixSuspendedContinuity.none;
      _activeContinuityValidated = false;
      _clearFailed = false;
      _freshLoginAfterClear = true;
    });
  }

  Future<T> _withClient<T>(
    Future<T> Function(Client client) operation, {
    bool authorizeAccess = false,
    bool freshLogin = false,
  }) async {
    if (_accessRevoked && !authorizeAccess) {
      throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
    }
    late Client active;
    await _serializeLifecycle(() async {
      if (_accessRevoked && !authorizeAccess) {
        throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
      }
      if (authorizeAccess) _accessRevoked = false;
      active = await _resumeWithinLifecycle(freshLogin: freshLogin);
      _beginClientOperation();
    });
    try {
      return await operation(active);
    } finally {
      _finishClientOperation();
    }
  }

  void _beginClientOperation() {
    if (_inFlightClientOperations++ == 0) {
      _clientOperationsDrained = Completer<void>();
    }
  }

  void _finishClientOperation() {
    if (--_inFlightClientOperations == 0) {
      _clientOperationsDrained?.complete();
      _clientOperationsDrained = null;
    }
  }

  Future<void> _waitForClientOperationsToDrain() async {
    final drained = _clientOperationsDrained;
    if (drained == null) return;
    try {
      await drained.future.timeout(lifecycleDrainTimeout);
    } on TimeoutException {
      securityLogger.record(
        stage: MatrixSecurityStage.lifecycle,
        outcome: MatrixSecurityOutcome.timeout,
        eventCode: MatrixSecurityCode.lifecycleDrainTimeout,
      );
      throw StateError('E2EE_LIFECYCLE_DRAIN_TIMEOUT');
    }
  }

  void _requireLifecycleAccess() {
    if (_accessRevoked) {
      throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
    }
  }

  Future<MatrixManagedSubscription> _registerInternalStream<T>({
    required Stream<T> Function(Client client) streamFor,
    required void Function(T event) onData,
  }) =>
      _serializeLifecycle(() async {
        _requireLifecycleAccess();
        final active = await _resumeWithinLifecycle();
        final registration = _ManagedClientStream<T>(
          owner: this,
          streamFor: streamFor,
          onData: onData,
        );
        await registration.attach(active);
        _managedSubscriptions.add(registration);
        return registration;
      });

  Future<MatrixManagedResource> _registerInternalResource({
    required Future<void> Function(Client client) open,
    required Future<void> Function() close,
    void Function()? revoke,
  }) =>
      _serializeLifecycle(() async {
        _requireLifecycleAccess();
        final active = await _resumeWithinLifecycle();
        final resource = _ManagedClientResource(
          owner: this,
          open: open,
          close: close,
          revoke: revoke,
        );
        await resource.attach(active);
        _managedResources.add(resource);
        return resource;
      });

  Future<MatrixManagedResource> registerAppHomeResource({
    required Future<void> Function(MatrixAppHomeCapability capability) open,
    required Future<void> Function() close,
  }) {
    _SdkAppHomeCapability? capability;
    return _registerInternalResource(
      open: (client) async {
        final next = _SdkAppHomeCapability(this, client);
        capability = next;
        try {
          await open(next);
        } finally {
          next._opening = false;
        }
      },
      revoke: () => capability?.revoke(),
      close: () async {
        capability?.revoke();
        capability = null;
        await close();
      },
    );
  }

  Future<MatrixManagedResource> registerVerificationLifecycle({
    required Future<void> Function() open,
    required Future<void> Function() close,
    required void Function() revoke,
  }) =>
      _registerInternalResource(
        open: (_) => open(),
        close: close,
        revoke: revoke,
      );

  Future<MatrixManagedSubscription> subscribeSasRequests({
    required void Function(MatrixSasRequestHandle request) onData,
    Stream<MatrixSasRequestHandle> Function()? testSource,
  }) =>
      _registerInternalStream<MatrixSasRequestHandle>(
        streamFor: (client) =>
            testSource?.call() ??
            client.onKeyVerificationRequest.stream
                .map(_SdkSasRequestHandle.new),
        onData: (request) => onData(_TrackedSasRequestHandle(this, request)),
      );

  Future<void> startSasRequest(
    String userId, {
    String? deviceId,
    required void Function(MatrixSasRequestHandle request) onStarted,
  }) =>
      _withClient((client) async {
        final encryption = client.encryption;
        if (encryption == null) {
          throw StateError('Matrix encryption is disabled');
        }
        final request = KeyVerification(
          encryption: encryption,
          userId: userId,
          deviceId: deviceId,
        );
        final handle = _TrackedSasRequestHandle(
          this,
          _SdkSasRequestHandle(request),
        );
        try {
          await request.start();
          onStarted(handle);
        } catch (_) {
          handle.dispose();
          rethrow;
        }
      });

  @override
  Future<ResolvedAvatarUrl?> resolveAvatar({
    required Uri? avatarUri,
    required double size,
  }) =>
      _withClient(
        (client) => MatrixAvatarUrlResolver.resolveForClient(
          avatarUri: avatarUri,
          client: client,
          size: size,
        ),
      );

  Future<MatrixRoomLease> openRoomLease(String roomId) =>
      _serializeLifecycle(() async {
        _requireLifecycleAccess();
        final active = await _resumeWithinLifecycle();
        if (active.userID != null) await _loadLocalHistory(active);
        final lease = MatrixRoomLease._(this, roomId);
        await lease.attach(active);
        _managedResources.add(lease);
        return lease;
      });

  Future<void> _cancelManagedResource(_ManagedClientResourceBase resource) =>
      _serializeLifecycle(() async {
        await resource.detach();
        resource.canceled = true;
        _managedResources.remove(resource);
      });

  Future<void> _detachManagedResources() async {
    for (final resource in _managedResources.reversed) {
      await resource.detach();
    }
  }

  void _revokeManagedResources() {
    for (final resource in _managedResources) {
      if (resource case final _ManagedClientResource managed) {
        managed.revokeNow();
      } else if (resource case final MatrixRoomLease lease) {
        lease.revokeNow();
      }
    }
  }

  Future<void> _attachManagedResources(Client client) async {
    try {
      for (final resource in _managedResources) {
        await resource.attach(client);
      }
    } catch (error, stackTrace) {
      await _detachManagedResources();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _cancelManagedSubscription(
    _ManagedClientStreamBase registration,
  ) =>
      _serializeLifecycle(() async {
        await registration.detach();
        registration.canceled = true;
        _managedSubscriptions.remove(registration);
      });

  Future<void> _detachManagedSubscriptions() async {
    for (final registration in _managedSubscriptions) {
      await registration.detach();
    }
  }

  Future<void> _attachManagedSubscriptions(Client client) async {
    try {
      for (final registration in _managedSubscriptions) {
        await registration.attach(client);
      }
    } catch (error, stackTrace) {
      await _detachManagedSubscriptions();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<T> _serializeLifecycle<T>(Future<T> Function() operation) {
    final result = _lifecycleTail.then<T>((_) => operation());
    _lifecycleTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<Client> _resumeWithinLifecycle({bool freshLogin = false}) async {
    final active = _client;
    if (active != null) {
      if (!_activeContinuityValidated) {
        _bindDecryptionCache(await _readContinuityMetadata(active));
        _activeContinuityValidated = true;
      }
      return active;
    }
    if (_clearFailed) {
      throw StateError('Matrix local clear must be retried before resume');
    }
    await _closePendingClient();
    final resume = _resumeClient;
    if (resume == null) {
      throw StateError('Matrix client resume is not configured');
    }
    final resumed = await resume();
    late final MatrixClientContinuityMetadata resumedMetadata;
    try {
      resumedMetadata = await _readContinuityMetadata(resumed);
    } catch (error, stackTrace) {
      await _rejectResumeClient(resumed);
      Error.throwWithStackTrace(error, stackTrace);
    }
    final suspendedMetadata = _suspendedMetadata;
    final allowedFreshLogin = freshLogin &&
        _freshLoginAfterClear &&
        suspendedMetadata == null &&
        !resumedMetadata.isLoggedIn &&
        resumedMetadata.userId == null &&
        resumedMetadata.deviceId == null &&
        resumedMetadata.ed25519Fingerprint == null;
    if (!allowedFreshLogin &&
        (suspendedMetadata == null ||
            !suspendedMetadata.hasSameContinuity(resumedMetadata))) {
      securityLogger.record(
        stage: MatrixSecurityStage.continuity,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: suspendedMetadata == null
            ? MatrixSecurityCode.continuityResumeUnverified
            : _continuityMismatchCode(suspendedMetadata, resumedMetadata),
        identity: _identity(
          matrixUserId: resumedMetadata.userId,
          deviceId: resumedMetadata.deviceId,
          previousDeviceId: suspendedMetadata?.deviceId,
          databaseGeneration: resumedMetadata.databaseGeneration,
          fingerprint: resumedMetadata.ed25519Fingerprint,
        ),
      );
      await _rejectResumeClient(resumed);
      throw StateError('Matrix client resumed with a different identity');
    }
    try {
      await _attachManagedResources(resumed);
      await _attachManagedSubscriptions(resumed);
    } catch (error, stackTrace) {
      await _detachManagedSubscriptions();
      await _detachManagedResources();
      await _rejectResumeClient(resumed);
      Error.throwWithStackTrace(error, stackTrace);
    }
    _bindDecryptionCache(resumedMetadata);
    _client = resumed;
    // 挂起期的观察值不再适用：此刻的权威事实就是这个 client。
    _suspendedMetadata = null;
    _suspendedIdentity = null;
    _suspendedContinuity = MatrixSuspendedContinuity.none;
    _ensureOutgoingWorkIdentity(resumed);
    _attachOutgoingEchoListener(resumed);
    _attachDecryptionListener(resumed);
    _attachMemberRefreshListener(resumed);
    _freshLoginAfterClear = false;
    _activeContinuityValidated = true;
    return resumed;
  }

  /// 把 resume 失败归因到具体哪一项连续性锚点不一致，便于本地诊断。
  MatrixSecurityCode _continuityMismatchCode(
    MatrixClientContinuityMetadata previous,
    MatrixClientContinuityMetadata next,
  ) {
    if (previous.userId != next.userId) {
      return MatrixSecurityCode.continuityBindingMismatch;
    }
    if (previous.ed25519Fingerprint != next.ed25519Fingerprint) {
      return MatrixSecurityCode.continuityFingerprintMismatch;
    }
    return MatrixSecurityCode.continuityGenerationMismatch;
  }

  void _replaceOutgoingWork(Client client) {
    _outgoingWork.revoke('Matrix client identity replaced');
    _outgoingWork.dispose();
    _outgoingWork = _newOutgoingWork(client.userID ?? '');
  }

  MatrixOutgoingWorkCoordinator _newOutgoingWork(String accountId) =>
      _outgoingWorkFactory(accountId);

  void _ensureOutgoingWorkIdentity(Client client) {
    final accountId = client.userID;
    if (accountId == null || accountId.isEmpty) return;
    if (!_outgoingWork.isActive || _outgoingWork.accountId != accountId) {
      _replaceOutgoingWork(client);
      _attachOutgoingEchoListener(client);
    }
  }

  Future<void> _rejectResumeClient(Client resumed) async {
    try {
      await _suspendClient(resumed);
    } catch (error, stackTrace) {
      _pendingCloseClient = resumed;
      securityLogger.record(
        stage: MatrixSecurityStage.lifecycle,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.lifecycleResumeRejectCloseFailed,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _closePendingClient() async {
    final pending = _pendingCloseClient;
    if (pending == null) return;
    await _suspendClient(pending);
    _pendingCloseClient = null;
  }

  static Future<void> _defaultSuspend(Client client) => client.dispose();

  static Future<void> _defaultClear(Client? client) async {
    if (client == null) return;
    await client.dispose();
  }

  static Future<MatrixClientContinuityMetadata> _unconfiguredContinuityMetadata(
      Client client) async {
    if (client.isLogged()) {
      throw StateError('Matrix continuity metadata is not configured');
    }
    return const MatrixClientContinuityMetadata(
      isLoggedIn: false,
      userId: null,
      deviceId: null,
      ed25519Fingerprint: null,
      databaseGeneration: 'unmanaged-client',
    );
  }

  @override
  Future<void> verifyDevice(String deviceId) => _withClient((active) async {
        final userId = active.userID;
        if (userId == null) throw StateError('Matrix client is not logged in');
        final device = active.userDeviceKeys[userId]?.deviceKeys[deviceId];
        if (device == null) {
          throw StateError('Device keys are not available; sync first');
        }
        await device.setVerified(true);
      });

  @override
  Future<void> backupKeysToEncryptedStore() => _withClient((active) async {
        // SSSS creates an account-data backed encrypted store. The recovery key
        // remains local and must be persisted by the caller in secure storage.
        final encryption = active.encryption;
        if (encryption == null) {
          throw StateError('Matrix encryption is not enabled');
        }
        final handle = await encryption.ssss.createKey();
        if (_accessRevoked || !identical(active, _client)) {
          throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
        }
        _lastRecoveryKey = handle.recoveryKey;
        if (_lastRecoveryKey == null) {
          throw StateError('Matrix backup key generation failed');
        }
        await handle.maybeCacheAll();
      });

  @override
  Future<void> initializeCrossSigning({required String recoveryKey}) =>
      _withClient((active) async {
        final encryption = active.encryption;
        if (encryption == null) {
          throw StateError('Matrix encryption is not enabled');
        }
        await encryption.crossSigning.selfSign(recoveryKey: recoveryKey);
      });

  @override
  Future<void> restoreEncryptedBackup({required String recoveryKey}) =>
      _withClient((active) async {
        final encryption = active.encryption;
        if (encryption == null) {
          throw StateError('Matrix encryption is not enabled');
        }
        final handle = encryption.ssss.open(EventTypes.CrossSigningMasterKey);
        await handle.unlock(recoveryKey: recoveryKey);
        await handle.maybeCacheAll();
      });

  @override
  Future<String> sendEncryptedText(String roomId, String plaintext) =>
      _withClient((active) async {
        final room = active.getRoomById(roomId);
        if (room == null) throw StateError('Matrix room is not joined');
        await _requireRoomSend(room);
        final eventId =
            await room.sendTextEvent(plaintext, parseCommands: false);
        if (eventId == null) throw StateError('Matrix event was not accepted');
        return eventId;
      });

  @override

  /// 发送加密媒体。
  ///
  /// 参数为 `Uint8List` 且**直接透传**给 SDK——此前这里对正文与缩略图
  /// 各做一次 `Uint8List.fromList` 全量拷贝，视频路径上凭空多出两份
  /// 完整内存副本（SDK 加密内部还会再做一次原生拷贝，无法避免）。
  Future<String> sendEncryptedMedia(
          String roomId, List<int> plaintext, String mimeType,
          {Map<String, dynamic>? extraContent,
          String? txid,
          String? filename,
          Uint8List? thumbnailBytes,
          int? thumbnailWidth,
          int? thumbnailHeight}) =>
      _withClient((active) async {
        final room = active.getRoomById(roomId);
        if (room == null) throw StateError('Matrix room is not joined');
        return _sendMedia(room, plaintext, mimeType,
            extraContent: extraContent,
            txid: txid,
            filename: filename,
            thumbnailBytes: thumbnailBytes,
            thumbnailWidth: thumbnailWidth,
            thumbnailHeight: thumbnailHeight);
      });

  Future<String> _sendEncryptedMediaFromLease(
          MatrixRoomLease lease, List<int> plaintext, String mimeType,
          {Map<String, dynamic>? extraContent,
          String? txid,
          String? filename,
          Uint8List? thumbnailBytes,
          int? thumbnailWidth,
          int? thumbnailHeight}) =>
      _withClient((active) async {
        final room = lease._activeRoom;
        if (!identical(room.client, active)) {
          throw StateError('Matrix room lease client mismatch');
        }
        return _sendMedia(room, plaintext, mimeType, validateLease: () {
          if (!identical(lease._activeRoom, room)) {
            throw StateError('Matrix room lease is no longer active');
          }
        },
            extraContent: extraContent,
            txid: txid,
            filename: filename,
            thumbnailBytes: thumbnailBytes,
            thumbnailWidth: thumbnailWidth,
            thumbnailHeight: thumbnailHeight);
      });

  Future<String> _sendMedia(
    Room room,
    List<int> plaintext,
    String mimeType, {
    void Function()? validateLease,
    Map<String, dynamic>? extraContent,
    String? txid,
    String? filename,
    Uint8List? thumbnailBytes,
    int? thumbnailWidth,
    int? thumbnailHeight,
  }) async {
    void validateSendAccess() {
      if (_accessRevoked ||
          !identical(_client, room.client) ||
          !identical(_client?.getRoomById(room.id), room)) {
        throw StateError('E2EE_LIFECYCLE_ACCESS_REVOKED');
      }
      validateLease?.call();
      if (!room.encrypted || !room.client.fileEncryptionEnabled) {
        throw StateError('Encrypted media requires E2EE attachments');
      }
      if (room.membership != Membership.join || !room.canSendDefaultMessages) {
        throw StateError('当前会话不可发送消息');
      }
    }

    await _requireRoomSend(room);
    validateSendAccess();
    if (!room.isDirectChat && mimeType.startsWith('video/')) {
      validateGroupVideoSize(plaintext.length);
    }
    MatrixImageFile? thumbnail;
    if (thumbnailBytes != null) {
      thumbnail = MatrixImageFile(
        bytes: thumbnailBytes,
        name: 'thumb.jpg',
        mimeType: 'image/jpeg',
        width: thumbnailWidth,
        height: thumbnailHeight,
      );
    }
    final media = buildMediaFileForSend(
      bytes: plaintext is Uint8List ? plaintext : Uint8List.fromList(plaintext),
      name: filename ?? '畅聊附件',
      mimeType: mimeType,
      extraContent: extraContent,
    );
    // BUG-28：自带缩略图的路径会跳过下面的缩略图生成，事件顶层可能缺
    // info.w/h——同一张图两次连发落入不同布局。在聚合点补齐解码尺寸。
    final sizedFile = await ensureImageDimensionsForSend(media.file);
    // The original is already processed by the image/video picker. Generate
    // only a missing thumbnail before hashing; the SDK must not transform a
    // prepared envelope after this point.
    final image = sizedFile;
    if (image is MatrixImageFile && thumbnail == null) {
      try {
        thumbnail = await OutgoingMediaThumbnailCache.load(
          accountId: room.client.userID ?? '',
          image: image,
          generate: () => image.generateThumbnail(
            nativeImplementations: room.client.nativeImplementations,
            customImageResizer: room.client.customImageResizer,
          ),
        );
      } catch (_) {
        /* An unavailable optional thumbnail preserves the original. */
      }
      if (thumbnail != null && thumbnail.size > image.size) thumbnail = null;
    }
    await cacheOutgoingMedia(
      accountId: room.client.userID ?? '',
      roomId: room.id,
      bytes: sizedFile.bytes,
    );
    if (thumbnail != null) {
      await cacheOutgoingMedia(
        accountId: room.client.userID ?? '',
        roomId: room.id,
        bytes: thumbnail.bytes,
      );
    }
    validateSendAccess();
    final prepared = await prepareContentAddressedMedia(
      file: sizedFile,
      thumbnail: thumbnail,
      extraContent: media.extraContent,
    );
    // Preparation yields to worker isolates. Revoke/room replacement can happen
    // meanwhile; check both owner and originating lease before any SDK upload.
    await _requireRoomSend(room);
    validateSendAccess();
    final eventId = await room.sendFileEvent(
      prepared.file,
      thumbnail: prepared.thumbnail,
      extraContent: prepared.extraContent,
      txid: txid,
    );
    if (eventId == null) {
      // 上传/发送重试耗尽（网络类）→ waitingNetwork 自动重发；见
      // MessageSendNetworkException 的文档。
      throw const MessageSendNetworkException('媒体消息发送失败');
    }
    return eventId;
  }

  bool hasPendingMentions(String roomId) {
    final room = _client?.getRoomById(roomId);
    return !_accessRevoked &&
        room != null &&
        RoomMentionStore.shared.hasPending(room);
  }

  /// **本地只读**：本机 SDK store 是否已知该房间（任意 membership）。
  ///
  /// 供 `RoomOpeningPolicy` 的离线优先判定使用：不触发 `/sync`、不等待同步、
  /// 不发起任何网络请求（与 `waitForRoom` 的区别就在于此）。
  bool knowsRoomLocally(String roomId) => _client?.getRoomById(roomId) != null;

  /// **本地只读**：该房间在本机 SDK store 中是否为我方已加入。
  bool isRoomJoinedLocally(String roomId) =>
      _client?.getRoomById(roomId)?.membership == Membership.join;

  /// **本地只读**：accountData 引用的控制房间（表情仓库 / 提醒同步）。
  ///
  /// 身份来自 accountData 的 `room_id` 与房间号本身，**不依赖展示名**。
  Set<String> get controlRoomIds {
    final client = _client;
    if (client == null) return const <String>{};
    return roomVisibilityFromAccountData(client).controlRoomIds;
  }

  Future<void> scanMentions() => _withClient((client) async {
        await Future.wait([
          for (final room in client.rooms)
            if (!room.isDirectChat && room.membership == Membership.join)
              RoomMentionStore.shared.scan(room,
                  shouldContinue: () =>
                      !_accessRevoked && identical(client, _client))
        ]);
      });

  Future<DirectChatRoom> openCanonicalDirectRoom(String id,
          {String? matrixUserId}) =>
      _withClient((client) => MatrixDirectChatBackend(client)
          .openCanonicalRoom(id, matrixUserId: matrixUserId));

  /// Recovery after an uncertain create may only reuse an existing room.
  Future<DirectChatRoom?> findExistingDirectChat(String peer) => _withClient(
      (client) => MatrixDirectChatBackend(client).findJoinedDirectRoom(peer));

  /// Local-only recovery lookup. A miss is intentionally inconclusive.
  Future<DirectChatRoom?> findCachedDirectChat(String peer) =>
      _withClient((client) =>
          MatrixDirectChatBackend(client).findCachedJoinedDirectRoom(peer));

  /// **Offline First**：只读本地 SDK 库的安全快照，零网络、不抛错。
  ///
  /// 命中即立刻进入会话；未命中返回 null（调用方进入 pending conversation
  /// 或后台仲裁），**绝不**把“本地还没有会话”当成错误。
  @override
  Future<DirectChatRoom?> tryLocalDirectChat(String matrixUserId) async {
    try {
      final cached = await findCachedDirectChat(matrixUserId);
      if (cached == null) return null;
      final safe = cached.roomId.trim().isNotEmpty &&
          cached.encrypted &&
          cached.joinedMemberCount == 2 &&
          cached.participantIds.length == 2 &&
          cached.participantIds.contains(matrixUserId);
      return safe ? cached : null;
    } catch (_) {
      return null;
    }
  }

  /// 房间号提示由协调 intent（`DirectRoomIntentStore`）持有，客户端不持有
  /// 该存储，因此这里没有可返回的本地提示。
  @override
  Future<String?> localRoomHint(String matrixUserId) async => null;

  /// The caller owns one durable creation grant. Never repair an uncertain
  /// existing room or retry a Matrix create inside this operation.
  Future<String> createReservedDirectRoom(
          String peer, String aliasLocalpart, String reservationId) =>
      _withClient((client) async {
        if (!RegExp(r'^chatflow_dm_[a-f0-9]{32}$').hasMatch(aliasLocalpart)) {
          throw StateError('Invalid reserved alias');
        }
        final self = client.userID;
        if (self == null || !self.contains(':')) {
          throw StateError('Account unavailable');
        }
        final alias =
            '#$aliasLocalpart:${self.substring(self.indexOf(':') + 1)}';
        Future<String?> resolve() async {
          try {
            return (await client.getRoomIdByAlias(alias)).roomId;
          } on MatrixException catch (error) {
            if (error.errcode == 'M_NOT_FOUND') return null;
            rethrow;
          }
        }

        final existing = await resolve();
        if (existing != null) return existing;
        try {
          return await client.createRoom(
              roomAliasName: aliasLocalpart,
              invite: [peer],
              isDirect: true,
              preset: CreateRoomPreset.trustedPrivateChat,
              initialState: [
                StateEvent(type: EventTypes.Encryption, content: {
                  'algorithm': Client.supportedGroupEncryptionAlgorithms.first
                }),
                StateEvent(
                    type: conversationKindStateType,
                    stateKey: '',
                    content: {
                      'kind': 'direct',
                      'participants': [self, peer]
                    }),
                StateEvent(
                    type: 'com.chatflow.direct_reservation',
                    stateKey: '',
                    content: {'reservation_id': reservationId}),
              ]);
        } catch (_) {
          final recovered = await resolve();
          if (recovered != null) return recovered;
          rethrow;
        }
      });

  Future<DirectChatRoom> createDirectChatOnce(String peer) =>
      _withClient((client) async {
        final backend = MatrixDirectChatBackend(client);
        final roomId = await backend.createEncryptedDirectRoom(peer);
        return backend.waitForRoom(roomId);
      });
  Future<MatrixRoomInfoSnapshot> waitForRoom(String id) =>
      conversations.waitForJoinedRoom(id);
  Future<void> sendFriendAccepted(
          String roomId, String peerId, String displayName,
          {String? requestId, String? requestMessage}) =>
      _withClient((client) async {
        final room = client.getRoomById(roomId);
        if (room == null || !room.encrypted) throw StateError('加密私聊尚未就绪');
        await _requireRoomSend(room);
        final id = await room.sendEvent(
            friendAcceptedEventContent(
              requesterMatrixUserId: peerId,
              requesterDisplayName: displayName,
              requestId: requestId,
              requestMessage: requestMessage,
            ),
            type: changliaoFriendAcceptedEventType,
            txid: friendAcceptedTransactionId(
                roomId: roomId,
                acceptingUserId: client.userID ?? '',
                requestId: requestId));
        if (id == null) throw StateError('好友招呼尚未发送');
      });

  @override

  /// **LEGACY（生产禁用）**：无 canonical 仲裁的私聊创建便捷方法。
  ///
  /// 生产私聊创建只经 `DirectChatController` → `CoordinatedDirectChatGateway`
  /// （`createDirectChatOnce` 持一次性建房授权）。本方法保留给兼容性测试；
  /// 架构守卫测试断言 `lib/` 生产代码不调用它。
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId) =>
      _withClient((active) async {
        return DirectChatService(MatrixDirectChatBackend(active))
            .openOrCreateDirectChat(matrixUserId);
      });

  @override
  Future<String> createEncryptedGroupChat({
    required String name,
    required List<String> matrixUserIds,
  }) =>
      _withClient((active) async {
        return GroupChatService(MatrixGroupChatBackend(active))
            .createEncryptedGroupChat(
          name: name,
          matrixUserIds: matrixUserIds,
        );
      });
}

/// Task B：把本机 Matrix 加密库投影成只读搜索来源。
///
/// 安全与边界：
/// - **零网络**：只经 [MatrixSdkE2eeClient.readLocalRoomEvents] 读取本机
///   SQLCipher 加密库中的事件，绝不触发 `/messages` 分页或任何 HTTP 请求；
/// - 只索引**已解密且用户可见的文本**事件（`m.message` / `m.text`）；
/// - 闪照、图片/视频/音频/文件等媒体事件与未解密事件永不进入索引；
/// - 明文只停留在内存索引中，落盘内容仍是 SQLCipher 加密库本身。
final class MatrixLocalHistorySearchSource implements LocalHistorySearchSource {
  MatrixLocalHistorySearchSource({required this.owner});

  final MatrixAppHomeCapability owner;

  /// 单次回填最多覆盖的房间数（有界，不下钻整段云端历史）。
  static const _maxRooms = 200;

  @override
  Future<List<String>> localRoomIds() async =>
      owner.localSearchRoomIds(maxRooms: _maxRooms);

  @override
  Future<List<LocalSearchMessage>> readRecentMessages({
    required String roomId,
    required int limit,
  }) async {
    if (roomId.isEmpty || limit <= 0) return const [];
    List<Event> events;
    try {
      events = await owner.readLocalRoomEvents(roomId, limit: limit);
    } catch (_) {
      return const []; // 本地库不可用：如实返回空，绝不回退到网络分页。
    }
    final messages = <LocalSearchMessage>[];
    for (final event in events) {
      final message = projectLocalSearchEvent(event);
      if (message != null) messages.add(message);
    }
    return messages;
  }
}

/// 把一条本机事件投影成搜索记录（纯函数，便于单测）。
///
/// 只接受已解密的用户可见**文本**消息；媒体、闪照、撤回、未解密一律返回 null。
@visibleForTesting
LocalSearchMessage? projectLocalSearchEvent(Event event,
    {String? localUserId}) {
  if (event.type != EventTypes.Message) return null;
  final messageType = event.messageType;
  if (messageType != MessageTypes.Text && messageType != 'm.notice') {
    return null;
  }
  final body = event.plaintextBody;
  if (body.trim().isEmpty) return null;
  // 媒体占位正文（[图片]/[视频]/裸 mime/data URI）永不进入索引；
  // 闪照事件同样被占位正文与仓储层双重拦截。
  if (!LocalMessageSearchRepository.isIndexableText(body)) return null;
  final room = event.room;
  final senderId = event.senderId;
  final resolvedName = senderId == localUserId
      ? '我'
      : room.unsafeGetUserFromMemoryOrFallback(senderId).displayName;
  final senderName = (resolvedName ?? '').trim();
  return LocalSearchMessage(
    eventId: event.eventId,
    senderId: senderId,
    senderName: senderName.isEmpty ? senderId : senderName,
    timestamp: event.originServerTs,
    body: body,
    roomId: room.id,
    roomName: room.getLocalizedDisplayname(),
    isGroup: !room.isDirectChat,
    senderIsSelf: senderId == localUserId,
    roomAvatarSeed: room.id,
  );
}
