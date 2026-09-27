import 'package:flutter/services.dart';

import 'session_failure.dart';

enum StartupFailureStage {
  initialization('initialization'),
  installationCheck('installation_check'),
  diagnosticSalt('diagnostic_salt'),
  installationIdentity('installation_identity'),
  matrixPreflight('matrix_preflight'),
  startApplication('start_application'),
  sessionBootstrap('session_bootstrap'),
  localRestore('local_restore');

  const StartupFailureStage(this.wireName);
  final String wireName;
}

enum StartupFailureBoundary {
  versionLoad('version_load'),
  preferencesLoad('preferences_load'),
  markerRead('marker_read'),
  protectedDataProbe('protected_data_probe'),
  containerProbe('container_probe'),
  markerRegister('marker_register'),
  installationCleanup('installation_cleanup'),
  reconcile('reconcile'),
  diagnosticSalt('diagnostic_salt'),
  installationIdentity('installation_identity'),
  identitySnapshot('identity_snapshot'),
  databasePresence('database_presence'),
  databaseHeader('database_header'),
  databaseIdentityRead('database_identity_read'),
  olmIdentityCheck('olm_identity_check'),
  originalIdentitySearch('original_identity_search'),
  databaseKey('database_key'),
  databaseOpen('database_open'),
  clientMigration('client_migration'),
  applicationStart('application_start'),
  localIdentity('local_identity'),
  matrixGrant('matrix_grant'),
  switchLocalClear('switch_local_clear'),
  matrixLogin('matrix_login'),
  matrixSync('matrix_sync'),
  identityBinding('identity_binding'),
  accountStorage('account_storage'),
  matrixSession('matrix_session'),
  localRestore('local_restore'),
  bootstrap('bootstrap');

  const StartupFailureBoundary(this.wireName);
  final String wireName;
}

enum StartupIdentityCause {
  missingDatabaseWithBinding,
  missingDatabaseWithKey,
  missingKey,
  missingOlmAccount,
  fingerprintMismatch,
  identityMismatch,
  unreadable,
  originalIdentityElsewhere,
  multipleCandidates,
  recoveryPending,
  legacyPlaintextMigrationDeferred;

  String get wireName => name;
}

enum StartupNativeStatus {
  interactionNotAllowed(-25308),
  missingEntitlement(-34018),
  notAvailable(-25291),
  itemNotFound(-25300),
  parameter(-50),
  other('other');

  const StartupNativeStatus(this.wireValue);
  final Object wireValue;
}

enum StartupLoginStage {
  localIdentity('L01', StartupFailureBoundary.localIdentity),
  matrixGrant('L02', StartupFailureBoundary.matrixGrant),
  switchLocalClear('L03', StartupFailureBoundary.switchLocalClear),
  matrixLogin('L04', StartupFailureBoundary.matrixLogin),
  matrixSync('L05', StartupFailureBoundary.matrixSync),
  identityBinding('L06', StartupFailureBoundary.identityBinding),
  accountStorage('L07', StartupFailureBoundary.accountStorage),
  matrixSession('L08', StartupFailureBoundary.matrixSession);

  const StartupLoginStage(this.wireName, this.boundary);
  final String wireName;
  final StartupFailureBoundary boundary;

  static StartupLoginStage? fromLocalStage(String stage) => switch (stage) {
        'local_identity' => localIdentity,
        'matrix_grant' => matrixGrant,
        'switch_local_clear' => switchLocalClear,
        'matrix_login' => matrixLogin,
        'matrix_sync' => matrixSync,
        'identity_binding' => identityBinding,
        'account_storage' => accountStorage,
        'matrix_session' => matrixSession,
        _ => null,
      };
}

extension StartupSessionFailureWire on SessionFailureCategory {
  String get wireName => switch (this) {
        SessionFailureCategory.protectedData => 'protected_data',
        SessionFailureCategory.keychainPermission => 'keychain_permission',
        SessionFailureCategory.matrixIdentity => 'matrix_identity',
        SessionFailureCategory.matrixCredentials => 'matrix_credentials',
        SessionFailureCategory.matrixRejected => 'matrix_rejected',
        SessionFailureCategory.matrixRateLimited => 'matrix_rate_limited',
        SessionFailureCategory.matrixService => 'matrix_service',
        _ => name,
      };
}

/// An exception may implement this without retaining its original error.
abstract interface class StartupFailureProvider {
  StartupFailureMetadata get startupFailure;
}

/// Used only at app composition boundaries after existing recovery decisions.
final class StartupFailureException
    implements Exception, StartupFailureProvider {
  const StartupFailureException(this.startupFailure);
  @override
  final StartupFailureMetadata startupFailure;
  @override
  String toString() =>
      'StartupFailureException(${startupFailure.category.wireName})';
}

Future<T> observeStartupOperation<T>(Future<T> Function() operation,
    {required StartupFailureBoundary boundary,
    StartupLoginStage? loginStage}) async {
  try {
    return await operation();
  } catch (error) {
    final failure = safeStartupFailure(error, boundary: boundary);
    throw StartupFailureException(failure.withLoginStage(loginStage));
  }
}

StartupFailureStage startupStageForFailure(StartupFailureMetadata failure) =>
    switch (failure.boundary) {
      StartupFailureBoundary.versionLoad ||
      StartupFailureBoundary.preferencesLoad =>
        StartupFailureStage.initialization,
      StartupFailureBoundary.markerRead ||
      StartupFailureBoundary.protectedDataProbe ||
      StartupFailureBoundary.containerProbe ||
      StartupFailureBoundary.markerRegister ||
      StartupFailureBoundary.installationCleanup ||
      StartupFailureBoundary.reconcile =>
        StartupFailureStage.installationCheck,
      StartupFailureBoundary.diagnosticSalt =>
        StartupFailureStage.diagnosticSalt,
      StartupFailureBoundary.installationIdentity =>
        StartupFailureStage.installationIdentity,
      StartupFailureBoundary.identitySnapshot ||
      StartupFailureBoundary.databasePresence ||
      StartupFailureBoundary.databaseHeader ||
      StartupFailureBoundary.databaseIdentityRead ||
      StartupFailureBoundary.olmIdentityCheck ||
      StartupFailureBoundary.originalIdentitySearch ||
      StartupFailureBoundary.databaseKey ||
      StartupFailureBoundary.databaseOpen ||
      StartupFailureBoundary.clientMigration =>
        StartupFailureStage.matrixPreflight,
      _ => StartupFailureStage.startApplication,
    };

final class StartupFailureMetadata {
  const StartupFailureMetadata({
    required this.category,
    required this.boundary,
    this.preflightCause,
    this.nativeStatus,
    this.loginStage,
  });

  final SessionFailureCategory category;
  final StartupFailureBoundary boundary;
  final StartupIdentityCause? preflightCause;
  final StartupNativeStatus? nativeStatus;
  final StartupLoginStage? loginStage;

  StartupFailureMetadata withLoginStage(StartupLoginStage? stage) =>
      StartupFailureMetadata(
        category: category,
        boundary: boundary,
        preflightCause: preflightCause,
        nativeStatus: nativeStatus,
        loginStage: stage ?? loginStage,
      );

  @override
  String toString() =>
      'StartupFailureMetadata(${category.wireName},${boundary.wireName})';
}

StartupFailureMetadata safeStartupFailure(Object error,
    {required StartupFailureBoundary boundary}) {
  if (error is StartupFailureProvider) return error.startupFailure;
  StartupNativeStatus? nativeStatus;
  if (error is PlatformException) {
    final details = error.details;
    final value = error.code == 'secure_session_status' && details is Map
        ? details['status']
        : null;
    final status = (value is int ? value : null) ??
        int.tryParse(error.code) ??
        (error.code == 'Unexpected security result code' && details is int
            ? details
            : null);
    if (status != null) {
      nativeStatus = switch (status) {
        -25308 => StartupNativeStatus.interactionNotAllowed,
        -34018 => StartupNativeStatus.missingEntitlement,
        -25291 => StartupNativeStatus.notAvailable,
        -25300 => StartupNativeStatus.itemNotFound,
        -50 => StartupNativeStatus.parameter,
        _ => StartupNativeStatus.other,
      };
    }
  }
  return StartupFailureMetadata(
    category: classifySessionFailure(error),
    boundary: boundary,
    nativeStatus: nativeStatus,
  );
}

typedef StartupFailureObserver = void Function(StartupFailureMetadata failure);

void notifyStartupFailure(
    StartupFailureObserver? observer, StartupFailureMetadata failure) {
  try {
    observer?.call(failure);
  } catch (_) {
    // Observability never changes authentication, recovery, or startup results.
  }
}
