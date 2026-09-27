import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/installation_container_probe.dart';
import 'package:liuhetong_mobile/core/installation_marker.dart';
import 'package:liuhetong_mobile/core/installation_reconciler.dart';
import 'package:liuhetong_mobile/core/installation_startup_gate.dart';
import 'package:liuhetong_mobile/core/session_failure.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/startup_failure_metadata.dart';
import 'session_store_test.dart' show MemorySecureKeyValueStore;

class _UnreadableMarker implements InstallationMarkerStore {
  @override
  Future<bool> isRegistered() async => throw PlatformException(code: '-25308');
  @override
  Future<void> register() async => throw StateError('must not write');
}

class _UntouchedProbe implements InstallationContainerProbe {
  @override
  Future<bool> hasPreviousMatrixStore() async =>
      throw StateError('must not probe');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reconciler reports swallowed marker failure without clearing keys',
      () async {
    final failures = <StartupFailureMetadata>[];
    final memory = MemorySecureKeyValueStore()..values['retained'] = 'KEEP';
    final reconciler = InstallationReconciler(
      marker: _UnreadableMarker(),
      probe: _UntouchedProbe(),
      store: SecureSessionStore(memory),
      onFailure: failures.add,
    );
    expect(await reconciler.reconcile(), InstallationResetOutcome.failed);
    expect(memory.values['retained'], 'KEEP');
    expect(failures.single.category, SessionFailureCategory.protectedData);
    expect(failures.single.boundary, StartupFailureBoundary.markerRead);
  });
  testWidgets(
      'gate records terminal failure before UI without awaiting observer',
      (tester) async {
    final failures = <StartupFailureMetadata>[];
    await tester.pumpWidget(CupertinoApp(
        home: InstallationStartupGate(
      reconcile: () async => InstallationResetOutcome.notNeeded,
      start: () async => throw PlatformException(code: '-34018'),
      onFailure: (failure) {
        failures.add(failure);
        throw StateError('observer');
      },
    )));
    await tester.pumpAndSettle();
    expect(failures.single.nativeStatus!.wireValue, -34018);
    expect(find.byKey(const Key('installation-startup-retry')), findsOneWidget);
    expect(find.textContaining('安全存储访问权限异常'), findsOneWidget);
  });
}
