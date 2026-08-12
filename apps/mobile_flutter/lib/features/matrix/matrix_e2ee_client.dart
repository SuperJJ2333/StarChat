import 'package:matrix/matrix.dart';
/// Matrix is the encrypted communications domain. This interface never sends message plaintext or recovery keys to the business API.
abstract interface class MatrixE2eeClient {
  Future<void> login(String userId, String password);
  Future<void> sync();
  Future<void> verifyDevice(String deviceId);
  Future<void> backupKeysToEncryptedStore();
  Future<String> sendEncryptedText(String roomId, String plaintext);
  Future<String> sendEncryptedMedia(String roomId, List<int> ciphertext, String mimeType);
}
final class MatrixSdkE2eeClient implements MatrixE2eeClient {
  MatrixSdkE2eeClient(this.client);
  final Client client;
  @override Future<void> login(String userId, String password) async => throw UnimplementedError('wire Matrix login on device');
  @override Future<void> sync() async { await client.sync(); }
  @override Future<void> verifyDevice(String deviceId) async => throw UnimplementedError('device verification flow');
  @override Future<void> backupKeysToEncryptedStore() async => throw UnimplementedError('encrypted key backup flow');
  @override Future<String> sendEncryptedText(String roomId, String plaintext) async => throw UnimplementedError('encrypted room send flow');
  @override Future<String> sendEncryptedMedia(String roomId, List<int> ciphertext, String mimeType) async => throw UnimplementedError('encrypted media flow');
}
