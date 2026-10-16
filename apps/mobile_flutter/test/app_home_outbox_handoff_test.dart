import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_watchdog.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_room_sender_registry.dart';
import 'package:liuhetong_mobile/core/network_state_manager.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';
import 'package:liuhetong_mobile/features/push/native_message_policy.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

final class _HeldFirstQueryStore implements OutboxStore {
  final inner = InMemoryOutboxStore();
  final release = Completer<void>();
  bool queried = false;
  @override
  Future<List<OutboxMessage>> query(
      {Set<OutboxStatus>? statuses,
      bool unsent = false,
      String? roomId,
      String? receiverId,
      String? accountId,
      int? limit}) async {
    if (!queried) {
      queried = true;
      await release.future;
    }
    return inner.query(
        statuses: statuses,
        unsent: unsent,
        roomId: roomId,
        receiverId: receiverId,
        accountId: accountId,
        limit: limit);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final target = switch (invocation.memberName) {
      #insert => inner.insert,
      #byLocalId => inner.byLocalId,
      #byTxid => inner.byTxid,
      #updateStatus => inner.updateStatus,
      #delete => inner.delete,
      #deleteSent => inner.deleteSent,
      #bindRoom => inner.bindRoom,
      #bindRoomForReceiver => inner.bindRoomForReceiver,
      #clear => inner.clear,
      #close => inner.close,
      _ => null,
    };
    if (target != null) {
      return Function.apply(
          target, invocation.positionalArguments, invocation.namedArguments);
    }
    return super.noSuchMethod(invocation);
  }
}

final class _RaceRoom extends SnapshotRoom {
  _RaceRoom(Client client)
      : super(id: '!handoff:test', client: client, joined: true);
  @override
  bool get encrypted => true;
  @override
  bool get canSendDefaultMessages => true;
}

final class _Sender implements OutboxSender {
  _Sender(this.store);
  final OutboxStore store;
  final sent = <String>[];
  @override
  String get roomId => '!handoff:test';
  @override
  bool get canSend => true;
  @override
  Future<String> send(OutboxMessage row) async {
    final owner = PersistentOutboxManager.shared!;
    expect(owner.store, same(store));
    if (!await owner.claim(row.localId)) return '';
    sent.add(row.txid);
    await owner.removeOrArchive(row.localId);
    return r'$synthetic-ack';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <String>{};
  setUpAll(() async {
    // Initialize the process singleton outside per-test FakeAsync zones. Its
    // initial serialized-write future must remain usable across widget tests.
    NativeMessagePolicy.shared;
    await Future<void>.delayed(Duration.zero);
  });
  setUp(() {
    ConversationReadState.shared().resetForTest();
    MaintenanceActivity.instance.resetForTesting();
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
    ConversationReadState.shared().resetForTest();
    MaintenanceActivity.instance.resetForTesting();
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    channels.clear();
  });

  testWidgets(
      'unfinished local open retains one owner at verified scheduler binding',
      (tester) async {
    for (final boundary in [
      'authorized',
      'epoch',
      'account',
      'failure',
      'disposed'
    ]) {
      final store = _HeldFirstQueryStore();
      final now = DateTime.utc(2026, 10, 16);
      await store.inner.insert(OutboxMessage(
          localId: 'local-original',
          txid: 'tx-original',
          receiverId: '!handoff:test',
          roomId: '!handoff:test',
          accountId: '@me:test',
          content: 'durable pending text',
          createdAt: now,
          updatedAt: now));
      final sender = _Sender(store);
      OutboxRoomSenderRegistry.shared.register(sender);
      PersistentOutboxManager.shared = null;
      NetworkStateManager.shared = NetworkStateManager();
      final client = SnapshotClient()..loggedIn = true;
      client.snapshotRooms.add(_RaceRoom(client));
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
      final theme = ThemeController(store: _ThemeStore());
      final localMode = ValueNotifier(true);
      await tester.pumpWidget(CupertinoApp(
          home: ValueListenableBuilder<bool>(
              valueListenable: localMode,
              builder: (_, local, __) => AppHome(
                    localOnly: local,
                    api: api,
                    matrix: matrix,
                    onLogout: () async {},
                    themeController: theme,
                    profileRepositoryFactory: (_, __) async => profile,
                    outboxStoreFactory: () => store,
                    syncWatchdogFactory: (_) =>
                        MatrixSyncWatchdog(target: _Target()),
                  ))));
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(store.queried, isTrue);
      expect(PersistentOutboxManager.shared, isNull);
      localMode.value = false;
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
      final dynamic home = tester.state(find.byType(AppHome));
      expect(home.matrixResources, isNotNull,
          reason: 'verified resources attached before local open completed');
      expect(PersistentOutboxManager.shared, isNull,
          reason:
              'scheduler binding must await and reuse the unfinished local owner');
      expect(sender.sent, isEmpty);
      if (boundary == 'epoch') await api.clearLocalSession();
      if (boundary == 'account') client.matrixUserId = '@other:test';
      if (boundary == 'disposed') await tester.pumpWidget(const SizedBox());
      if (boundary == 'failure') {
        store.release
            .completeError(StateError('synthetic storage unavailable'));
      } else {
        store.release.complete();
      }
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
      if (boundary == 'authorized') {
        expect(PersistentOutboxManager.shared!.store, same(store));
        NetworkStateManager.shared!.reportSuccess();
        for (var i = 0; i < 20; i++) {
          await tester.pump();
        }
        expect(sender.sent, ['tx-original']);
        expect(await store.inner.query(unsent: true), isEmpty);
        NetworkStateManager.shared!.reportSuccess();
        for (var i = 0; i < 8; i++) {
          await tester.pump();
        }
        expect(sender.sent, ['tx-original'],
            reason: 'recovery keeps the original txid and dispatches once');
      } else {
        expect(PersistentOutboxManager.shared, isNull,
            reason: '$boundary completion cannot publish another queue');
        NetworkStateManager.shared!.reportSuccess();
        for (var i = 0; i < 8; i++) {
          await tester.pump();
        }
        expect(sender.sent, isEmpty, reason: '$boundary must remain closed');
        expect((await store.inner.query(unsent: true)).single.status,
            OutboxStatus.queued);
      }
      OutboxRoomSenderRegistry.shared.unregister(sender);
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      await client.dispose();
      await tester.pump(const Duration(milliseconds: 100));
      theme.dispose();
      NetworkStateManager.shared?.dispose();
      NetworkStateManager.shared = null;
    }
  });
}
