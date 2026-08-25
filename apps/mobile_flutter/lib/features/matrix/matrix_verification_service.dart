import 'dart:async';

import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';

import 'matrix_e2ee_client.dart';

/// UI-facing SAS verification state. No secret or message plaintext leaves
/// this process.
final class MatrixVerificationService {
  MatrixVerificationService(this.matrix);
  final MatrixSdkE2eeClient matrix;
  KeyVerification? _active;
  MatrixManagedSubscription? _subscription;
  MatrixManagedResource? _lifecycleResource;
  Future<void>? _lifecycleSetup;

  Future<void> _ensureLifecycle() => _lifecycleSetup ??= () async {
        _lifecycleResource = await matrix.registerManagedResource(
          open: (_) async {},
          close: () async {
            _active?.dispose();
            _active = null;
          },
        );
      }();

  Future<void> start(String userId, {String? deviceId}) async {
    await _ensureLifecycle();
    await matrix.runClientOperation<void>((client) async {
      final encryption = client.encryption;
      if (encryption == null) {
        throw StateError('Matrix encryption is disabled');
      }
      final request = KeyVerification(
        encryption: encryption,
        userId: userId,
        deviceId: deviceId,
      );
      _active = request;
      await request.start();
    });
  }

  Future<void> listenForIncoming(
      void Function(KeyVerification) onRequest) async {
    await _ensureLifecycle();
    await _subscription?.cancel();
    _subscription = await matrix.subscribeClientStream<KeyVerification>(
      streamFor: (client) => client.onKeyVerificationRequest.stream,
      onData: (request) {
        _active = request;
        onRequest(request);
      },
    );
  }

  Future<void> acceptIncoming() =>
      _withActive((request) => request.acceptVerification());

  Future<void> chooseSas() =>
      _withActive((request) => request.continueVerification(EventTypes.Sas));

  Future<void> confirmSasMatch() =>
      _withActive((request) => request.acceptSas());

  Future<void> reject() =>
      _withActive((request) => request.rejectVerification());

  Future<void> _withActive(
    Future<void> Function(KeyVerification request) action,
  ) async {
    await _ensureLifecycle();
    await matrix.runClientOperation<void>((_) => action(_requireActive()));
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _lifecycleResource?.cancel();
    _lifecycleResource = null;
    _active?.dispose();
    _active = null;
  }

  KeyVerification _requireActive() =>
      _active ?? (throw StateError('No active Matrix verification request'));
}
