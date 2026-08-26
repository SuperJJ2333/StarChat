import 'dart:async';

import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:flutter/foundation.dart';
import '../auth/login_controller.dart' hide LoginState;
import 'avatar_url_resolver.dart';
import 'conversation_preferences.dart';
import 'matrix_control_rooms.dart';
import 'direct_chat_controller.dart';
import 'emoji_vault.dart';
import 'group_chat_controller.dart';
import 'group_chat_info_controller.dart';
import 'matrix_direct_chat_adapter.dart';
import 'matrix_group_chat_adapter.dart';
import 'group_invitation_auto_join.dart';
import 'matrix_call_adapter.dart';
import 'matrix_emoji_vault.dart';
import 'matrix_message_reminder_backend.dart';
import 'matrix_room_timeline_adapter.dart';
import 'matrix_security_logger.dart';
import 'matrix_user_avatar.dart';
import 'message_interaction_service.dart';
import 'nudge_service.dart';
import 'room_timeline_controller.dart';

const changliaoRedPacketMessageType = 'com.changliao.red_packet';

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

abstract interface class MatrixEncryptedMediaGateway {
  /// The SDK encrypts these local plaintext bytes during upload whenever the
  /// target room is encrypted. Callers must never forward them to business APIs.
  Future<String> sendEncryptedMedia(
    String roomId,
    List<int> plaintext,
    String mimeType,
  );
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
      isLoggedIn == other.isLoggedIn &&
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
  MatrixCallBackend createCallBackend();
  Future<MatrixMessageReminderBackend> openMessageReminderBackend();
}

final class _SdkAppHomeCapability implements MatrixAppHomeCapability {
  _SdkAppHomeCapability(this._owner, this._client);
  final MatrixSdkE2eeClient _owner;
  final Client _client;
  bool _revoked = false;

  void revoke() => _revoked = true;

  void _ensureActive() {
    if (_revoked) throw StateError('Matrix home capability is revoked');
  }

  @override
  MatrixCallBackend createCallBackend() {
    _ensureActive();
    return MatrixCallBackend(
      _client,
      ensureActive: () {
        _ensureActive();
        if (!identical(_owner._client, _client)) {
          throw StateError('Matrix home capability belongs to an old session');
        }
      },
    );
  }

  @override
  Future<MatrixMessageReminderBackend> openMessageReminderBackend() async {
    _ensureActive();
    late MatrixMessageReminderBackend backend;
    await _owner._withClient((active) async {
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
  });
  final String type;
  final String text;
  final String body;
  final DateTime originServerTs;
  final String senderId;
  final MatrixMemberSnapshot sender;
  final bool redacted;
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

  Future<void> reconcileMetadata() => _owner._withClient((client) async {
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
            await writeConversationPreference(
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
            await writeConversationPreference(room, restored);
          }
        }
      });

  Future<MatrixConversationSnapshot> snapshot() =>
      _owner._withClient((client) async {
        for (final room in client.rooms.where((room) => !room.isDirectChat)) {
          try {
            await room.requestParticipants([Membership.join]);
          } catch (_) {
            // Preserve the last in-memory membership snapshot while offline.
          }
        }
        return MatrixConversationSnapshot(
          vaultRoomId: client
              .accountData[emojiVaultAccountDataType]?.content['room_id']
              ?.toString(),
          reminderRoomId: client
              .accountData[messageReminderAccountDataType]?.content['room_id']
              ?.toString(),
          rooms: [for (final room in client.rooms) _snapshotRoom(room)],
        );
      });

  Future<String> roomDisplayName(String roomId) =>
      _owner._withClient((client) async {
        final room = client.getRoomById(roomId);
        if (room == null) throw StateError('Matrix room is unavailable');
        return room.getLocalizedDisplayname();
      });

  Future<void> markReadOnOpen(String roomId) =>
      _owner._withClient((client) async {
        final room = client.getRoomById(roomId);
        if (room == null) throw StateError('Matrix room is unavailable');
        final preference = preferenceForRoom(room);
        if (!preference.manualUnread) return;
        try {
          await writeConversationPreference(
              room, clearUnreadOnOpen(preference));
        } catch (_) {
          // A later sync retries the account-data write.
        }
      });

  Future<void> mutate(String roomId, MatrixConversationMutation mutation) =>
      _owner._withClient((client) async {
        final room = client.getRoomById(roomId);
        if (room == null) throw StateError('Matrix room is unavailable');
        final preference = preferenceForRoom(room);
        switch (mutation) {
          case MatrixConversationMutation.markUnread:
            await writeConversationPreference(room, markUnread(preference));
          case MatrixConversationMutation.togglePin:
            final next = preference.pinned
                ? preference.copyWith(pinned: false, clearPinnedAt: true)
                : preference.copyWith(
                    pinned: true,
                    pinnedAt: DateTime.now().toUtc(),
                  );
            await writeConversationPreference(room, next);
          case MatrixConversationMutation.hide:
            await writeConversationPreference(
              room,
              hideConversation(preference, DateTime.now().toUtc()),
            );
          case MatrixConversationMutation.delete:
            await room.leave();
            await room.forget();
        }
      });

  static MatrixConversationRoomSnapshot _snapshotRoom(Room room) {
    final event = room.lastEvent;
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
      displayName: room.getLocalizedDisplayname(),
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
              text: event.text,
              body: event.body,
              originServerTs: event.originServerTs,
              senderId: event.senderId,
              sender: member(event.senderFromMemoryOrFallback),
              redacted: event.redacted,
            ),
      preference: preferenceForRoom(room),
      notificationCount: room.notificationCount,
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
  });

  final String id;
  final String displayName;
  final Uri? avatarUri;
  final bool isJoined;
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
  final ConversationPreference preference;
  final List<MatrixRoomMemberSnapshot> members;
}

@immutable
final class MatrixForwardDestinationSnapshot {
  const MatrixForwardDestinationSnapshot({
    required this.id,
    required this.displayName,
  });

  final String id;
  final String displayName;
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

  /// A non-SDK snapshot valid only while this lease is active.
  MatrixRoomInfoSnapshot get roomInfo => _snapshotRoomInfo(_activeRoom);

  Future<MatrixRoomInfoSnapshot> refreshRoomInfo() async {
    await _activeRoom.requestParticipants([Membership.join]);
    return roomInfo;
  }

  Future<RoomTimelineCapability> openRoomTimeline({
    required void Function() onUpdate,
  }) async {
    final timeline = await _activeRoom.getTimeline(onUpdate: onUpdate);
    final capability = _SdkRoomTimelineCapability(this, timeline);
    _timelines.add(capability);
    return capability;
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
      writeConversationPreference(_activeRoom, preference);

  Future<DateTime?> serverNow() async {
    final homeserver = _activeRoom.client.homeserver;
    if (homeserver == null) return null;
    try {
      return await MatrixServerClock(
        homeserver: homeserver,
        httpClient: _activeRoom.client.httpClient,
      ).now();
    } catch (_) {
      return null;
    }
  }

  Future<List<MatrixForwardDestinationSnapshot>>
      forwardingDestinations() async {
    final client = _activeRoom.client;
    final vaultRoomId = client
        .accountData[emojiVaultAccountDataType]?.content['room_id']
        ?.toString();
    final reminderRoomId = client
        .accountData[messageReminderAccountDataType]?.content['room_id']
        ?.toString();
    return [
      for (final target in client.rooms)
        if (target.id != roomId &&
            target.encrypted &&
            !isMatrixControlRoom(
              roomId: target.id,
              displayName: target.getLocalizedDisplayname(),
              vaultRoomId: vaultRoomId,
              reminderRoomId: reminderRoomId,
            ))
          MatrixForwardDestinationSnapshot(
            id: target.id,
            displayName: target.getLocalizedDisplayname(),
          ),
    ];
  }

  Future<void> sendEncryptedAttachment({
    required Uint8List bytes,
    required String name,
    required String mimeType,
  }) =>
      _activeRoom.sendFileEvent(
        MatrixFile.fromMimeType(bytes: bytes, name: name, mimeType: mimeType),
      );

  void setOnRevoked(FutureOr<void> Function() callback) =>
      _onRevoked = callback;

  void bindOwnerDrain(Future<void> Function() drain) => _drainOwner = drain;

  @override
  Future<String> sendEncryptedMedia(
    String requestedRoomId,
    List<int> plaintext,
    String mimeType,
  ) {
    if (requestedRoomId != roomId) {
      return Future<String>.error(
        StateError('Matrix room lease identity mismatch'),
      );
    }
    return owner._sendEncryptedMediaFromLease(this, plaintext, mimeType);
  }

  @override
  Future<ResolvedAvatarUrl?> resolveAvatar({
    required Uri? avatarUri,
    required double size,
  }) =>
      MatrixAvatarUrlResolver.resolveForClient(
        avatarUri: avatarUri,
        client: _activeRoom.client,
        size: size,
      );

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
  }) async {
    final payload = Map<String, dynamic>.from(content);
    final eventId = type == null
        ? await _activeRoom.sendEvent(payload)
        : await _activeRoom.sendEvent(payload, type: type);
    if (eventId == null) throw StateError('Matrix room event was not accepted');
  }

  @override
  Future<void> redact(
    String requestedRoomId,
    String eventId,
    String reason,
  ) {
    _requireRoomId(requestedRoomId);
    return _activeRoom.redactEvent(eventId, reason: reason);
  }

  @override
  Future<void> forwardEncryptedCopy(
    String sourceRoomId,
    String targetRoomId,
    String eventId,
  ) async {
    _requireRoomId(sourceRoomId);
    final source = _activeRoom;
    final target = source.client.getRoomById(targetRoomId);
    if (target == null || !target.encrypted) {
      throw StateError('只能转发到端到端加密会话');
    }
    final event = _eventForInteraction(eventId);
    if (event.roomId != null && event.roomId != source.id) {
      throw StateError('消息不属于当前会话');
    }
    if ({MessageTypes.Image, MessageTypes.File, MessageTypes.Audio}
        .contains(event.messageType)) {
      final attachment = await event.downloadAndDecryptAttachment();
      final mimeType = event.content['info'] is Map
          ? (event.content['info'] as Map)['mimetype']?.toString()
          : null;
      await target.sendFileEvent(
        MatrixFile.fromMimeType(
          bytes: attachment.bytes,
          name: event.body,
          mimeType: mimeType,
        ),
      );
      return;
    }
    if (event.messageType != MessageTypes.Text) {
      throw StateError('该消息类型不能转发');
    }
    await target.sendEvent({
      'msgtype': MessageTypes.Text,
      'body': event.body,
      if (event.content['format'] != null) 'format': event.content['format'],
      if (event.content['formatted_body'] != null)
        'formatted_body': event.content['formatted_body'],
    });
  }

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
    announcementVersion:
        announcementVersion is num ? announcementVersion.toInt() : 0,
    preference: preferenceForRoom(room),
    members: [for (final user in room.getParticipants()) member(user)],
  );
}

final class _SdkRoomTimelineCapability implements RoomTimelineCapability {
  _SdkRoomTimelineCapability(this._lease, this._timeline);

  final MatrixRoomLease _lease;
  final Timeline _timeline;
  bool _disposed = false;

  void _ensureActive() {
    if (_disposed) throw StateError('Matrix timeline capability is disposed');
    _lease._activeRoom;
  }

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
    return _timeline.events
        .where(
          (event) =>
              event.type == EventTypes.Message ||
              event.type == changliaoNudgeEventType,
        )
        .toList(growable: false)
        .reversed
        .map(_message)
        .toList(growable: false);
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
    final nudge = event.type == changliaoNudgeEventType;
    final nudgeText = nudge
        ? '${event.content['sender_display_name'] ?? '好友'}拍了拍'
            '${event.content['target_display_name'] ?? '好友'}'
            '${event.content['suffix'] ?? ''}'
        : null;
    return RoomMessageViewModel(
      id: event.eventId,
      senderId: event.senderId,
      text: event.redacted ? '' : (nudgeText ?? event.text),
      isOwn: event.senderId == _lease._activeRoom.client.userID,
      deliveryState: status,
      timestamp: event.originServerTs.toLocal(),
      kind: nudge
          ? RoomMessageKind.system
          : switch (messageType) {
              MessageTypes.Image => RoomMessageKind.image,
              MessageTypes.Audio => RoomMessageKind.voice,
              MessageTypes.File => RoomMessageKind.file,
              changliaoRedPacketMessageType => RoomMessageKind.redPacket,
              _ => RoomMessageKind.text,
            },
      mimeType: mimeType,
      packetId: event.content['packet_id']?.toString(),
      greeting: event.content['greeting']?.toString(),
      voiceDuration: Duration(milliseconds: durationMilliseconds ?? 1000),
      isRecalled: event.redacted,
      replyToEventId: ((event.content['m.relates_to'] as Map?)?['m.in_reply_to']
              as Map?)?['event_id']
          ?.toString(),
    );
  }

  @override
  Future<String> sendText(String text) async {
    _ensureActive();
    return await _lease._activeRoom.sendTextEvent(text, parseCommands: false) ??
        (throw StateError('消息发送失败'));
  }

  @override
  Future<String> sendRedPacketReference(
      String packetId, String greeting) async {
    _ensureActive();
    return await _lease._activeRoom.sendEvent({
          'msgtype': changliaoRedPacketMessageType,
          'body': '[畅聊点钻红包]',
          'packet_id': packetId,
          'greeting': greeting,
        }) ??
        (throw StateError('红包消息发送失败'));
  }

  @override
  Future<Uint8List> loadAttachment(String eventId) async {
    _ensureActive();
    final event = eventById(eventId) ??
        (throw StateError('Matrix timeline event is unavailable'));
    return (await event.downloadAndDecryptAttachment()).bytes;
  }

  @override
  Future<void> retry(String transactionId) async {
    _ensureActive();
    final event = eventById(transactionId) ??
        (throw StateError('Matrix timeline event is unavailable'));
    await event.sendAgain();
  }

  @override
  Future<void> loadHistory() {
    _ensureActive();
    return _timeline.requestHistory();
  }

  @override
  Future<void> markRead() {
    _ensureActive();
    return _timeline.setReadMarker();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timeline.cancelSubscriptions();
    _lease._timelines.remove(this);
  }
}

final class _SdkEmojiVaultBackend implements MatrixEmojiVaultBackend {
  _SdkEmojiVaultBackend(this._lease);

  final MatrixRoomLease _lease;

  Client get _client => _lease._activeRoom.client;

  @override
  String? readStoredRoomId() =>
      _client.accountData[emojiVaultAccountDataType]?.content['room_id']
          as String?;

  @override
  Future<String> createEncryptedVaultRoom() async {
    final roomId = await _client.createGroupChat(
      groupName: '畅聊表情仓库',
      enableEncryption: true,
      invite: const [],
      preset: CreateRoomPreset.privateChat,
      visibility: Visibility.private,
      waitForSync: true,
    );
    var room = _client.getRoomById(roomId);
    if (room == null) {
      throw StateError('Matrix did not create the emoji vault room');
    }
    if (!room.encrypted) {
      await room.enableEncryption();
      await _client.oneShotSync();
      room = _client.getRoomById(roomId);
    }
    if (room == null || !room.encrypted) {
      throw StateError('Matrix did not create an encrypted emoji vault room');
    }
    return roomId;
  }

  @override
  Future<void> storeRoomId(String roomId) async {
    final userId = _client.userID;
    if (userId == null) throw StateError('Matrix client is not logged in');
    await _client.setAccountData(
      userId,
      emojiVaultAccountDataType,
      {'room_id': roomId},
    );
    await _client.oneShotSync();
  }

  Future<Room> _room(String roomId) async {
    var room = _client.getRoomById(roomId);
    if (room == null) {
      await _client.sync();
      room = _client.getRoomById(roomId);
    }
    if (room == null) throw StateError('Emoji vault room is not joined');
    return room;
  }

  @override
  Future<bool> isRoomEncrypted(String roomId) async =>
      (await _room(roomId)).encrypted;

  @override
  Future<Map<String, Object?>> uploadEncrypted(
    String roomId,
    Uint8List bytes,
    String mimeType,
  ) async {
    final room = await _room(roomId);
    if (!room.encrypted) {
      throw StateError('Emoji media upload requires an encrypted room');
    }
    final encrypted = await MatrixFile(
      bytes: bytes,
      name: '畅聊加密表情',
      mimeType: mimeType,
    ).encrypt();
    final uri = await _client.uploadContent(
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
  }

  @override
  Future<void> sendEncryptedEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    final room = await _room(roomId);
    if (!room.encrypted || !_client.encryptionEnabled) {
      throw StateError('Emoji metadata requires Matrix E2EE');
    }
    final eventId =
        await room.sendEvent(Map<String, dynamic>.from(content), type: type);
    if (eventId == null) throw StateError('Emoji vault event was not accepted');
  }

  @override
  Future<List<EmojiVaultEvent>> loadEvents(String roomId) async {
    final timeline = await (await _room(roomId)).getTimeline();
    try {
      return timeline.events
          .map(_decodeEvent)
          .whereType<EmojiVaultEvent>()
          .toList(growable: false);
    } finally {
      timeline.cancelSubscriptions();
    }
  }

  @override
  Future<Uint8List> downloadAndDecrypt(
    String roomId,
    Map<String, Object?> encryptedFile,
  ) async {
    final room = await _room(roomId);
    if (!room.encrypted || !_client.encryptionEnabled) {
      throw StateError('Emoji media download requires Matrix E2EE');
    }
    final url = encryptedFile['url']?.toString();
    final key = encryptedFile['key'];
    final hashes = encryptedFile['hashes'];
    if (url == null || key is! Map || hashes is! Map) {
      throw StateError('Encrypted emoji descriptor is invalid');
    }
    final downloadUri = await Uri.parse(url).getDownloadUri(_client);
    final ciphertext = (await _client.httpClient.get(
      downloadUri,
      headers: {'authorization': 'Bearer ${_client.accessToken}'},
    ))
        .bodyBytes;
    final plaintext = await _client.nativeImplementations.decryptFile(
      EncryptedFile(
        data: ciphertext,
        k: key['k']!.toString(),
        iv: encryptedFile['iv']!.toString(),
        sha256: hashes['sha256']!.toString(),
      ),
    );
    if (plaintext == null) throw StateError('Encrypted emoji integrity failed');
    return plaintext;
  }

  EmojiVaultEvent? _decodeEvent(Event event) {
    if (!event.type.startsWith('com.changliao.emoji.')) return null;
    final content = Map<String, Object?>.from(event.content);
    final at = DateTime.tryParse(content['at']?.toString() ?? '')?.toUtc() ??
        event.originServerTs.toUtc();
    final stableId = content['event_id']?.toString() ?? event.eventId;
    switch (event.type) {
      case 'com.changliao.emoji.add':
        final rawItem = content['item'];
        if (rawItem is! Map) return null;
        return EmojiVaultEvent.add(
          eventId: stableId,
          at: at,
          item: EmojiVaultItem.fromJson(Map<String, Object?>.from(rawItem)),
        );
      case 'com.changliao.emoji.remove':
        final itemId = content['item_id']?.toString();
        return itemId == null
            ? null
            : EmojiVaultEvent.remove(eventId: stableId, at: at, itemId: itemId);
      case 'com.changliao.emoji.recents':
        final rawIds = content['item_ids'];
        return rawIds is! List
            ? null
            : EmojiVaultEvent.recent(
                eventId: stableId,
                at: at,
                itemIds: rawIds.map((value) => value.toString()).toList(),
              );
      default:
        return null;
    }
  }
}

final class _SdkGroupChatInfoGateway implements GroupChatInfoGateway {
  _SdkGroupChatInfoGateway(this._lease);

  final MatrixRoomLease _lease;
  Map<String, Object?>? _cachedSettings;

  Room get _room => _lease._activeRoom;

  Map<String, Object?> get _settings =>
      _cachedSettings ??= Map<String, Object?>.from(
        _room.roomAccountData[groupChatAccountDataType]?.content ?? const {},
      );

  @override
  Future<GroupChatInfoSnapshot> load() async {
    final users = await _room.requestParticipants([Membership.join]);
    final invited = await _room.requestParticipants([Membership.invite]);
    final modern = _room.roomAccountData[conversationPreferenceType]?.content;
    final settings =
        modern == null ? _settings : Map<String, Object?>.from(modern);
    _cachedSettings = settings;
    final allMembers = [...users, ...invited];
    final order = reconcileMemberOrder(
      settings['member_order_ids'] is List
          ? (settings['member_order_ids'] as List)
              .map((value) => value.toString())
          : const <String>[],
      allMembers.map((user) => user.id),
    );
    final userById = {for (final user in allMembers) user.id: user};
    final ownerId = settings['owner_id']?.toString().isNotEmpty == true
        ? settings['owner_id'].toString()
        : _room.getState(EventTypes.RoomCreate)?.senderId ?? '';
    final adminIds = normalizeGroupAdminIds(
      settings['admin_ids'] is List
          ? (settings['admin_ids'] as List).map((value) => value.toString())
          : const <String>[],
      ownerId: ownerId,
    );
    final orderedUsers = [for (final id in order) userById[id]!];
    final activeIds = orderedUsers.map((user) => user.id).toSet();
    final followed = settings['followed_member_ids'];
    return GroupChatInfoSnapshot(
      name: _room.name.trim(),
      announcement: _room.topic,
      remark: settings['remark']?.toString() ?? '',
      muted: settings['muted'] == true,
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
      qrJoinEnabled: settings['qr_join_enabled'] != false,
      joinApprovalRequired: settings['join_approval_required'] == true,
      onlyManagersCanRename: settings['only_managers_can_rename'] == true,
      currentUserId: _room.client.userID,
      members: orderGroupMembers(
        members: [for (final user in orderedUsers) _member(user)],
        ownerId: ownerId,
        adminIds: adminIds.toSet(),
      ),
    );
  }

  GroupChatMember _member(User user) => GroupChatMember(
        matrixUserId: user.id,
        displayName: user.calcDisplayname(),
        matrixAvatarUri: user.avatarUrl,
        membership: user.membership == Membership.join
            ? GroupMemberMembership.joined
            : GroupMemberMembership.invited,
      );

  @override
  Future<void> invite(String matrixUserId) => _room.invite(matrixUserId);

  @override
  Future<void> leave() => _room.leave();

  @override
  Future<void> removeMembers(List<String> matrixUserIds) async {
    for (final userId in matrixUserIds) {
      await _room.kick(userId);
    }
  }

  @override
  Future<void> setAdminIds(List<String> matrixUserIds) => _writeSetting(
        'admin_ids',
        normalizeGroupAdminIds(
          matrixUserIds,
          ownerId: _room.getState(EventTypes.RoomCreate)?.senderId ?? '',
        ),
      );

  @override
  Future<void> setGroupSetting(String key, Object value) =>
      _writeSetting(key, value);

  @override
  Future<void> rename(String name) => _room.setName(name);

  @override
  Future<void> setAnnouncement(String announcement) async {
    await _room.setDescription(announcement);
    final version =
        ((_settings['announcement_version'] as num?)?.toInt() ?? 0) + 1;
    await _writeSetting('announcement_version', version);
  }

  @override
  Future<void> setPreference(
    GroupChatPreference preference,
    bool value,
  ) async {
    await _writeSetting(
      switch (preference) {
        GroupChatPreference.muted => 'muted',
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
  }

  @override
  Future<void> setFollowedMemberIds(List<String> matrixUserIds) =>
      _writeSetting('followed_member_ids', matrixUserIds.take(4).toList());

  @override
  Future<void> setRemark(String remark) => _writeSetting('remark', remark);

  Future<void> _writeSetting(String key, Object value) async {
    final userId = _room.client.userID;
    if (userId == null) throw StateError('Matrix 账号尚未登录');
    final next = {..._settings, key: value};
    await _room.client.setAccountDataPerRoom(
      userId,
      _room.id,
      conversationPreferenceType,
      next,
    );
    _cachedSettings = next;
  }
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
        MatrixTokenLoginGateway,
        AvatarMediaCapability {
  MatrixSdkE2eeClient(
    Client client, {
    required this.homeserver,
    Future<void> Function(Client client)? suspendClient,
    Future<Client> Function()? resumeClient,
    Future<void> Function(Client? client)? clearClientData,
    Future<MatrixClientContinuityMetadata> Function(Client client)?
        readContinuityMetadata,
    MatrixSecurityLogger? securityLogger,
    this.lifecycleDrainTimeout = const Duration(seconds: 5),
  })  : _client = client,
        _suspendClient = suspendClient ?? _defaultSuspend,
        _resumeClient = resumeClient,
        _clearClientData = clearClientData ?? _defaultClear,
        _readContinuityMetadata =
            readContinuityMetadata ?? _unconfiguredContinuityMetadata,
        securityLogger = securityLogger ??
            MatrixSecurityLogger.create(sink: (line) => debugPrint(line));
  Client? _client;
  Client? _pendingCloseClient;
  final Future<void> Function(Client client) _suspendClient;
  final Future<Client> Function()? _resumeClient;
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
  bool _activeContinuityValidated = false;
  bool _credentialsInvalid = false;
  final Uri homeserver;
  final StreamController<void> _syncEvents = StreamController.broadcast();
  final List<_ManagedClientStreamBase> _managedSubscriptions = [];
  final List<_ManagedClientResourceBase> _managedResources = [];
  late final MatrixConversationCapability conversations =
      MatrixConversationCapability._(this);
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
  bool get credentialsInvalid => _credentialsInvalid;
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
      }, authorizeAccess: true);

  @override
  Future<void> loginWithToken(
          {required String loginToken,
          required Uri homeserver,
          String? deviceId}) =>
      _withClient((active) async {
        await active.checkHomeserver(homeserver);
        if (_credentialsInvalid && active.isLogged()) {
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
      }, authorizeAccess: true);

  Future<void> _persistLoggedInContinuity(Client active) async {
    _activeContinuityValidated = false;
    await _readContinuityMetadata(active);
    _activeContinuityValidated = true;
  }

  Stream<void> get syncEvents => _syncEvents.stream;

  @override
  Future<void> sync() => _withClient((active) async {
        try {
          await active.sync();
          await _autoJoinInvitedGroups(active);
          _syncEvents.add(null);
        } on MatrixException catch (error) {
          if (error.errcode == 'M_UNKNOWN_TOKEN' ||
              error.errcode == 'M_FORBIDDEN') {
            _credentialsInvalid = true;
          }
          rethrow;
        }
      }, authorizeAccess: true);

  Future<void> _autoJoinInvitedGroups(Client active) async {
    final invitedRoomIds = active.rooms
        .where((room) =>
            room.membership == Membership.invite && !room.isDirectChat)
        .map((room) => room.id)
        .toList(growable: false);
    if (invitedRoomIds.isEmpty) return;
    final result = await autoJoinInvitedRoomIds(
      invitedRoomIds: invitedRoomIds,
      joinRoom: active.joinRoom,
    );
    debugPrint(
      '[GroupSync] invitations=${invitedRoomIds.length} '
      'joined=${result.joinedRoomIds.length} failures=${result.failures.length}',
    );
    if (result.joinedRoomIds.isNotEmpty) await active.oneShotSync();
  }

  @override
  Future<void> suspend() {
    _accessRevoked = true;
    _revokeManagedResources();
    return _serializeLifecycle(() async {
      final active = _client;
      if (active == null) return;
      await _waitForClientOperationsToDrain();
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

  /// Destructively removes this device's Matrix session and encrypted store.
  /// Only explicit account-switch or confirmed local-clear flows may call it.
  @override
  Future<void> clearLocalChatData() {
    _accessRevoked = true;
    _revokeManagedResources();
    return _serializeLifecycle(() async {
      final target = _client ?? _pendingCloseClient;
      await _waitForClientOperationsToDrain();
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
      await _clearClientData(target);
      _pendingCloseClient = null;
      _suspendedMetadata = null;
      _clearFailed = false;
    });
  }

  Future<T> _withClient<T>(
    Future<T> Function(Client client) operation, {
    bool authorizeAccess = false,
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
      active = await _resumeWithinLifecycle();
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

  Future<MatrixManagedSubscription> _registerInternalStream<T>({
    required Stream<T> Function(Client client) streamFor,
    required void Function(T event) onData,
  }) =>
      _serializeLifecycle(() async {
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
      open: (client) {
        final next = _SdkAppHomeCapability(this, client);
        capability = next;
        return open(next);
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
        final active = await _resumeWithinLifecycle();
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

  Future<Client> _resumeWithinLifecycle() async {
    final active = _client;
    if (active != null) {
      if (!_activeContinuityValidated) {
        await _readContinuityMetadata(active);
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
    if (suspendedMetadata == null ||
        !suspendedMetadata.hasSameContinuity(resumedMetadata)) {
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
    _client = resumed;
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
  Future<String> sendEncryptedMedia(
          String roomId, List<int> plaintext, String mimeType) =>
      _withClient((active) async {
        final room = active.getRoomById(roomId);
        if (room == null) throw StateError('Matrix room is not joined');
        final eventId = await room.sendFileEvent(MatrixFile(
            bytes: Uint8List.fromList(plaintext),
            name: '畅聊附件',
            mimeType: mimeType));
        if (eventId == null) {
          throw StateError('Matrix media event was not accepted');
        }
        return eventId;
      });

  Future<String> _sendEncryptedMediaFromLease(
    MatrixRoomLease lease,
    List<int> plaintext,
    String mimeType,
  ) =>
      _withClient((active) async {
        final leasedRoom = lease._activeRoom;
        if (!identical(leasedRoom.client, active)) {
          throw StateError('Matrix room lease client mismatch');
        }
        final eventId = await leasedRoom.sendFileEvent(MatrixFile(
          bytes: Uint8List.fromList(plaintext),
          name: '畅聊附件',
          mimeType: mimeType,
        ));
        if (eventId == null) {
          throw StateError('Matrix media event was not accepted');
        }
        return eventId;
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
