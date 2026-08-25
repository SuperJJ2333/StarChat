import 'dart:async';

import 'package:matrix/matrix.dart';
import 'package:flutter/foundation.dart';
import '../auth/login_controller.dart';
import 'direct_chat_controller.dart';
import 'group_chat_controller.dart';
import 'matrix_direct_chat_adapter.dart';
import 'matrix_group_chat_adapter.dart';
import 'group_invitation_auto_join.dart';

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
    implements MatrixSessionGateway, DirectChatGateway, GroupChatGateway {
  Future<void> login(String userId, String password);
  Future<void> verifyDevice(String deviceId);
  Future<void> backupKeysToEncryptedStore();
  Future<void> initializeCrossSigning({required String recoveryKey});
  Future<void> restoreEncryptedBackup({required String recoveryKey});
  Future<String> sendEncryptedText(String roomId, String plaintext);

  /// The SDK encrypts these local plaintext bytes during upload whenever the
  /// target room is encrypted. Callers must never forward them to business APIs.
  Future<String> sendEncryptedMedia(
      String roomId, List<int> plaintext, String mimeType);
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
  });
  final MatrixSdkE2eeClient owner;
  final Future<void> Function(Client client) open;
  final Future<void> Function() close;
  bool opened = false;
  @override
  bool canceled = false;

  @override
  Future<void> attach(Client client) async {
    if (canceled || opened) return;
    await open(client);
    opened = true;
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

final class MatrixRoomLease implements _ManagedClientResourceBase {
  MatrixRoomLease._(this.owner, this.roomId);
  final MatrixSdkE2eeClient owner;
  final String roomId;
  Room? _room;
  FutureOr<void> Function()? _onRevoked;
  Future<void> Function()? _drainOwner;
  @override
  bool canceled = false;

  Room get room =>
      _room ?? (throw StateError('Matrix room lease is not active'));

  void setOnRevoked(FutureOr<void> Function() callback) =>
      _onRevoked = callback;

  void bindOwnerDrain(Future<void> Function() drain) => _drainOwner = drain;

  @override
  Future<void> attach(Client client) async {
    if (canceled) return;
    _room = client.getRoomById(roomId) ??
        (throw StateError('Matrix room is unavailable'));
  }

  @override
  Future<void> detach() async {
    if (_room == null) return;
    await _onRevoked?.call();
    await _drainOwner?.call();
    _room = null;
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
  MatrixClientContinuityMetadata? _suspendedMetadata;
  bool _clearFailed = false;
  bool _activeContinuityValidated = false;
  final Uri homeserver;
  final StreamController<void> _syncEvents = StreamController.broadcast();
  final List<_ManagedClientStreamBase> _managedSubscriptions = [];
  final List<_ManagedClientResourceBase> _managedResources = [];
  @visibleForTesting
  Client get sdkClient =>
      _client ??
      (throw StateError('Matrix client is suspended and must be resumed'));
  String? _lastRecoveryKey;

  /// Recovery key is exposed only to the caller so it can be written to the
  /// platform secure store; it is never sent to the business API.
  String? get lastRecoveryKey => _lastRecoveryKey;
  @override
  bool get isLoggedIn =>
      _client?.isLogged() ?? _suspendedMetadata?.isLoggedIn ?? false;
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
      });

  @override
  Future<void> loginWithToken(
          {required String loginToken, required Uri homeserver}) =>
      _withClient((active) async {
        await active.checkHomeserver(homeserver);
        await active.login('m.login.token',
            token: loginToken, initialDeviceDisplayName: '畅聊移动端');
        await _persistLoggedInContinuity(active);
      });

  Future<void> _persistLoggedInContinuity(Client active) async {
    _activeContinuityValidated = false;
    await _readContinuityMetadata(active);
    _activeContinuityValidated = true;
  }

  Stream<void> get syncEvents => _syncEvents.stream;

  @override
  Future<void> sync() => _withClient((active) async {
        await active.sync();
        await _autoJoinInvitedGroups(active);
        _syncEvents.add(null);
      });

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
  Future<void> suspend() => _serializeLifecycle(() async {
        final active = _client;
        if (active == null) return;
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

  /// Destructively removes this device's Matrix session and encrypted store.
  /// Only explicit account-switch or confirmed local-clear flows may call it.
  @override
  Future<void> clearLocalChatData() => _serializeLifecycle(() async {
        final target = _client ?? _pendingCloseClient;
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

  Future<T> _withClient<T>(Future<T> Function(Client client) operation) =>
      _serializeLifecycle(() async {
        final active = await _resumeWithinLifecycle();
        return operation(active);
      });

  /// Runs a short SDK operation under the same lifecycle ordering as suspend,
  /// resume and explicit local clear. Raw SDK handles may not escape the call.
  Future<T> runClientOperation<T>(
    FutureOr<T> Function(Client client) operation,
  ) =>
      _withClient((active) async {
        final result = await operation(active);
        if (_containsSdkHandle(result)) {
          throw StateError('Matrix SDK handles cannot escape their operation');
        }
        return result;
      });

  Future<MatrixManagedSubscription> subscribeClientStream<T>({
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

  Future<MatrixManagedResource> registerManagedResource({
    required Future<void> Function(Client client) open,
    required Future<void> Function() close,
  }) =>
      _serializeLifecycle(() async {
        final active = await _resumeWithinLifecycle();
        final resource = _ManagedClientResource(
          owner: this,
          open: open,
          close: close,
        );
        await resource.attach(active);
        _managedResources.add(resource);
        return resource;
      });

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

  static bool _containsSdkHandle(Object? value) {
    if (value is Client || value is Room) return true;
    if (value is Iterable<Object?>) return value.any(_containsSdkHandle);
    if (value is Map<Object?, Object?>) {
      return value.keys.any(_containsSdkHandle) ||
          value.values.any(_containsSdkHandle);
    }
    return false;
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
