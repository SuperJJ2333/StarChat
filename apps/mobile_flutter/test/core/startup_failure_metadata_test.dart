import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_failure.dart';
import 'package:liuhetong_mobile/core/startup_failure_metadata.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';

void main() {
  test('composition observer preserves success and safe L07 failure metadata',
      () async {
    expect(
        await observeStartupOperation(() async => 7,
            boundary: StartupFailureBoundary.databaseOpen),
        7);
    await expectLater(
        observeStartupOperation(
            () async => throw PlatformException(
                code: '-25308', message: 'PRIVATE-CREDENTIAL'),
            boundary: StartupFailureBoundary.accountStorage,
            loginStage: StartupLoginStage.accountStorage),
        throwsA(isA<StartupFailureException>()
            .having((error) => error.startupFailure.nativeStatus,
                'native status', StartupNativeStatus.interactionNotAllowed)
            .having((error) => error.startupFailure.loginStage, 'login stage',
                StartupLoginStage.accountStorage)
            .having((error) => error.toString(), 'safe description',
                isNot(contains('PRIVATE')))));
  });
  test('keychain status is projected without retaining private error details',
      () {
    final failure = safeStartupFailure(
      PlatformException(
          code: 'secure_session_status',
          message: 'PRIVATE-TOKEN',
          details: {'status': -25308, 'path': 'PRIVATE-PATH'}),
      boundary: StartupFailureBoundary.identitySnapshot,
    );
    expect(failure.category, SessionFailureCategory.protectedData);
    expect(failure.nativeStatus, StartupNativeStatus.interactionNotAllowed);
    expect(failure.boundary.wireName, 'identity_snapshot');
    expect(failure.toString(), isNot(contains('PRIVATE')));
  });

  test('entitlement and unlisted status remain bounded enums', () {
    final permission = safeStartupFailure(
      PlatformException(code: '-34018'),
      boundary: StartupFailureBoundary.databaseKey,
    );
    expect(permission.category, SessionFailureCategory.keychainPermission);
    expect(permission.nativeStatus!.wireValue, -34018);
    final unknown = safeStartupFailure(
      PlatformException(
          code: 'secure_session_status', details: {'status': 918273}),
      boundary: StartupFailureBoundary.databaseKey,
    );
    expect(unknown.nativeStatus!.wireValue, 'other');
    expect(unknown.toString(), isNot(contains('918273')));
  });

  test('observer faults cannot change session outcome', () {
    final failure = safeStartupFailure(StateError('PRIVATE-STATE'),
        boundary: StartupFailureBoundary.applicationStart);
    expect(
        () =>
            notifyStartupFailure((_) => throw StateError('callback'), failure),
        returnsNormally);
    expect(failure.category, SessionFailureCategory.unknown);
  });

  test(
      'preflight and L07 wrappers preserve safe native cause and deep boundary',
      () {
    final preflight = MatrixLocalIdentityPreflightException.fromError(
      MatrixLocalIdentityCause.unreadable,
      PlatformException(code: '-34018', message: 'PRIVATE-KEY'),
      boundary: StartupFailureBoundary.identitySnapshot,
    );
    final wrapped = LoginStageException.fromCause('account_storage', preflight);
    final safe =
        safeStartupFailure(wrapped, boundary: StartupFailureBoundary.bootstrap);
    expect(safe.category, SessionFailureCategory.keychainPermission);
    expect(safe.boundary, StartupFailureBoundary.identitySnapshot);
    expect(safe.preflightCause, StartupIdentityCause.unreadable);
    expect(safe.nativeStatus!.wireValue, -34018);
    expect(safe.loginStage!.wireName, 'L07');
    expect(preflight.canCreateNewDevice, isFalse);
    expect(wrapped.message, isNot(contains('PRIVATE')));
  });

  test(
      'L04 direct wrapper projects native status before original error is lost',
      () {
    final wrapped = LoginStageException.fromCause(
        'matrix_login',
        PlatformException(
            code: 'secure_session_status', details: {'status': -25308}));
    final safe =
        safeStartupFailure(wrapped, boundary: StartupFailureBoundary.bootstrap);
    expect(safe.loginStage, StartupLoginStage.matrixLogin);
    expect(safe.nativeStatus!.wireValue, -25308);
    expect(safe.boundary, StartupFailureBoundary.matrixLogin);
  });
}
