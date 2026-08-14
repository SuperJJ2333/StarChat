import 'package:matrix/matrix.dart';
import 'dart:typed_data';

/// Matrix is the encrypted communications domain. This interface never sends message plaintext or recovery keys to the business API.
abstract interface class MatrixSessionGateway {
  bool get isLoggedIn;
  String? get userId;
  String? get deviceId;
  Future<void> sync();
  Future<void> logout();
}

abstract interface class MatrixE2eeClient implements MatrixSessionGateway {
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

final class MatrixSdkE2eeClient implements MatrixE2eeClient {
  MatrixSdkE2eeClient(
    Client client, {
    required this.homeserver,
    Future<Client> Function(Client client)? resetClient,
  })  : _client = client,
        _resetClient = resetClient;
  Client _client;
  final Future<Client> Function(Client client)? _resetClient;
  final Uri homeserver;
  Client get sdkClient => _client;
  Client get client => _client;
  String? _lastRecoveryKey;

  /// Recovery key is exposed only to the caller so it can be written to the
  /// platform secure store; it is never sent to the business API.
  String? get lastRecoveryKey => _lastRecoveryKey;
  @override
  bool get isLoggedIn => client.isLogged();
  @override
  String? get userId => client.userID;
  @override
  String? get deviceId => client.deviceID;
  @override
  Future<void> login(String userId, String password) async {
    await client.checkHomeserver(homeserver);
    await client.login('m.login.password',
        identifier: AuthenticationUserIdentifier(user: userId),
        password: password,
        initialDeviceDisplayName: '六合通移动端');
  }

  @override
  Future<void> sync() async {
    await client.sync();
  }

  @override
  Future<void> logout() async {
    final current = client;
    try {
      await current.logout();
    } finally {
      final resetClient = _resetClient;
      if (resetClient != null) {
        _client = await resetClient(current);
      }
    }
  }

  @override
  Future<void> verifyDevice(String deviceId) async {
    final userId = client.userID;
    if (userId == null) throw StateError('Matrix client is not logged in');
    final device = client.userDeviceKeys[userId]?.deviceKeys[deviceId];
    if (device == null) {
      throw StateError('Device keys are not available; sync first');
    }
    await device.setVerified(true);
  }

  @override
  Future<void> backupKeysToEncryptedStore() async {
    // SSSS creates an account-data backed encrypted store. The recovery key
    // remains local and must be persisted by the caller in secure storage.
    final encryption = client.encryption;
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
    final encryption = client.encryption;
    if (encryption == null) {
      throw StateError('Matrix encryption is not enabled');
    }
    await encryption.crossSigning.selfSign(recoveryKey: recoveryKey);
  }

  @override
  Future<void> restoreEncryptedBackup({required String recoveryKey}) async {
    final encryption = client.encryption;
    if (encryption == null) {
      throw StateError('Matrix encryption is not enabled');
    }
    final handle = encryption.ssss.open(EventTypes.CrossSigningMasterKey);
    await handle.unlock(recoveryKey: recoveryKey);
    await handle.maybeCacheAll();
  }

  @override
  Future<String> sendEncryptedText(String roomId, String plaintext) async {
    final room = client.getRoomById(roomId);
    if (room == null) throw StateError('Matrix room is not joined');
    final eventId = await room.sendTextEvent(plaintext, parseCommands: false);
    if (eventId == null) throw StateError('Matrix event was not accepted');
    return eventId;
  }

  @override
  Future<String> sendEncryptedMedia(
      String roomId, List<int> plaintext, String mimeType) async {
    final room = client.getRoomById(roomId);
    if (room == null) throw StateError('Matrix room is not joined');
    final eventId = await room.sendFileEvent(MatrixFile(
        bytes: Uint8List.fromList(plaintext),
        name: '六合通附件',
        mimeType: mimeType));
    if (eventId == null) {
      throw StateError('Matrix media event was not accepted');
    }
    return eventId;
  }
}
