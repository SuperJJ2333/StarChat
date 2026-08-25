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

final class MatrixSdkE2eeClient
    implements MatrixE2eeClient, MatrixTokenLoginGateway {
  MatrixSdkE2eeClient(
    Client client, {
    required this.homeserver,
    Future<void> Function(Client client)? suspendClient,
    Future<Client> Function()? resumeClient,
    Future<void> Function(Client? client)? clearClientData,
  })  : _client = client,
        _suspendClient = suspendClient ?? _defaultSuspend,
        _resumeClient = resumeClient,
        _clearClientData = clearClientData ?? _defaultClear;
  Client? _client;
  final Future<void> Function(Client client) _suspendClient;
  final Future<Client> Function()? _resumeClient;
  final Future<void> Function(Client? client) _clearClientData;
  Future<Client>? _resumeInFlight;
  int _lifecycleEpoch = 0;
  bool _suspendedWasLoggedIn = false;
  String? _suspendedUserId;
  String? _suspendedDeviceId;
  final Uri homeserver;
  Client get sdkClient => client;
  Client get client =>
      _client ??
      (throw StateError('Matrix client is suspended and must be resumed'));
  String? _lastRecoveryKey;

  /// Recovery key is exposed only to the caller so it can be written to the
  /// platform secure store; it is never sent to the business API.
  String? get lastRecoveryKey => _lastRecoveryKey;
  @override
  bool get isLoggedIn => _client?.isLogged() ?? _suspendedWasLoggedIn;
  @override
  String? get userId {
    final active = _client;
    return active == null ? _suspendedUserId : active.userID;
  }

  @override
  String? get deviceId {
    final active = _client;
    return active == null ? _suspendedDeviceId : active.deviceID;
  }

  @override
  Future<void> login(String userId, String password) async {
    final active = await _requireClient();
    await active.checkHomeserver(homeserver);
    await active.login('m.login.password',
        identifier: AuthenticationUserIdentifier(user: userId),
        password: password,
        initialDeviceDisplayName: '畅聊移动端');
  }

  @override
  Future<void> loginWithToken(
      {required String loginToken, required Uri homeserver}) async {
    final active = await _requireClient();
    await active.checkHomeserver(homeserver);
    await active.login('m.login.token',
        token: loginToken, initialDeviceDisplayName: '畅聊移动端');
  }

  @override
  Future<void> sync() async {
    final active = await _requireClient();
    await active.sync();
    await _autoJoinInvitedGroups(active);
  }

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
  Future<void> suspend() async {
    _lifecycleEpoch++;
    final active = _client;
    if (active == null) return;
    _suspendedWasLoggedIn = active.isLogged();
    _suspendedUserId = active.userID;
    _suspendedDeviceId = active.deviceID;
    _client = null;
    await _suspendClient(active);
  }

  /// Destructively removes this device's Matrix session and encrypted store.
  /// Only explicit account-switch or confirmed local-clear flows may call it.
  @override
  Future<void> clearLocalChatData() async {
    _lifecycleEpoch++;
    final active = _client;
    _client = null;
    await _clearClientData(active);
    _suspendedWasLoggedIn = false;
    _suspendedUserId = null;
    _suspendedDeviceId = null;
  }

  Future<Client> _requireClient() {
    final active = _client;
    if (active != null) return Future.value(active);
    final inFlight = _resumeInFlight;
    if (inFlight != null) return inFlight;
    late final Future<Client> operation;
    operation = _resumeAndValidate(_lifecycleEpoch).whenComplete(() {
      if (identical(_resumeInFlight, operation)) _resumeInFlight = null;
    });
    _resumeInFlight = operation;
    return operation;
  }

  Future<Client> _resumeAndValidate(int resumeEpoch) async {
    final resume = _resumeClient;
    if (resume == null) {
      throw StateError('Matrix client resume is not configured');
    }
    final resumed = await resume();
    if (resumeEpoch != _lifecycleEpoch) {
      await _closeRejectedResume(resumed);
      throw StateError('Matrix client lifecycle changed during resume');
    }
    final identityMatches = resumed.isLogged() == _suspendedWasLoggedIn &&
        (!_suspendedWasLoggedIn ||
            (resumed.userID == _suspendedUserId &&
                resumed.deviceID == _suspendedDeviceId));
    if (!identityMatches) {
      await _closeRejectedResume(resumed);
      throw StateError('Matrix client resumed with a different identity');
    }
    _client = resumed;
    return resumed;
  }

  Future<void> _closeRejectedResume(Client resumed) async {
    try {
      await _suspendClient(resumed);
    } catch (_) {
      debugPrint('E2EE_LIFECYCLE_RESUME_REJECT_CLOSE_FAILED');
    }
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

  @override
  Future<void> verifyDevice(String deviceId) async {
    final active = await _requireClient();
    final userId = active.userID;
    if (userId == null) throw StateError('Matrix client is not logged in');
    final device = active.userDeviceKeys[userId]?.deviceKeys[deviceId];
    if (device == null) {
      throw StateError('Device keys are not available; sync first');
    }
    await device.setVerified(true);
  }

  @override
  Future<void> backupKeysToEncryptedStore() async {
    // SSSS creates an account-data backed encrypted store. The recovery key
    // remains local and must be persisted by the caller in secure storage.
    final active = await _requireClient();
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
  }

  @override
  Future<void> initializeCrossSigning({required String recoveryKey}) async {
    final active = await _requireClient();
    final encryption = active.encryption;
    if (encryption == null) {
      throw StateError('Matrix encryption is not enabled');
    }
    await encryption.crossSigning.selfSign(recoveryKey: recoveryKey);
  }

  @override
  Future<void> restoreEncryptedBackup({required String recoveryKey}) async {
    final active = await _requireClient();
    final encryption = active.encryption;
    if (encryption == null) {
      throw StateError('Matrix encryption is not enabled');
    }
    final handle = encryption.ssss.open(EventTypes.CrossSigningMasterKey);
    await handle.unlock(recoveryKey: recoveryKey);
    await handle.maybeCacheAll();
  }

  @override
  Future<String> sendEncryptedText(String roomId, String plaintext) async {
    final active = await _requireClient();
    final room = active.getRoomById(roomId);
    if (room == null) throw StateError('Matrix room is not joined');
    final eventId = await room.sendTextEvent(plaintext, parseCommands: false);
    if (eventId == null) throw StateError('Matrix event was not accepted');
    return eventId;
  }

  @override
  Future<String> sendEncryptedMedia(
      String roomId, List<int> plaintext, String mimeType) async {
    final active = await _requireClient();
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
  }

  @override
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId) async {
    final active = await _requireClient();
    return DirectChatService(MatrixDirectChatBackend(active))
        .openOrCreateDirectChat(matrixUserId);
  }

  @override
  Future<String> createEncryptedGroupChat({
    required String name,
    required List<String> matrixUserIds,
  }) async {
    final active = await _requireClient();
    return GroupChatService(MatrixGroupChatBackend(active))
        .createEncryptedGroupChat(
      name: name,
      matrixUserIds: matrixUserIds,
    );
  }
}
