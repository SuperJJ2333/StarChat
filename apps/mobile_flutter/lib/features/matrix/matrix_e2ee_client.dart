import 'matrix_room_display_name.dart' as room_names;
import 'matrix_outgoing_work_coordinator.dart';
import 'conversation_read_state.dart';
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
import 'room_timeline_viewport.dart';
import 'matrix_recovery_service.dart';
import 'matrix_security_logger.dart';
import 'matrix_user_avatar.dart';
import 'message_interaction_service.dart';
import 'nudge_service.dart';
import 'room_timeline_controller.dart';

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

enum MatrixConversationMutation { markUnread, togglePin, hide, delete }

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
            isJoined: isJoined);

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
}

@immutable
final class MatrixConversationSnapshot {
  MatrixConversationSnapshot({
    required this.vaultRoomId,
    required this.reminderRoomId,
    required List<MatrixConversationRoomSnapshot> rooms,
  }) : rooms = List.unmodifiable(rooms);
  final String? vaultRoomId;
  final String? reminderRoomId;
  final List<MatrixConversationRoomSnapshot> rooms;
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
        await reconcileConversationPreferences(client);
        _flushPreferences();
        final localHistory = client.userID == null
            ? null
            : await _owner._loadLocalHistory(client);
        _owner._memberProjectionCache.prune({
          for (final room in client.rooms)
            if (room.membership == Membership.join) room.id,
        });
        return MatrixConversationSnapshot(
          vaultRoomId: client
              .accountData[emojiVaultAccountDataType]?.content['room_id']
              ?.toString(),
          reminderRoomId: client
              .accountData[messageReminderAccountDataType]?.content['room_id']
              ?.toString(),
          rooms: [
            for (final room in client.rooms)
              if (room.membership == Membership.join)
                _snapshotRoom(room, localHistory)
          ],
        );
      });

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
        MatrixEncryptedMediaGateway, MatrixOutgoingProgressView,
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

  /// A non-SDK snapshot valid only while this lease is active.
  MatrixRoomInfoSnapshot get roomInfo => _snapshotRoomInfo(_activeRoom);

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
        sourceIdentity: event == null
            ? null
            : matrixMediaSourceIdentity(event.content, thumbnail: thumbnail));
  }

  Future<MatrixRoomInfoSnapshot> refreshRoomInfo() =>
      _withLeaseOperation((room) async {
        await room.requestParticipants([Membership.join]);
        return _snapshotRoomInfo(room);
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
      owner.conversations.clearLocalHistory(roomId,
          messageIds: messageIds, cutoff: cutoff);

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
        final vaultRoomId = client
            .accountData[emojiVaultAccountDataType]?.content['room_id']
            ?.toString();
        final reminderRoomId = client
            .accountData[messageReminderAccountDataType]?.content['room_id']
            ?.toString();
        return [
          for (final target in client.rooms)
            if (target.encrypted &&
                target.membership == Membership.join &&
                target.canSendDefaultMessages &&
                !isMatrixControlRoom(
                  roomId: target.id,
                  displayName: room_names.roomDisplayName(target),
                  vaultRoomId: vaultRoomId,
                  reminderRoomId: reminderRoomId,
                ))
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
      _withLeaseOperation((room) async =>
          await room.sendEvent(Map<String, dynamic>.from(content),
              txid: txid) ??
          (throw StateError('Matrix room event was not accepted')));

  Future<void> sendEncryptedAttachment({
    required Uint8List bytes,
    required String name,
    required String mimeType,
  }) =>
      _withLeaseOperation((room) => room.sendFileEvent(
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
      _withLeaseOperation((room) async {
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
    for (final timeline in _timelines.toList(growable: false)) {
      timeline.dispose();
    }
    _timelines.clear();
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
        RoomTimelineCapability,
        RoomHistoryStatus,
        RoomFutureHistoryStatus,
        RoomHistoryDateCapability,
        RoomWindowedTimelineSource {
  _SdkRoomTimelineCapability(this._lease, Timeline timeline, this._onUpdate)
      : _liveTimeline = timeline {
    _outgoingListener = () {
      if (!_disposed) _onUpdate();
    };
    _outgoingWork = _lease.owner.outgoingWork;
    _outgoingWork.addListener(_outgoingListener);
  }

  final MatrixRoomLease _lease;
  final Timeline _liveTimeline;
  Timeline? _contextTimeline;
  int _contextGeneration = 0;
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
              event.type == changliaoFriendAcceptedEventType) ||
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
  RoomMessageViewModel? findMessage(String id) => _viewport?.find(id);
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
    _contextGeneration++;
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
              event.type == changliaoFriendAcceptedEventType) ||
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
      imageWidth: info is Map ? int.tryParse('${info['w']}') : null,
      imageHeight: info is Map ? int.tryParse('${info['h']}') : null,
      senderId: event.senderId,
      text: event.redacted
          ? ''
          : friendAccepted
              ? _friendAcceptedBody(event)
              : (nudge ? '' : event.text),
      isOwn: event.senderId == _lease._activeRoom.client.userID,
      deliveryState: status,
      timestamp: event.originServerTs.toLocal(),
      isSdkLocalEcho: !event.status.isSynced,
      kind: (nudge || friendAccepted)
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
  static String _friendAcceptedBody(Event event) {
    final body = event.content['body']?.toString();
    if (body != null && body.isNotEmpty) return body;
    return friendAcceptedSystemMessage(
      event.content['friend_display_name']?.toString() ?? '好友',
    );
  }

  @override
  Future<String> sendText(String text) => _withOperation(() async =>
      await _lease._activeRoom.sendTextEvent(text, parseCommands: false) ??
      (throw StateError('消息发送失败')));

  @override
  Future<String> sendTextWithTransaction(String text, String transactionId) =>
      _withOperation(() async =>
          await _lease._activeRoom
              .sendTextEvent(text, txid: transactionId, parseCommands: false) ??
          (throw StateError('消息发送失败')));

  @override
  Future<String> sendTransferReference(
          String transferId, String amount, String? note) =>
      _withOperation(() async =>
          await _lease._activeRoom.sendEvent({
            'msgtype': changliaoTransferMessageType,
            'body': '[畅聊点钻转账]',
            'transfer_id': transferId,
            'transfer_amount': amount,
            if (note != null && note.isNotEmpty) 'transfer_note': note
          }) ??
          (throw StateError('转账消息发送失败')));

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
  Future<String> sendRedPacketReference(String packetId, String greeting) =>
      _withOperation(() async =>
          await _lease._activeRoom.sendEvent({
            'msgtype': changliaoRedPacketMessageType,
            'body': '[畅聊点钻红包]',
            'packet_id': packetId,
            'greeting': greeting,
          }) ??
          (throw StateError('红包消息发送失败')));

  @override
  Future<Uint8List> loadAttachment(String eventId) => _withOperation(() async {
        final event = eventById(eventId) ??
            (throw StateError('Matrix timeline event is unavailable'));
        return loadMediaWithCache(
            _lease.mediaCacheKey(eventId), () => downloadMediaContent(event));
      });

  @override
  Future<void> retry(String transactionId) => _withOperation(() async {
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
          if (result == null) throw StateError('消息发送失败');
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
  }

  @override
  Future<void> markRead() => _withOperation(_liveTimeline.setReadMarker);

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
    final day = DateTime(localDay.year, localDay.month, localDay.day);
    _ensureActive();
    final generation = ++_contextGeneration;
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

  @override
  void dispose() {
    if (_disposed) return;
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
    final prepared =
        await prepareLocalChatVideo(source, deleteSourceWhenDone: false);
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
  @visibleForTesting
  int get debugManagedResourceCount => _managedResources.length;
  @visibleForTesting
  bool get debugHasActiveClient => _client != null;
  @visibleForTesting
  MatrixSuspendedContinuity get debugSuspendedContinuity => _suspendedContinuity;

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
    final targets = List<String>.unmodifiable(targetRoomIds);
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
    final targets = List<String>.unmodifiable(targetRoomIds);
    if (targets.any((target) => target.isEmpty) ||
        targets.toSet().length != targets.length) {
      throw ArgumentError(
          'Media forwarding targets must be non-empty and unique');
    }
    final existing = session.coordinator.job(jobId);
    if (existing != null) return existing;
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
    final targets = _freezeVideoTargets(targetRoomIds);
    final existing = session.coordinator.job(jobId);
    if (existing != null) return existing;
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
        targetRoomIds: _freezeVideoTargets(request.targetRoomIds),
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
    // The original is already processed by the image/video picker. Generate
    // only a missing thumbnail before hashing; the SDK must not transform a
    // prepared envelope after this point.
    final image = media.file;
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
      bytes: media.file.bytes,
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
      file: media.file,
      thumbnail: thumbnail,
      extraContent: media.extraContent,
    );
    // Preparation yields to worker isolates. Revoke/room replacement can happen
    // meanwhile; check both owner and originating lease before any SDK upload.
    validateSendAccess();
    final eventId = await room.sendFileEvent(
      prepared.file,
      thumbnail: prepared.thumbnail,
      extraContent: prepared.extraContent,
      txid: txid,
    );
    if (eventId == null) {
      throw StateError('Matrix media event was not accepted');
    }
    return eventId;
  }

  bool hasPendingMentions(String roomId) {
    final room = _client?.getRoomById(roomId);
    return !_accessRevoked &&
        room != null &&
        RoomMentionStore.shared.hasPending(room);
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

  /// The caller owns one durable creation grant. Never repair an uncertain
  /// existing room or retry a Matrix create inside this operation.
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
