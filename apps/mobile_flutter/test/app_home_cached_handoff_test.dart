import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_watchdog.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/session_gate.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/session_bootstrap_controller_test.dart'
    show FakeBusiness, FakeMatrix;
import 'core/session_store_test.dart' show MemorySecureKeyValueStore;
import 'features/matrix/matrix_client_factory_test.dart'
    show SnapshotClient, SnapshotRoom;

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

final class _Target implements SyncWatchdogTarget {
  @override
  Stream<SyncStatusUpdate> get syncStatus => const Stream.empty();
  @override
  Future<void> oneShotSync() async {}
  @override
  Future<void> abortSync() async {}
  @override
  set backgroundSync(bool value) {}
}

final class _CachedRoom extends SnapshotRoom {
  _CachedRoom(Client client, int index)
      : label = 'Cached row $index',
        super(id: '!handoff-$index:test', client: client, joined: true);
  String label;
  @override
  String get name => label;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <String>{};
  setUp(() {
    SharedPreferences.setMockInitialValues(
        {'keepalive.battery_prompted_v1': true});
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'native_call',
      'chatflow/call',
      'chatflow/native_messages',
      'FlutterWebRTC.Event',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers'
    ]) {
      channels.add(name);
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        if (name == 'xyz.luan/audioplayers' && call.method == 'create') {
          final event =
              'xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}';
          channels.add(event);
          messenger.setMockMethodCallHandler(
              MethodChannel(event), (_) async => null);
        }
        if (name == 'dexterous.com/flutter/local_notifications') {
          if (call.method == 'getNotificationAppLaunchDetails') {
            return {'notificationLaunchedApp': false};
          }
          return true;
        }
        if (name == 'chatflow/native_messages') {
          if (call.method == 'bind') {
            return {'scope': 'a' * 64, 'revision': 1};
          }
          if (call.method == 'takeTap') return null;
          return true;
        }
        return null;
      });
    }
  });
  tearDown(() {
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    channels.clear();
  });

  for (final boundary in ['ready', 'revoke', 'account', 'epoch']) {
    testWidgets('cached handoff holds real rows through attachment: $boundary',
        (tester) async {
      final client = SnapshotClient()..loggedIn = true;
      for (var i = 0; i < 60; i++) {
        client.snapshotRooms.add(_CachedRoom(client, i));
      }
      final matrix = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://matrix.test'),
          readContinuityMetadata: (active) async =>
              MatrixClientContinuityMetadata(
                  isLoggedIn: true,
                  userId: active.userID,
                  deviceId: 'SYNTHETIC',
                  ed25519Fingerprint: 'synthetic-fingerprint',
                  databaseGeneration: 'synthetic-generation'));
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://business.test'),
          sessionStore: SecureSessionStore(MemorySecureKeyValueStore()),
          client: MockClient((_) async => http.Response('{}', 503)));
      final profile = ProfileRepository.forTesting(
          accountKey: '@me:test', store: _ProfileStore());
      final heldProfile = Completer<ProfileRepository>();
      final business = FakeBusiness(BusinessSessionRestore.authenticated,
          matrixUserId: '@me:test', restoreGate: Completer<void>());
      final session = SessionBootstrapController(
          business: business,
          matrix: FakeMatrix(isLoggedIn: true, userId: '@me:test'));
      final restoring = session.bootstrap();
      final handoff = MatrixHomeHandoff(
          api: api,
          matrix: matrix,
          eligible: () => session.canShowCachedMessages);
      session.addListener(handoff.invalidateIfUnavailable);
      final theme = ThemeController(store: _ThemeStore());
      await tester.pumpWidget(CupertinoApp(
          home: SessionGate(
        controller: session,
        cachedMessagesBuilder: (_) => MatrixHomePage(
            api: api,
            matrix: matrix,
            themeController: theme,
            onCreateGroup: () {},
            previewOnly: true,
            identityCache: profile,
            startupHandoff: handoff),
        authenticatedBuilder: (_) => AppHome(
            api: api,
            matrix: matrix,
            startupHandoff: handoff,
            themeController: theme,
            onLogout: () async {},
            profileRepositoryFactory: (_, __) => heldProfile.future,
            syncWatchdogFactory: (_) => MatrixSyncWatchdog(target: _Target())),
        unauthenticatedBuilder: (_) => const Text('LOGIN'),
      )));
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(find.textContaining('Cached row 0'), findsOneWidget);

      final attached = Completer<void>();
      final release = Completer<void>();
      final blocker = matrix.registerVerificationLifecycle(
          open: () async {
            attached.complete();
            await release.future;
          },
          close: () async {},
          revoke: () {});
      await tester.pump();
      await attached.future;
      business.restoreGate!.complete();
      await restoring;
      await tester.pump();
      await tester.pump();
      expect(find.byType(AppHome), findsOneWidget);
      expect(release.isCompleted, isFalse);
      expect(find.text('Cached row 0'), findsOneWidget,
          reason:
              'real cached rows must remain while new local reads queue behind attachment');
      final search = find.byKey(const Key('messages-search'));
      expect(tester.widget<CupertinoButton>(search).onPressed, isNull);
      final list = find.byType(ListView).first;
      final scroll = tester.state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first);
      await tester.drag(list, const Offset(0, -350));
      await tester.pump(const Duration(milliseconds: 100));
      expect(scroll.position.pixels, greaterThan(100));

      if (boundary != 'ready') {
        if (boundary == 'revoke') {
          unawaited(session.logout());
        } else if (boundary == 'account') {
          client.matrixUserId = '@replacement:test';
          handoff.invalidateIfUnavailable();
        } else {
          await api.clearLocalSession();
          handoff.invalidateIfUnavailable();
        }
        await tester.pump();
        expect(find.textContaining('Cached row', skipOffstage: false),
            findsNothing);
        expect(handoff.read(api, matrix), isNull);
        if (boundary == 'revoke') expect(find.text('LOGIN'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        release.complete();
        final blockedResource = await blocker;
        await blockedResource.cancel();
        for (var i = 0; i < 8; i++) {
          await tester.pump();
        }
        expect(find.textContaining('Cached row', skipOffstage: false),
            findsNothing);
        expect(matrix.debugManagedResourceCount, 0);
        session.dispose();
        await client.dispose();
        return;
      }

      release.complete();
      final blockerResource = await blocker;
      await blockerResource.cancel();
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(heldProfile.isCompleted, isFalse);
      expect(find.text('Cached row 0'), findsOneWidget);
      expect(tester.widget<CupertinoButton>(search).onPressed, isNotNull);
      (client.snapshotRooms.first as _CachedRoom).label = 'Live updated row';
      client.onRoomListUpdated.add(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Live updated row'), findsOneWidget,
          reason:
              'live initialization must attach the real local update listener');
      expect(handoff.read(api, matrix), isNull,
          reason: 'fresh live snapshot releases the startup reference');
      final dynamic homeState = tester.state(find.byType(AppHome));
      final MatrixManagedResource resource = homeState.matrixResources;
      var closed = false;
      final closing = resource.cancel().then((_) => closed = true);
      for (var i = 0; i < 30 && !closed; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(closed, isTrue);
      await closing;
      await tester.pump();
      expect(find.text('Live updated row'), findsNothing);
      expect(find.byKey(const Key('messages-search')), findsNothing);
      client.onRoomListUpdated.add(null);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Live updated row'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      session.dispose();
      await client.dispose();
    });
  }

  for (final boundary in [
    'eligibility',
    'same-account-epoch',
    'device-owner'
  ]) {
    test('retired handoff cannot be reused or republished after $boundary',
        () async {
      final client = SnapshotClient()..loggedIn = true;
      final matrix = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://matrix.test'));
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://business.test'),
          sessionStore: SecureSessionStore(MemorySecureKeyValueStore()));
      var eligible = true;
      final handoff =
          MatrixHomeHandoff(api: api, matrix: matrix, eligible: () => eligible);
      final snapshot = MatrixConversationSnapshot(
          vaultRoomId: null, reminderRoomId: null, rooms: const []);
      handoff.publish(snapshot);
      expect(identical(handoff.read(api, matrix), snapshot), isTrue);
      if (boundary == 'eligibility') {
        eligible = false;
      } else if (boundary == 'same-account-epoch') {
        await api.clearLocalSession();
        expect(matrix.userId, '@me:test');
      } else {
        client.matrixDeviceId = 'REPLACEMENT-DEVICE';
      }
      handoff.invalidateIfUnavailable();
      expect(handoff.read(api, matrix), isNull);
      eligible = true;
      handoff.publish(snapshot);
      expect(handoff.read(api, matrix), isNull,
          reason: 'late work cannot make a retired startup reference reusable');
      await client.dispose();
    });
  }
}
