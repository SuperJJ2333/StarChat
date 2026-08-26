import 'dart:async';

import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:flutter/foundation.dart';
import '../auth/login_controller.dart' hide LoginState;
import 'avatar_url_resolver.dart';
import 'conversation_preferences.dart';
import 'direct_chat_controller.dart';
import 'group_chat_controller.dart';
import 'matrix_direct_chat_adapter.dart';
import 'matrix_group_chat_adapter.dart';
import 'group_invitation_auto_join.dart';
import 'matrix_call_adapter.dart';
import 'matrix_emoji_vault.dart';
import 'matrix_message_reminder_backend.dart';

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
    return MatrixCallBackend(_client);
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
      backend = await MatrixMessageReminderBackend.open(active);
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
      debugPrint('E2EE_LIFECYCLE_RESOURCE_REVOKE_FAILED');
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

final class MatrixRoomLease
    implements _ManagedClientResourceBase, MatrixEncryptedMediaGateway {
  MatrixRoomLease._(this.owner, this.roomId);
  final MatrixSdkE2eeClient owner;
  final String roomId;
  Room? _room;
  FutureOr<void> Function()? _onRevoked;
  Future<void> Function()? _drainOwner;
  Future<void>? _revocationDrain;
  @override
  bool canceled = false;

  Room get room =>
      _room ?? (throw StateError('Matrix room lease is not active'));

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
  Future<void> attach(Client client) async {
    if (canceled) return;
    _room = client.getRoomById(roomId) ??
        (throw StateError('Matrix room is unavailable'));
    _revocationDrain = null;
  }

  void revokeNow() {
    if (_room == null) return;
    _room = null;
    final callback = _onRevoked;
    if (callback != null) {
      try {
        final result = callback();
        if (result is Future<void>) {
          unawaited(result.catchError((_) {
            debugPrint('E2EE_ROOM_LEASE_REVOKE_CALLBACK_FAILED');
          }));
        }
      } catch (_) {
        debugPrint('E2EE_ROOM_LEASE_REVOKE_CALLBACK_FAILED');
      }
    }
    final drain = _drainOwner;
    _revocationDrain = drain == null
        ? Future<void>.value()
        : drain().catchError((_) {
            debugPrint('E2EE_ROOM_LEASE_DRAIN_FAILED');
          });
  }

  @override
  Future<void> detach() async {
    revokeNow();
    final pending = _revocationDrain;
    if (pending == null) return;
    try {
      await pending;
    } finally {
      _revocationDrain = null;
    }
  }

  @override
  Future<void> cancel() => owner._cancelManagedResource(this);
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
    implements MatrixE2eeClient, MatrixTokenLoginGateway {
  MatrixSdkE2eeClient(
    Client client, {
    required this.homeserver,
    Future<void> Function(Client client)? suspendClient,
    Future<Client> Function()? resumeClient,
    Future<void> Function(Client? client)? clearClientData,
    Future<MatrixClientContinuityMetadata> Function(Client client)?
        readContinuityMetadata,
    this.lifecycleDrainTimeout = const Duration(seconds: 5),
  })  : _client = client,
        _suspendClient = suspendClient ?? _defaultSuspend,
        _resumeClient = resumeClient,
        _clearClientData = clearClientData ?? _defaultClear,
        _readContinuityMetadata =
            readContinuityMetadata ?? _unconfiguredContinuityMetadata;
  Client? _client;
  Client? _pendingCloseClient;
  final Future<void> Function(Client client) _suspendClient;
  final Future<Client> Function()? _resumeClient;
  final Future<void> Function(Client? client) _clearClientData;
  final Future<MatrixClientContinuityMetadata> Function(Client client)
      _readContinuityMetadata;
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
          if (error.errcode == 'M_UNKNOWN_TOKEN') {
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
      await _detachManagedSubscriptions();
      for (final registration in _managedSubscriptions) {
        registration.canceled = true;
      }
      _managedSubscriptions.clear();
      await _detachManagedResources();
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
      debugPrint('E2EE_LIFECYCLE_DRAIN_TIMEOUT');
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
      debugPrint('E2EE_LIFECYCLE_RESUME_REJECT_CLOSE_FAILED');
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
    try {
      await client.logout();
    } finally {
      await client.dispose();
    }
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
        final leasedRoom = lease.room;
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
