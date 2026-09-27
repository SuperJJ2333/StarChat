import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/core/session_failure.dart';
import 'package:liuhetong_mobile/core/startup_failure_metadata.dart';
import 'session_bootstrap_controller_test.dart' show FakeBusiness, FakeMatrix;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('direct fatal restore state emits closed metadata without cleanup',
      () async {
    final failures = <StartupFailureMetadata>[];
    final business = FakeBusiness(BusinessSessionRestore.authenticated);
    final matrix = FakeMatrix(isLoggedIn: false);
    final controller = SessionBootstrapController(
        business: business, matrix: matrix, onFailure: failures.add);
    addTearDown(controller.dispose);
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
    expect(failures.single.category, SessionFailureCategory.unknown);
    expect(failures.single.boundary, StartupFailureBoundary.localRestore);
    expect(business.localClearCalls, 0);
    expect(matrix.clearCalls, 0);
  });
  test('direct fatal identity mismatch emits no identity values', () async {
    final failures = <StartupFailureMetadata>[];
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@expected:private.test');
    final matrix =
        FakeMatrix(isLoggedIn: true, userId: '@different:private.test');
    final controller = SessionBootstrapController(
        business: business, matrix: matrix, onFailure: failures.add);
    addTearDown(controller.dispose);
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
    expect(failures.single.category, SessionFailureCategory.matrixIdentity);
    expect(failures.single.boundary, StartupFailureBoundary.localIdentity);
    expect(failures.single.toString(), isNot(contains('private.test')));
    expect(business.localClearCalls, 0);
    expect(matrix.clearCalls, 0);
  });
  test('bootstrap swallowed keychain failure emits once without revocation',
      () async {
    final failures = <StartupFailureMetadata>[];
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        error: PlatformException(code: '-34018'));
    final matrix = FakeMatrix(isLoggedIn: false);
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
      onFailure: (failure) {
        failures.add(failure);
        throw StateError('observer');
      },
    );
    addTearDown(controller.dispose);
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
    expect(failures.single.category, SessionFailureCategory.keychainPermission);
    expect(failures.single.boundary, StartupFailureBoundary.bootstrap);
    expect(business.localClearCalls, 0);
    expect(matrix.clearCalls, 0);
  });
}
