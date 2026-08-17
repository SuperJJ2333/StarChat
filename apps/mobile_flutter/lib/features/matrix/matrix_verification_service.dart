import 'dart:async';

import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';

/// UI-facing SAS verification state. No secret or message plaintext leaves
/// this process.
final class MatrixVerificationService {
  MatrixVerificationService(this.client);
  final Client client;
  KeyVerification? _active;
  StreamSubscription<KeyVerification>? _subscription;

  KeyVerification? get active => _active;

  Future<KeyVerification> start(String userId, {String? deviceId}) async {
    final encryption = client.encryption;
    if (encryption == null) throw StateError('Matrix encryption is disabled');
    final request = KeyVerification(
      encryption: encryption,
      userId: userId,
      deviceId: deviceId,
    );
    _active = request;
    await request.start();
    return request;
  }

  Future<void> listenForIncoming(
      void Function(KeyVerification) onRequest) async {
    await _subscription?.cancel();
    _subscription = client.onKeyVerificationRequest.stream.listen((request) {
      _active = request;
      onRequest(request);
    });
  }

  Future<void> acceptIncoming() async => _requireActive().acceptVerification();

  Future<void> chooseSas() async {
    final request = _requireActive();
    await request.continueVerification(EventTypes.Sas);
  }

  Future<void> confirmSasMatch() async => _requireActive().acceptSas();

  Future<void> reject() async => _requireActive().rejectVerification();

  Future<void> dispose() async {
    await _subscription?.cancel();
    _active?.dispose();
    _active = null;
  }

  KeyVerification _requireActive() =>
      _active ?? (throw StateError('No active Matrix verification request'));
}
