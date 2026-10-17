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
  for (final stage in ['prepare', 'reconcile', 'admission']) {
    for (final retire in ['timeout', 'dispose']) {
      testWidgets(
          'enhanced $stage stays private then $retire retires late completion',
          (tester) async {
        final held = Completer<void>();
        final attempts = <StartupAdmissionAttempt>[];
        var prepares = 0;
        var checks = 0;
        var compositions = 0;
        var retiredOwners = 0;
        await tester.pumpWidget(CupertinoApp(
            home: InstallationStartupGate(
          prepare: () async {
            prepares++;
            if (stage == 'prepare') await held.future;
          },
          reconcile: () async {
            checks++;
            if (stage == 'reconcile') await held.future;
            return InstallationResetOutcome.notNeeded;
          },
          start: () async => const Text('legacy'),
          startWithAdmission: (attempt) async {
            attempts.add(attempt);
            attempt.onRetire(() => retiredOwners++);
            if (stage == 'admission' && attempts.length == 1) await held.future;
            attempt.checkCurrent();
            compositions++;
            return const Text('real-interactive-list');
          },
        )));
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(CupertinoActivityIndicator), findsNothing);
        expect(tester.binding.sendFramesToEngine, isFalse);
        if (retire == 'dispose') {
          await tester.pumpWidget(const SizedBox.shrink());
          held.complete();
          await tester.pump();
          expect(compositions, 0);
          expect(tester.binding.sendFramesToEngine, isTrue);
        } else {
          await tester.pump(const Duration(seconds: 6));
          expect(find.byKey(const Key('installation-startup-retry')),
              findsOneWidget);
          await tester.tap(find.byKey(const Key('installation-startup-retry')));
          await tester.pump();
          expect(prepares, 1, reason: 'Retry joins outstanding minimum checks');
          if (stage == 'reconcile') expect(checks, 1);
          held.complete();
          await tester.pumpAndSettle();
          expect(find.text('real-interactive-list'), findsOneWidget);
          expect(compositions, 1);
        }
        if (stage == 'admission') {
          expect(attempts.first.isCurrent, isFalse);
          expect(retiredOwners, 1);
        }
      });
    }
  }
  testWidgets(
      'enhanced prepare and reconciliation share one admission deadline',
      (tester) async {
    final prepared = Completer<void>();
    final checked = Completer<InstallationResetOutcome>();
    var starts = 0;
    await tester.pumpWidget(CupertinoApp(
        home: InstallationStartupGate(
      prepare: () => prepared.future,
      reconcile: () => checked.future,
      start: () async => const SizedBox.shrink(),
      startWithAdmission: (_) async {
        starts++;
        return const Text('content');
      },
    )));
    await tester.pump(const Duration(seconds: 4));
    prepared.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const Key('installation-startup-retry')), findsOneWidget);
    checked.complete(InstallationResetOutcome.notNeeded);
    await tester.pump();
    expect(starts, 0);
  });
  testWidgets(
      'slow minimum checks publish real content as the first engine frame',
      (tester) async {
    final prepared = Completer<void>();
    final checked = Completer<InstallationResetOutcome>();
    final admitted = Completer<Widget>();
    await tester.pumpWidget(CupertinoApp(
        home: InstallationStartupGate(
      prepare: () => prepared.future,
      reconcile: () => checked.future,
      start: () => admitted.future,
      startWithAdmission: (_) => admitted.future,
    )));
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.sendFramesToEngine, isFalse);
    prepared.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.sendFramesToEngine, isFalse);
    checked.complete(InstallationResetOutcome.notNeeded);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.sendFramesToEngine, isFalse);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    var observedVisibleContent = false;
    void checkVisibleFrame(Duration _) {
      if (!tester.binding.sendFramesToEngine) {
        tester.binding.addPostFrameCallback(checkVisibleFrame);
        return;
      }
      expect(find.text('ready-real-content'), findsOneWidget);
      observedVisibleContent = true;
    }

    tester.binding.addPostFrameCallback(checkVisibleFrame);
    admitted.complete(const Text('ready-real-content'));
    await tester.pump();
    await tester.pump();
    expect(tester.binding.sendFramesToEngine, isTrue);
    expect(observedVisibleContent, isTrue);
  });

  testWidgets(
      'known cache miss cancels deadline and releases normal initialization',
      (tester) async {
    final loaded = Completer<Widget>();
    await tester.pumpWidget(CupertinoApp(
        home: InstallationStartupGate(
      reconcile: () async => InstallationResetOutcome.notNeeded,
      start: () => loaded.future,
      startWithAdmission: (attempt) {
        attempt.cacheMiss();
        return loaded.future;
      },
    )));
    await tester.pump(const Duration(seconds: 9));
    expect(tester.binding.sendFramesToEngine, isTrue);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(find.byKey(const Key('installation-startup-retry')), findsNothing);
    loaded.complete(const Text('normal-content'));
    await tester.pumpAndSettle();
    expect(find.text('normal-content'), findsOneWidget);
  });
  testWidgets('held reconciliation releases a safe shell after one second',
      (tester) async {
    final checked = Completer<InstallationResetOutcome>();
    var checks = 0;
    var starts = 0;
    await tester.pumpWidget(CupertinoApp(
      home: InstallationStartupGate(
        reconcile: () {
          checks++;
          return checked.future;
        },
        start: () async {
          starts++;
          return const Text('account-content');
        },
      ),
    ));
    await tester.pump(const Duration(milliseconds: 999));
    expect(find.text('正在启动畅聊'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('正在启动畅聊'), findsOneWidget);
    expect(tester.binding.sendFramesToEngine, isTrue);
    expect(find.text('account-content'), findsNothing);
    expect(find.byKey(const Key('installation-startup-retry')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('正在检查本地安装状态，请稍候'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(checks, 1);
    expect(starts, 0);
    checked.complete(InstallationResetOutcome.notNeeded);
    await tester.pumpAndSettle();
    expect(starts, 1);
    expect(find.text('account-content'), findsOneWidget);
  });

  testWidgets(
      'held application start reports its actual phase without reopening',
      (tester) async {
    final loaded = Completer<Widget>();
    var starts = 0;
    await tester.pumpWidget(CupertinoApp(
      home: InstallationStartupGate(
        reconcile: () async => InstallationResetOutcome.notNeeded,
        start: () {
          starts++;
          return loaded.future;
        },
      ),
    ));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('正在打开本地聊天，请稍候'), findsOneWidget);
    expect(find.byKey(const Key('installation-startup-retry')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(starts, 1);
    loaded.complete(const Text('late-account-content'));
    await tester.pumpAndSettle();
    expect(find.text('late-account-content'), findsOneWidget);
    expect(starts, 1);
  });

  testWidgets('disposing a held gate cancels shell timers and releases frame',
      (tester) async {
    final checked = Completer<InstallationResetOutcome>();
    await tester.pumpWidget(CupertinoApp(
      home: InstallationStartupGate(
        reconcile: () => checked.future,
        start: () async => const Text('must-not-publish'),
      ),
    ));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
    checked.complete(InstallationResetOutcome.notNeeded);
    await tester.pump();
    expect(tester.binding.sendFramesToEngine, isTrue);
    expect(find.text('must-not-publish'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pre-app preferences share the same total shell budget',
      (tester) async {
    final preferences = Completer<void>();
    final checked = Completer<InstallationResetOutcome>();
    var checks = 0;
    await tester.pumpWidget(InstallationStartupGate(
      shellBuilder: (child) => CupertinoApp(home: child),
      prepare: () => preferences.future,
      reconcile: () {
        checks++;
        return checked.future;
      },
      start: () async => const Text('account-content'),
    ));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('正在读取本地设置，请稍候'), findsOneWidget);
    expect(checks, 0);
    expect(find.text('account-content'), findsNothing);
    preferences.complete();
    await tester.pump();
    expect(find.text('正在检查本地安装状态，请稍候'), findsOneWidget);
    expect(checks, 1);
    expect(tester.binding.sendFramesToEngine, isTrue);
    checked.complete(InstallationResetOutcome.notNeeded);
    await tester.pumpAndSettle();
    expect(find.text('account-content'), findsOneWidget);
  });

  testWidgets('failed preparation retries once and never opens account early',
      (tester) async {
    var preparations = 0;
    var checks = 0;
    await tester.pumpWidget(CupertinoApp(
      home: InstallationStartupGate(
        prepare: () async {
          preparations++;
          if (preparations == 1) throw StateError('private-setting');
        },
        reconcile: () async {
          checks++;
          return InstallationResetOutcome.notNeeded;
        },
        start: () async => const Text('account-content'),
      ),
    ));
    await tester.pump();
    expect(checks, 0);
    expect(find.textContaining('private-setting'), findsNothing);
    await tester.tap(find.byKey(const Key('installation-startup-retry')));
    await tester.tap(find.byKey(const Key('installation-startup-retry')));
    await tester.pumpAndSettle();
    expect(preparations, 2);
    expect(checks, 1);
    expect(find.text('account-content'), findsOneWidget);
  });

  testWidgets('completed preparation is retained after a reconciliation retry',
      (tester) async {
    var preparations = 0;
    var checks = 0;
    await tester.pumpWidget(CupertinoApp(
      home: InstallationStartupGate(
        prepare: () async {
          preparations++;
        },
        reconcile: () async => ++checks == 1
            ? InstallationResetOutcome.failed
            : InstallationResetOutcome.notNeeded,
        start: () async => const Text('account-content'),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('installation-startup-retry')));
    await tester.pumpAndSettle();
    expect(preparations, 1);
    expect(checks, 2);
  });

  testWidgets('local startup has no intermediate checking page',
      (tester) async {
    final checked = Completer<InstallationResetOutcome>();
    final loaded = Completer<Widget>();
    var starts = 0;
    await tester.pumpWidget(CupertinoApp(
      home: InstallationStartupGate(
        reconcile: () => checked.future,
        start: () {
          starts++;
          return loaded.future;
        },
      ),
    ));
    expect(find.textContaining('正在检查启动状态'), findsNothing);
    expect(find.byIcon(CupertinoIcons.shield), findsNothing);
    expect(starts, 0);
    checked.complete(InstallationResetOutcome.notNeeded);
    await tester.pump();
    expect(starts, 1);
    expect(find.textContaining('正在检查启动状态'), findsNothing);
    loaded.complete(const Text('cached-messages'));
    await tester.pumpAndSettle();
    expect(find.text('cached-messages'), findsOneWidget);
  });

  testWidgets('initialization failure can retry after returning unlocked',
      (tester) async {
    var starts = 0;
    await tester.pumpWidget(CupertinoApp(
        home: InstallationStartupGate(
      reconcile: () async => InstallationResetOutcome.notNeeded,
      start: () async {
        starts++;
        if (starts == 1) throw const FileSystemException('private-path');
        return const Text('restored-after-unlock');
      },
    )));
    await tester.pump();
    expect(find.byKey(const Key('installation-startup-retry')), findsOneWidget);
    expect(find.textContaining('private-path'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('restored-after-unlock'), findsOneWidget);
    expect(starts, 2);
  });

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
