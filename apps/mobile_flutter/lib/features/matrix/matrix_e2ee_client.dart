import 'matrix_room_display_name.dart' as room_names;
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
import 'room_mention_store.dart';
import 'unread_mention_tracker.dart';
import 'matrix_call_adapter.dart' hide changliaoCallMessageType;
import 'matrix_emoji_vault.dart';
import 'matrix_message_reminder_backend.dart';
import 'matrix_room_timeline_adapter.dart';
import 'matrix_recovery_service.dart';
import 'matrix_security_logger.dart';
import 'matrix_user_avatar.dart';
import 'message_interaction_service.dart';
import 'nudge_service.dart';
import 'room_timeline_controller.dart';

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

  bool hasSameContinuity(MatrixClientContinuityMetadata other) =>
      userId == other.userId &&
      deviceId == other.deviceId &&
      ed25519Fingerprint == other.ed25519Fingerprint &&
      databaseGeneration == other.databaseGeneration;
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
    required this.id,
    required this.displayName,
    required this.avatar,
    required this.isDirect,
    required this.directPeerId,
    required List<MatrixMemberSnapshot> members,
    required this.lastEvent,
    required this.preference,
    required this.notificationCount,
    required this.notificationsEnabled,
    this.name = '',
    this.isJoined = true,
  }) : members = List.unmodifiable(members);
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
        await Future.wait([
          for (final room in client.rooms)
            if (room.membership == Membership.join && !room.isDirectChat)
              () async {
                try {
                  await room.requestParticipants([Membership.join]);
                } catch (_) {/* Keep cached members offline. */}
              }()
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
          final cutoff = localHistory?.clearedThrough(room.id);
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

  MatrixConversationRoomSnapshot _snapshotRoom(
      Room room, SharedPreferencesLocalHiddenEvents? localHistory) {
    final originalEvent = room.lastEvent;
    final cutoff = localHistory?.clearedThrough(room.id);
    final locallyDeleted = cutoff != null &&
        (originalEvent == null ||
            !originalEvent.originServerTs.isAfter(cutoff));
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
    final joined = room.getParticipants([Membership.join]);
    final membersById = {for (final user in joined) user.id: user};
    final memberOrder = reconcileMemberOrder(
      preferenceForRoom(room).memberOrderIds,
      joined.map((user) => user.id),
    );
    MatrixMemberSnapshot member(User user) => MatrixMemberSnapshot(
          id: user.id,
          displayName: user.calcDisplayname(),
          avatar: user.avatarUrl,
        );
    return MatrixConversationRoomSnapshot(
      id: room.id,
      displayName: room_names.roomDisplayName(room),
      name: room.name,
      avatar: room.avatar,
      isDirect: room.isDirectChat,
      directPeerId: room.directChatMatrixID,
      members: [
        for (final id in memberOrder)
          if (membersById[id] != null) member(membersById[id]!),
      ],
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
          ? preferenceForRoom(room).copyWith(hidden: true, manualUnread: false)
          : preferenceForRoom(room),
      notificationCount: locallyDeleted ? 0 : room.notificationCount,
      notificationsEnabled: room.pushRuleState == PushRuleState.notify,
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
                room, timeline._timeline.events,
                shouldContinue: () => _mentionsActive);
          }
        }
      });
  String? get historyToken => _activeRoom.prev_batch;
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
        final capability = _SdkRoomTimelineCapability(this, timeline);
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
                  contentSha256: hashes?.contentSha256),
              () => downloadMediaContent(event));
          if (groupVideo) validateGroupVideoSize(bytes.length);
          Uint8List? thumbnail;
          if (hashes?.thumbnailSha256 != null || event.isThumbnailEncrypted) {
            thumbnail = await loadMediaWithCache(
                MediaCacheKey(
                    accountId: source.client.userID ?? '',
                    roomId: source.id,
                    eventId: 'thumb:${event.eventId}',
                    contentSha256: hashes?.thumbnailSha256), () async {
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
    implements RoomTimelineCapability, RoomHistoryStatus {
  _SdkRoomTimelineCapability(this._lease, this._timeline);

  final MatrixRoomLease _lease;
  final Timeline _timeline;
  final Set<String> _retrying = {};
  bool _disposed = false;

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
    return null;
  }

  @override
  List<RoomMessageViewModel> snapshot() {
    _ensureActive();
    final viewModels = _timeline.events
        .where(
          (event) =>
              event.type == EventTypes.Message ||
              event.type == changliaoNudgeEventType ||
              event.type == changliaoFriendAcceptedEventType,
        )
        .where((event) => event.messageType != groupAnnouncementMessageType)
        .toList(growable: false)
        .reversed
        .map(_message)
        .toList(growable: false)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    // BUG3：入群系统通知——以真实 Matrix 成员事件为唯一权威，本地推导
    // （invite 配对 join 转变），绝不插入本地临时文本；历史重载一致。
    // 规格§一4：私聊（m.direct）房间绝不推导群聊系统通知——DM 的
    // invite/join 成员事件属建房信令，不是"邀请加入群聊"。
    final notices = _lease._activeRoom.isDirectChat
        ? const <GroupJoinNotice>[]
        : deriveGroupJoinNotices(
            [for (final event in _timeline.events) projectMemberEvent(event)],
            resolveName: (matrixUserId) => _lease._activeRoom
                .unsafeGetUserFromMemoryOrFallback(matrixUserId)
                .calcDisplayname(),
          );
    final messages = notices.isEmpty
        ? viewModels
        : mergeNoticesIntoTimeline(viewModels, notices);
    return _lease.owner._localHistoryStore?.visibleItems(
            _lease.roomId, messages,
            eventId: (message) => message.id,
            eventTimestamp: (message) => message.timestamp) ??
        messages;
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
      isRecalled: event.redacted,
      replyToEventId: ((event.content['m.relates_to'] as Map?)?['m.in_reply_to']
              as Map?)?['event_id']
          ?.toString(),
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
  Future<void> loadHistory() =>
      _withOperation(() => _timeline.requestHistory(historyCount: 60));

  @override
  bool get canLoadHistory => !_disposed && _timeline.canRequestHistory;

  @override
  Future<void> markRead() => _withOperation(_timeline.setReadMarker);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timeline.cancelSubscriptions();
    _lease._timelines.remove(this);
  }
}

final class _SdkEmojiVaultBackend
    implements
        MatrixEmojiVaultBackend,
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
    if (!event.type.startsWith('com.changliao.emoji.')) return null;
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

final class MatrixSdkE2eeClient
    implements
        MatrixE2eeClient,
        MatrixRecoveryClient,
        MatrixRecoveryBackend,
        MatrixTokenLoginGateway,
        MatrixAccountSelectionGateway,
        AvatarMediaCapability {
  Future<void>? _memberRefresh;
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
    MatrixSecurityLogger? securityLogger,
    this.lifecycleDrainTimeout = const Duration(seconds: 5),
  })  : _client = client,
        _suspendClient = suspendClient ?? _defaultSuspend,
        _resumeClient = resumeClient,
        _selectClientAccount = selectClientAccount,
        _clearClientData = clearClientData ?? _defaultClear,
        _readContinuityMetadata =
            readContinuityMetadata ?? _unconfiguredContinuityMetadata,
        securityLogger = securityLogger ??
            MatrixSecurityLogger.create(sink: (line) => debugPrint(line)) {
    _attachDecryptionListener(client);
  }
  Client? _client;
  Client? _pendingCloseClient;
  final Future<void> Function(Client client) _suspendClient;
  final Future<Client> Function()? _resumeClient;
  final Future<void> Function(String homeserver, String userId)?
      _selectClientAccount;
  final Future<void> Function(Client? client) _clearClientData;
  final Future<MatrixClientContinuityMetadata> Function(Client client)
      _readContinuityMetadata;
  final MatrixSecurityLogger securityLogger;
  Future<void> _lifecycleTail = Future.value();
  final Duration lifecycleDrainTimeout;
  int _inFlightClientOperations = 0;
  Completer<void>? _clientOperationsDrained;
  bool _accessRevoked = false;
  MatrixClientContinuityMetadata? _suspendedMetadata;
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
  String? get debugActiveClientName => _client?.clientName;
  String? _lastRecoveryKey;

  /// Recovery key is exposed only to the caller so it can be written to the
  /// platform secure store; it is never sent to the business API.
  String? get lastRecoveryKey => _lastRecoveryKey;
  @override
  bool get isLoggedIn =>
      _client?.isLogged() ?? _suspendedMetadata?.isLoggedIn ?? false;
  @override
  bool get credentialsInvalid =>
      _credentialsInvalid ||
      _client?.onLoginStateChanged.value == LoginState.softLoggedOut;
  @override
  String? get userId {
    final active = _client;
    return active == null ? _suspendedMetadata?.userId : active.userID;
  }

  @override
  String? get deviceId {
    final active = _client;
    return active == null ? _suspendedMetadata?.deviceId : active.deviceID;
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
        if (credentialsInvalid &&
            active.userID != null &&
            active.deviceID != null) {
          _credentialsInvalid = true;
          final expectedUserId = active.userID;
          final expectedDeviceId = active.deviceID;
          if (expectedUserId == null || expectedDeviceId == null) {
            throw StateError('Matrix continuity identity is unavailable');
          }
          if (deviceId != null && deviceId != expectedDeviceId) {
            throw StateError('Matrix credential refresh device mismatch');
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
          if (response.userId != expectedUserId ||
              response.deviceId != expectedDeviceId) {
            throw StateError('Matrix credential refresh identity mismatch');
          }
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
            newDeviceID: expectedDeviceId,
            newDeviceName: active.deviceName ?? '畅聊移动端',
          );
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
    _accessRevoked = true;
    _revokeManagedResources();
    return _serializeLifecycle(() async {
      final active = _client;
      if (active == null) return;
      await _waitForClientOperationsToDrain();
      // Reopening the retained store can restore the old token from disk.
      // Keep its invalid status after the SDK object and stream are disposed.
      _credentialsInvalid = credentialsInvalid;
      _decryptedTimelineEvents.clear();
      _lastRecoveryKey = null;
      final metadata = await _readContinuityMetadata(active);
      try {
        await _detachManagedSubscriptions();
        await _detachManagedResources();
        await _suspendClient(active);
      } catch (error, stackTrace) {
        await _attachManagedResources(active);
        await _attachManagedSubscriptions(active);
        Error.throwWithStackTrace(error, stackTrace);
      }
      _client = null;
      _suspendedMetadata = metadata;
    });
  }

  @override
  Future<void> selectAccount(String matrixUserId, Uri selectedHomeserver) {
    final operation = _accountSelectionQueue
        .then((_) => _selectAccount(matrixUserId, selectedHomeserver));
    _accountSelectionQueue =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<void> _selectAccount(
      String matrixUserId, Uri selectedHomeserver) async {
    final select = _selectClientAccount;
    final resume = _resumeClient;
    if (select == null || resume == null || selectedHomeserver != homeserver) {
      throw StateError('Retained account storage is not configured');
    }
    await suspend();
    await _serializeLifecycle(() async {
      // Old UI capabilities must never be rebound to another identity.
      for (final registration in _managedSubscriptions) {
        registration.canceled = true;
      }
      for (final resource in _managedResources) {
        resource.canceled = true;
      }
      _managedSubscriptions.clear();
      _managedResources.clear();
      await select(selectedHomeserver.toString(), matrixUserId);
      _suspendedMetadata = null;
      _activeContinuityValidated = false;
      final next = await resume();
      try {
        if (next.userID != null && next.userID != matrixUserId) {
          throw StateError(
              'Stored Matrix identity does not match authenticated account');
        }
        final metadata = await _readContinuityMetadata(next);
        _client = next;
        _suspendedMetadata = metadata;
        _activeContinuityValidated = true;
        _credentialsInvalid = next.isLogged();
        _freshLoginAfterClear = false;
        _localHistoryStore = null;
        _decryptedTimelineEvents.clear();
        _lastRecoveryKey = null;
        _bindDecryptionCache(metadata);
        _attachDecryptionListener(next);
      } catch (_) {
        await _suspendClient(next);
        rethrow;
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
        await _detachManagedSubscriptions();
        await _detachManagedResources();
      } catch (error, stackTrace) {
        if (target != null) {
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
    _attachDecryptionListener(resumed);
    _client = resumed;
    _freshLoginAfterClear = false;
    _activeContinuityValidated = true;
    return resumed;
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

  Future<String> _sendMedia(Room room, List<int> plaintext, String mimeType,
      {void Function()? validateLease,
      Map<String, dynamic>? extraContent,
      String? txid,
      String? filename,
      Uint8List? thumbnailBytes,
      int? thumbnailWidth,
      int? thumbnailHeight}) async {
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
          height: thumbnailHeight);
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
        thumbnail = await image.generateThumbnail(
          nativeImplementations: room.client.nativeImplementations,
          customImageResizer: room.client.customImageResizer,
        );
      } catch (_) {
        /* An unavailable optional thumbnail preserves the original. */
      }
      if (thumbnail != null && thumbnail.size > image.size) thumbnail = null;
    }
    final prepared = await prepareContentAddressedMedia(
        file: media.file,
        thumbnail: thumbnail,
        extraContent: media.extraContent);
    // Preparation yields to worker isolates. Revoke/room replacement can happen
    // meanwhile; check both owner and originating lease before any SDK upload.
    validateSendAccess();
    final eventId = await room.sendFileEvent(prepared.file,
        thumbnail: prepared.thumbnail,
        extraContent: prepared.extraContent,
        txid: txid);
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
