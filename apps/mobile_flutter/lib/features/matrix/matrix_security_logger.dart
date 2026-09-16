import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A deliberately small, allowlisted lifecycle logger.
///
/// Callers cannot attach exception text, Matrix identifiers, event content, or
/// any key material. That keeps lifecycle diagnostics useful without crossing
/// the E2EE trust boundary. Identity correlation is possible only through
/// [MatrixDiagnosticIdentity], whose only constructor requires an already
/// salted [MatrixDiagnosticHasher] and therefore cannot carry a raw value.
enum MatrixSecurityStage {
  roomLeaseDrain('room_lease_drain'),
  lifecycle('lifecycle'),
  accountSelection('account_selection'),
  deviceRotation('device_rotation'),
  continuity('continuity');

  const MatrixSecurityStage(this.value);
  final String value;
}

enum MatrixSecurityOutcome {
  success('success'),
  failure('failure'),
  timeout('timeout');

  const MatrixSecurityOutcome(this.value);
  final String value;
}

enum MatrixSecurityCode {
  roomLeaseDrainTimeout('E2EE_ROOM_LEASE_DRAIN_TIMEOUT'),
  roomLeaseDrainFailed('E2EE_ROOM_LEASE_DRAIN_FAILED'),
  lifecycleDrainTimeout('E2EE_LIFECYCLE_DRAIN_TIMEOUT'),
  lifecycleSuspendDrainTimeout('E2EE_LIFECYCLE_SUSPEND_DRAIN_TIMEOUT'),
  lifecycleSuspendFailed('E2EE_LIFECYCLE_SUSPEND_FAILED'),
  lifecycleSuspendCloseFailed('E2EE_LIFECYCLE_SUSPEND_CLOSE_FAILED'),
  lifecycleContinuityReadFailed('E2EE_LIFECYCLE_CONTINUITY_READ_FAILED'),
  lifecycleSuspendBegin('E2EE_LIFECYCLE_SUSPEND_BEGIN'),
  lifecycleSuspendCompleted('E2EE_LIFECYCLE_SUSPEND_COMPLETED'),
  lifecycleClientDisposeBegin('E2EE_LIFECYCLE_CLIENT_DISPOSE_BEGIN'),
  accountSelectBegin('E2EE_ACCOUNT_SELECT_BEGIN'),
  lifecycleResumeRejectCloseFailed('E2EE_LIFECYCLE_RESUME_REJECT_CLOSE_FAILED'),
  lifecycleResourceRevokeFailed('E2EE_LIFECYCLE_RESOURCE_REVOKE_FAILED'),
  lifecycleClientDisposeFailed('E2EE_LIFECYCLE_CLIENT_DISPOSE_FAILED'),
  roomLeaseRevokeCallbackFailed('E2EE_ROOM_LEASE_REVOKE_CALLBACK_FAILED'),
  homeResourceDisposeFailed('E2EE_HOME_RESOURCE_DISPOSE_FAILED'),
  accountSelectContinuityMismatch('E2EE_ACCOUNT_SELECT_CONTINUITY_MISMATCH'),
  accountSelectResumeFailed('E2EE_ACCOUNT_SELECT_RESUME_FAILED'),
  continuityBindingMismatch('E2EE_CONTINUITY_BINDING_MISMATCH'),
  continuityFingerprintMismatch('E2EE_CONTINUITY_FINGERPRINT_MISMATCH'),
  continuityGenerationMismatch('E2EE_CONTINUITY_GENERATION_MISMATCH'),
  continuityIdentityUnavailable('E2EE_CONTINUITY_IDENTITY_UNAVAILABLE'),
  continuityResumeUnverified('E2EE_CONTINUITY_RESUME_UNVERIFIED'),
  deviceRotationDetected('E2EE_DEVICE_ROTATION_DETECTED'),
  deviceRotationBindingMigrated('E2EE_DEVICE_ROTATION_BINDING_MIGRATED'),
  deviceRotationBindingRejected('E2EE_DEVICE_ROTATION_BINDING_REJECTED');

  const MatrixSecurityCode(this.value);
  final String value;
}

/// 加盐哈希后的不透明标识集合。
///
/// 唯一构造入口是 [MatrixDiagnosticHasher]，因此原始 Matrix user id、device id、
/// scope、generation 或 fingerprint 都不可能出现在日志里。
final class MatrixDiagnosticIdentity {
  const MatrixDiagnosticIdentity._(this.hashed);

  final Map<String, String> hashed;
  bool get isEmpty => hashed.isEmpty;
  bool get isNotEmpty => hashed.isNotEmpty;
}

/// 使用本机安全存储里的 diagnostic salt 做关联哈希。
///
/// salt 只用于本地诊断关联，不是密钥材料；哈希不可逆且加了唯一 salt，
/// 因此即使日志被导出也无法与其它设备的标识对表。
final class MatrixDiagnosticHasher {
  const MatrixDiagnosticHasher(this._salt);

  final String _salt;

  MatrixDiagnosticIdentity of({
    String? matrixUserId,
    String? deviceId,
    String? previousDeviceId,
    String? databaseGeneration,
    String? fingerprint,
    String? scope,
  }) =>
      MatrixDiagnosticIdentity._({
        if (matrixUserId != null) 'matrix_user': _hash(matrixUserId),
        if (deviceId != null) 'device_id': _hash(deviceId),
        if (previousDeviceId != null)
          'previous_device_id': _hash(previousDeviceId),
        if (databaseGeneration != null)
          'database_generation': _hash(databaseGeneration),
        if (fingerprint != null) 'fingerprint': _hash(fingerprint),
        if (scope != null) 'scope': _hash(scope),
      });

  String _hash(String value) {
    final digest = sha256.convert(utf8.encode('$_salt|$value')).bytes;
    return base64Url.encode(digest).replaceAll('=', '').substring(0, 22);
  }
}

final class MatrixSecurityLogger {
  MatrixSecurityLogger({
    required String Function() traceId,
    required void Function(String line) sink,
  })  : _newTraceIdFactory = traceId,
        _sink = sink,
        _activeTraceId = traceId();

  final String Function() _newTraceIdFactory;
  final void Function(String line) _sink;
  String _activeTraceId;

  factory MatrixSecurityLogger.create({
    required void Function(String line) sink,
    String Function()? traceIdFactory,
  }) =>
      MatrixSecurityLogger(traceId: traceIdFactory ?? _newTraceId, sink: sink);

  String get traceId => _activeTraceId;

  /// 开始一次可关联的生命周期操作（一次登录尝试、一次挂起、一次账号切换）。
  /// 之后写入的事件共享同一个 id，等价于 login_attempt_id。
  String beginLifecycleOperation() {
    _activeTraceId = _newTraceIdFactory();
    return _activeTraceId;
  }

  void record({
    required MatrixSecurityStage stage,
    required MatrixSecurityOutcome outcome,
    required MatrixSecurityCode eventCode,
    MatrixDiagnosticIdentity? identity,
  }) {
    final hashed = identity?.hashed;
    _sink(jsonEncode({
      'trace_id': _activeTraceId,
      'stage': stage.value,
      'outcome': outcome.value,
      'event_code': eventCode.value,
      if (hashed != null && hashed.isNotEmpty) 'identity': hashed,
    }));
  }

  static String _newTraceId() => base64UrlEncode(
        List<int>.generate(18, (_) => Random.secure().nextInt(256)),
      ).replaceAll('=', '');
}
