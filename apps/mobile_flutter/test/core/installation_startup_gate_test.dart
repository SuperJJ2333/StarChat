import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/installation_container_probe.dart';
import 'package:liuhetong_mobile/core/installation_marker.dart';
import 'package:liuhetong_mobile/core/installation_reconciler.dart';
import 'package:liuhetong_mobile/core/installation_startup_gate.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'session_store_test.dart' show MemorySecureKeyValueStore;

final class _MemoryMarker implements InstallationMarkerStore {
  var registered = false;

  @override
  Future<bool> isRegistered() async => registered;

  @override
  Future<void> register() async {
    registered = true;
  }
}

final class _FreshInstallProbe implements InstallationContainerProbe {
  @override
  Future<bool> hasPreviousMatrixStore() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'failed installation check blocks startup until one successful retry',
      (tester) async {
    final outcomes = Queue<InstallationResetOutcome>.of([
      InstallationResetOutcome.failed,
      InstallationResetOutcome.cleared,
    ]);
    var reconcileCalls = 0;
    var startCalls = 0;

    await tester.pumpWidget(CupertinoApp(
      home: InstallationStartupGate(
        reconcile: () async {
          reconcileCalls++;
          return outcomes.removeFirst();
        },
        start: () async {
          startCalls++;
          return const Text('application-ready');
        },
      ),
    ));
    await tester.pump();

    expect(find.text('application-ready'), findsNothing);
    expect(find.text('启动检查未完成，请重试'), findsOneWidget);
    expect(startCalls, 0);

    await tester.tap(find.byKey(const Key('installation-startup-retry')));
    await tester.tap(find.byKey(const Key('installation-startup-retry')));
    await tester.pump();

    expect(find.text('application-ready'), findsOneWidget);
    expect(reconcileCalls, 2);
    expect(startCalls, 1);
  });

  testWidgets(
      'scoped deletion failure blocks startup until retry clears the retained keys',
      (tester) async {
    const suffix =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const scopedKey = 'liuhetong.matrix_database_key.v1.$suffix';
    final memory = MemorySecureKeyValueStore()
      ..values['liuhetong.matrix_account_slots.v1'] = '{"$suffix":"$suffix"}'
      ..values['liuhetong.active_matrix_scope.v1'] = suffix
      ..values[scopedKey] = 'old-database-key'
      ..deleteErrors[scopedKey] = StateError('keychain unavailable');
    final marker = _MemoryMarker();
    final reconciler = InstallationReconciler(
      marker: marker,
      probe: _FreshInstallProbe(),
      store: SecureSessionStore(memory),
    );
    final artifacts = Directory.fromUri(
      Directory.current.uri.resolve(
        '../../docs/verification/artifacts/2026-09-11/integrate-deploy-mi6/',
      ),
    );
    final database =
        File('${artifacts.path}/startup-gate-never-created.sqlite');
    await tester.runAsync(() async {
      await artifacts.create(recursive: true);
      if (await database.exists()) await database.delete();
    });
    addTearDown(() => tester.runAsync(() async {
          if (await database.exists()) await database.delete();
        }));
    var starts = 0;

    await tester.pumpWidget(CupertinoApp(
      home: InstallationStartupGate(
        reconcile: reconciler.reconcile,
        start: () async {
          starts++;
          expect(database.existsSync(), isFalse,
              reason: 'failed reconciliation must not construct a database');
          return const Text('application-ready');
        },
      ),
    ));
    await tester.pump();

    expect(find.text('启动检查未完成，请重试'), findsOneWidget);
    expect(starts, 0);
    expect(memory.values[scopedKey], 'old-database-key');
    expect(marker.registered, isFalse);

    memory.deleteErrors.clear();
    await tester.tap(find.byKey(const Key('installation-startup-retry')));
    await tester.pump();

    expect(find.text('application-ready'), findsOneWidget);
    expect(starts, 1);
    expect(marker.registered, isTrue);
    expect(memory.values.keys.where((key) => key.startsWith('liuhetong.')),
        isEmpty);
  });

  testWidgets('disposed held reconciliation cannot start the application',
      (tester) async {
    final held = Completer<InstallationResetOutcome>();
    var starts = 0;

    await tester.pumpWidget(CupertinoApp(
      home: InstallationStartupGate(
        reconcile: () => held.future,
        start: () async {
          starts++;
          return const Text('application-ready');
        },
      ),
    ));
    await tester.pumpWidget(const SizedBox.shrink());
    held.complete(InstallationResetOutcome.cleared);
    await tester.pump();

    expect(starts, 0);
    expect(find.text('application-ready'), findsNothing);
  });

  testWidgets('repeated failed retries never leak application startup',
      (tester) async {
    final outcomes = Queue<InstallationResetOutcome>.of([
      InstallationResetOutcome.failed,
      InstallationResetOutcome.failed,
      InstallationResetOutcome.adopted,
    ]);
    var startCalls = 0;

    await tester.pumpWidget(CupertinoApp(
      home: InstallationStartupGate(
        reconcile: () async => outcomes.removeFirst(),
        start: () async {
          startCalls++;
          return const Text('application-ready');
        },
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('installation-startup-retry')));
    await tester.pump();

    expect(find.text('application-ready'), findsNothing);
    expect(find.text('启动检查未完成，请重试'), findsOneWidget);
    expect(startCalls, 0);

    await tester.tap(find.byKey(const Key('installation-startup-retry')));
    await tester.pump();
    expect(find.text('application-ready'), findsOneWidget);
    expect(startCalls, 1);
  });
}
