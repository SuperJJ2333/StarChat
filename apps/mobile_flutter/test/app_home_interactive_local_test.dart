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
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_watchdog.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';
import 'package:liuhetong_mobile/features/push/native_message_policy.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_room_sender_registry.dart';
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

final class _CachedRoom extends SnapshotRoom {
  _CachedRoom(Client client, int index)
      : label = 'Cached row $index',
        super(id: '!handoff-$index:test', client: client, joined: true);
  String label;
  Completer<Timeline>? timelineHold;
  @override
  String get name => label;
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      timelineHold == null ? _HomeTimeline() : await timelineHold!.future;
}

final class _HomeTimeline extends Fake implements Timeline {
  int cancelCount = 0;
  @override
  List<Event> get events => const [];
  @override
  bool get isFragmentedTimeline => false;
  @override
  bool get canRequestHistory => false;
  @override
  bool get canRequestFuture => false;
  @override
  void cancelSubscriptions() {
    cancelCount++;
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

  testWidgets('local shell navigates tabs without starting live business work',
      (tester) async {
    final client = SnapshotClient()..loggedIn = true;
    client.snapshotRooms.add(_CachedRoom(client, 0));
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.test'),
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: true,
                userId: active.userID,
                deviceId: 'SYNTHETIC',
                ed25519Fingerprint: 'synthetic-fingerprint',
                databaseGeneration: 'synthetic-generation'));
    final requests = <String>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.test'),
        sessionStore: SecureSessionStore(MemorySecureKeyValueStore()),
        client: MockClient((request) async {
          requests.add(request.url.path);
          return http.Response('{}', 503);
        }));
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
        outboxStoreFactory: InMemoryOutboxStore.new,
        syncWatchdogFactory: (_) => MatrixSyncWatchdog(target: _Target()),
      ),
    )));
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    expect(find.textContaining('Cached row 0'), findsOneWidget);
    final home = tester.state(find.byType(AppHome));
    await tester.tap(find.text('通讯录').last);
    await tester.pump();
    expect(find.byKey(const Key('local-contacts')), findsOneWidget);
    await tester.tap(find.text('发现').last);
    await tester.pump();
    expect(find.byKey(const Key('local-discovery')), findsOneWidget);
    await tester.tap(find.text('我').last);
    await tester.pump();
    expect(find.byKey(const Key('local-profile')), findsOneWidget);
    expect(find.text('钱包'), findsNothing);
    expect(requests, isEmpty);
    expect(tester.state(find.byType(AppHome)), same(home));
    await tester.tap(find.text('消息').last);
    await tester.pump();
    final heldRoom = client.snapshotRooms.single as _CachedRoom;
    heldRoom.timelineHold = Completer<Timeline>();
    await tester.tap(find.text('Cached row 0'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(RoomPage), findsOneWidget);
    expect((tester.state(find.byType(RoomPage)) as dynamic).controller, isNull);
    expect(find.text('正在读取本机消息…'), findsNothing);
    expect(find.text('暂无消息'), findsNothing,
        reason: 'unread history must not masquerade as an empty conversation');
    expect(heldRoom.timelineHold!.isCompleted, isFalse);
    await tester.enterText(
        find.byKey(const Key('composer-input')), 'draft while held');
    await tester.pump();
    final disabledSend = tester.widget<CupertinoButton>(find.descendant(
        of: find.byKey(const Key('composer-send')),
        matching: find.byType(CupertinoButton)));
    expect(disabledSend.onPressed, isNull);
    final heldState = tester.state(find.byType(RoomPage)) as dynamic;
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect((await PersistentOutboxManager.shared!.unsent()), isEmpty);
    expect(heldState.input.text, 'draft while held');
    await tester.enterText(find.byKey(const Key('composer-input')), '');
    heldRoom.timelineHold!.complete(_HomeTimeline());
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
        (tester.state(find.byType(RoomPage)) as dynamic).controller, isNotNull);
    expect(find.byKey(const Key('local-text-composer')), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('composer-input')), 'durable pending text');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    final rows = await PersistentOutboxManager.shared!.unsent();
    expect(rows.map((row) => row.content), contains('durable pending text'));
    expect(requests, isEmpty,
        reason: 'cached room and pending send remain local');
    final roomState = tester.state(find.byType(RoomPage));
    final roomRoute = ModalRoute.of(tester.element(find.byType(RoomPage)));
    final txid = rows.single.txid;
    (client.snapshotRooms.single as _CachedRoom).refresh.complete(const []);
    localMode.value = false;
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    expect(tester.state(find.byType(RoomPage)), same(roomState));
    expect(
        ModalRoute.of(tester.element(find.byType(RoomPage))), same(roomRoute));
    expect(tester.state(find.byType(AppHome, skipOffstage: false)), same(home));
    expect((await PersistentOutboxManager.shared!.unsent()).single.txid, txid);
    expect(tester.takeException(), isNull,
        reason: 'upgrade may rebuild a Navigator sibling');

    Navigator.of(tester.element(find.byType(RoomPage)), rootNavigator: true)
        .pop();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 12; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pump(const Duration(seconds: 16));
    await client.dispose();
    theme.dispose();
  });

  for (final boundary in ['back', 'reentry', 'account', 'epoch', 'error']) {
    testWidgets('early room owns delayed preparation exactly: $boundary',
        (tester) async {
      final client = SnapshotClient()..loggedIn = true;
      final room = _CachedRoom(client, 0)..timelineHold = Completer<Timeline>();
      client.snapshotRooms.add(room);
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
      Future<void> frames([int count = 15]) async {
        for (var i = 0; i < count; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      final baselineSenders = OutboxRoomSenderRegistry.shared.length;
      await tester.pumpWidget(CupertinoApp(
          home: AppHome(
              localOnly: true,
              api: api,
              matrix: matrix,
              onLogout: () async {},
              themeController: theme,
              profileRepositoryFactory: (_, __) async => profile,
              outboxStoreFactory: InMemoryOutboxStore.new,
              syncWatchdogFactory: (_) =>
                  MatrixSyncWatchdog(target: _Target()))));
      await frames();
      await tester.tap(find.text('Cached row 0'));
      await frames();
      final oldState = tester.state(find.byType(RoomPage)) as dynamic;
      expect(oldState.controller, isNull);
      expect(OutboxRoomSenderRegistry.shared.length, baselineSenders);
      final oldHold = room.timelineHold!;
      final oldTimeline = _HomeTimeline();
      if (boundary == 'back' || boundary == 'reentry') {
        Navigator.of(tester.element(find.byType(RoomPage)), rootNavigator: true)
            .pop();
        await frames();
        expect(find.byType(RoomPage), findsNothing);
      }
      dynamic newState;
      if (boundary == 'reentry') {
        room.timelineHold = Completer<Timeline>();
        await tester.tap(find.text('Cached row 0'));
        await frames();
        newState = tester.state(find.byType(RoomPage));
        expect(newState, isNot(same(oldState)));
      }
      if (boundary == 'account') client.matrixUserId = '@other:synthetic.test';
      if (boundary == 'epoch') await api.clearLocalSession();
      if (boundary == 'error') {
        oldHold.completeError(StateError('synthetic delayed timeline failure'));
        await frames();
        expect(find.text('本机消息暂时无法读取'), findsOneWidget);
        expect(tester.state(find.byType(RoomPage)), same(oldState));
        room.timelineHold = Completer<Timeline>();
        await tester.tap(find.text('重试读取'));
        await frames();
        room.timelineHold!.complete(oldTimeline);
        await frames();
        expect(oldState.controller, isNotNull);
        expect(OutboxRoomSenderRegistry.shared.length, baselineSenders + 1);
      } else {
        oldHold.complete(oldTimeline);
        await frames();
        expect(oldTimeline.cancelCount, 1);
        expect(OutboxRoomSenderRegistry.shared.length, baselineSenders);
        if (boundary == 'account' || boundary == 'epoch') {
          expect(oldState.controller, isNull);
        }
        if (boundary == 'reentry') {
          expect(tester.state(find.byType(RoomPage)), same(newState));
          expect(newState.controller, isNull);
          room.timelineHold!.complete(_HomeTimeline());
          await frames();
          expect(newState.controller, isNotNull);
          expect(OutboxRoomSenderRegistry.shared.length, baselineSenders + 1);
        }
      }
      await tester.pumpWidget(const SizedBox());
      await frames();
      await tester.pump(const Duration(seconds: 16));
      await client.dispose();
      theme.dispose();
      expect(OutboxRoomSenderRegistry.shared.length, baselineSenders);
      expect(tester.takeException(), isNull);
    });
  }
}
