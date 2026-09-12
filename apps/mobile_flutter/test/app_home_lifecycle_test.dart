import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/app_connection_status.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_recovery_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_watchdog.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_page.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _ThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}

final class _ProfileStore implements ProfileStore {
  @override
  Future<ProfileSnapshot?> read(String key) async => null;
  @override
  Future<void> write(String key, ProfileSnapshot value) async {}
}

final class _EmptyTimeline extends Fake implements Timeline {
  @override
  List<Event> get events => const [];
  @override
  bool get canRequestHistory => false;
  @override
  void cancelSubscriptions() {}
  @override
  Future<Event?> getEventById(String eventId) async => null;
}

final class _GroupRoom extends Room {
  _GroupRoom(Client client) : super(id: '!group:test', client: client);
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      _EmptyTimeline();
  @override
  Membership get membership => Membership.join;
}

final class _WatchdogTarget implements SyncWatchdogTarget {
  final _statuses = StreamController<SyncStatusUpdate>.broadcast();
  var oneShots = 0;
  @override
  Stream<SyncStatusUpdate> get syncStatus => _statuses.stream;
  @override
  Future<void> oneShotSync() async => oneShots++;
  @override
  Future<void> abortSync() async {}
  @override
  set backgroundSync(bool _) {}
}

final class _OnlineTransport implements MatrixTransportMonitor {
  @override
  Future<Set<MatrixTransport>> check() async => {MatrixTransport.wifi};
  @override
  Stream<Set<MatrixTransport>> get changes => const Stream.empty();
}

void main() {
  test('suspend drains delayed initialization before next session handler',
      () async {
    final scope = AppHomeStartupScope();
    final release = Completer<void>();
    final started = Completer<void>();
    final writes = <String>[];
    scope.open();
    final first = scope.run((generation) async {
      started.complete();
      await release.future;
      if (!scope.isCurrent(generation)) return;
      writes.add('old handler');
    });
    await started.future;
    var closed = false;
    final closing = scope.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(scope.open, throwsStateError);
    release.complete();
    await first;
    await closing;
    scope.open();
    await scope.run((generation) async {
      if (scope.isCurrent(generation)) writes.add('new handler');
    });
    expect(writes, ['new handler']);
    await scope.close();
  });

  testWidgets('immediate AppHome removal cancels late Matrix resource setup',
      (tester) async {
    final matrix = MatrixSdkE2eeClient(
      Client('app-home'),
      homeserver: Uri.parse('https://matrix.test'),
    );
    final blockerStarted = Completer<void>();
    final allowBlocker = Completer<void>();
    final blockerRegistration = matrix.registerVerificationLifecycle(
      open: () async {
        blockerStarted.complete();
        await allowBlocker.future;
      },
      close: () async {},
      revoke: () {},
    );
    await blockerStarted.future;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(CupertinoApp(
      home: AppHome(
        api: api,
        matrix: matrix,
        onLogout: () async {},
        themeController: ThemeController(store: _ThemeStore()),
      ),
    ));
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    allowBlocker.complete();
    final blocker = await blockerRegistration;
    await blocker.cancel();
    await tester.pump();

    expect(matrix.debugManagedResourceCount, 0);
  });

  testWidgets('watchdog starts while notification bootstrap is not ready',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final matrix = MatrixSdkE2eeClient(
      Client('app-home-notification-failure'),
      homeserver: Uri.parse('https://matrix.test'),
    );
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
    );
    final target = _WatchdogTarget();
    late MatrixSyncWatchdog watchdog;

    await tester.pumpWidget(CupertinoApp(
      home: AppHome(
        api: api,
        matrix: matrix,
        onLogout: () async {},
        themeController: ThemeController(store: _ThemeStore()),
        syncWatchdogFactory: (_) => watchdog = MatrixSyncWatchdog(
          target: target,
          transport: _OnlineTransport(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(matrix.debugManagedResourceCount, 1,
        reason: 'watchdog assembly is part of Matrix resource setup and must '
            'not wait for notification bootstrap success');
    expect(target.oneShots, 1,
        reason: 'notification readiness must not block sync recovery');
    watchdog.dispose();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('AppHome publishes watchdog state and unbinds it on disposal',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final matrix = MatrixSdkE2eeClient(
      Client('app-home-connection-status'),
      homeserver: Uri.parse('https://matrix.test'),
    );
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
    );
    final target = _WatchdogTarget();

    await tester.pumpWidget(CupertinoApp(
      home: AppHome(
        api: api,
        matrix: matrix,
        onLogout: () async {},
        themeController: ThemeController(store: _ThemeStore()),
        syncWatchdogFactory: (_) => MatrixSyncWatchdog(target: target),
      ),
    ));
    await tester.pump();
    target._statuses.add(SyncStatusUpdate(SyncStatus.finished));
    await tester.pump();

    expect(AppConnectionStatusHub.shared.status.value,
        AppConnectionStatus.connected);

    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(AppConnectionStatusHub.shared.status.value,
        AppConnectionStatus.unknown);
    await target._statuses.close();
  });

  testWidgets('group entry reaches GroupChatPage while profile preload is held',
      (tester) async {
    final client = Client('app-home-group');
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.test'));
    client.rooms.add(_GroupRoom(client));
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.test'),
        sessionStore: SecureSessionStore());
    final heldProfile = Completer<ProfileData>();
    final cache = ProfileRepository.forTesting(
        accountKey: 'group',
        store: _ProfileStore(),
        loadProfile: () => heldProfile.future,
        loadContacts: () async => []);
    addTearDown(cache.dispose);
    await tester.pumpWidget(CupertinoApp(
        home: AppHome(
            api: api,
            matrix: matrix,
            onLogout: () async {},
            themeController: ThemeController(store: _ThemeStore()),
            profileRepositoryFactory: (_, __) async => cache)));
    await tester.pump();
    final home = tester.widget<MatrixHomePage>(find.byType(MatrixHomePage));
    home.onCreateGroup();
    await tester.pump();
    await tester.pump();
    expect(find.byType(GroupChatPage), findsOneWidget);
    tester
        .widget<GroupChatPage>(find.byType(GroupChatPage))
        .onCreated('!group:test');
    await tester.pump();
    await tester.pump();
    expect(find.byType(RoomPage), findsOneWidget);
    expect(heldProfile.isCompleted, isFalse);
    heldProfile.complete(const ProfileData(
        username: 'owner',
        nickname: 'Owner',
        maskedEmail: '',
        fallbackSeed: 'owner'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
