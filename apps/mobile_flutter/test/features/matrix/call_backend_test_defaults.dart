import 'package:liuhetong_mobile/features/matrix/call_controller.dart';

/// Shared test defaults for [CallBackend] fakes (Task F).
///
/// [CallBackend] gained [CallBackend.verifyStartTarget] /
/// [CallBackend.startVerified] so a single outgoing `start` validates the
/// encrypted two-party membership exactly once. Fakes can mix this in to get
/// a safe default implementation instead of repeating the boilerplate:
///
/// ```dart
/// final class FakeBackend with CallBackendTestDefaults implements CallBackend {
///   ...
/// }
/// ```
mixin CallBackendTestDefaults implements CallBackend {
  /// Default: the room is treated as safe (override to test rejections).
  bool get fakeSafeRoom => true;

  @override
  Future<VerifiedCallTarget?> verifyStartTarget(
          String roomId, String matrixUserId) async =>
      fakeSafeRoom
          ? VerifiedCallTarget(roomId: roomId, remoteUserId: matrixUserId)
          : null;

  @override
  Future<void> startVerified(VerifiedCallTarget target, CallMediaType type) =>
      start(target.roomId, target.remoteUserId, type);
}

/// Default permission gateway: grants every request.
mixin CallPermissionTestDefaults implements CallPermissionGateway {
  bool get fakePermissionGranted => true;

  @override
  Future<bool> request({required bool video}) async => fakePermissionGranted;
}
