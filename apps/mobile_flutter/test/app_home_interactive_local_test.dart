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
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
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

class _ControlledStore extends Fake implements OutboxStore {
  final inner = InMemoryOutboxStore();
  bool failInsert = false;
  Completer<void>? insertHold;
  Completer<void>? readHold;
  bool holdOneRead = false;
  bool captureBeforeReadHold = false;
  final attemptedTxids = <String>[];
  @override
  Future<void> insert(OutboxMessage row) async {
    attemptedTxids.add(row.txid);
    await insertHold?.future;
    if (failInsert) throw StateError('synthetic disk write failure');
    await inner.insert(row);
  }

  @override
  Future<OutboxMessage?> byLocalId(String id) => inner.byLocalId(id);
  @override
  Future<OutboxMessage?> byTxid(String id) async {
    final hold = readHold;
    if (holdOneRead) readHold = null;
    if (captureBeforeReadHold && hold != null) {
      final captured = await inner.byTxid(id);
      await hold.future;
      return captured;
    }
    await hold?.future;
    return inner.byTxid(id);
  }

  @override
  Future<bool> delete(String id) => inner.delete(id);
  @override
  Future<List<OutboxMessage>> query(
          {Set<OutboxStatus>? statuses,
          bool unsent = false,
          String? roomId,
          String? receiverId,
          String? accountId,
          int? limit}) =>
      inner.query(
          statuses: statuses,
          unsent: unsent,
          roomId: roomId,
          receiverId: receiverId,
          accountId: accountId,
          limit: limit);
  @override
  Future<int> deleteSent({String? accountId}) =>
      inner.deleteSent(accountId: accountId);
  @override
  Future<void> close() => inner.close();
  @override
  Future<bool> updateStatus(
    String localId,
    OutboxStatus status, {
    String? lastError,
    int? retryCount,
    int? serverRetryCount,
    DateTime? nextServerRetryAt,
    bool clearNextServerRetryAt = false,
    int? expectedRetryCount,
    String? accountId,
    DateTime? dueAt,
    bool incrementRetry = false,
    DateTime? updatedAt,
    Set<OutboxStatus>? from,
    bool clearLastError = false,
  }) =>
      inner.updateStatus(localId, status,
          lastError: lastError,
          retryCount: retryCount,
          serverRetryCount: serverRetryCount,
          nextServerRetryAt: nextServerRetryAt,
          clearNextServerRetryAt: clearNextServerRetryAt,
          expectedRetryCount: expectedRetryCount,
          accountId: accountId,
          dueAt: dueAt,
          incrementRetry: incrementRetry,
          updatedAt: updatedAt,
          from: from,
          clearLastError: clearLastError);
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

  for (final editWhileWriting in [
    'text',
    'caret',
    'reply',
    'ack',
    'ack-stale',
    'account',
    'epoch',
    'lease'
  ]) {
    testWidgets(
        'local shell queues before history with $editWhileWriting editing',
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
      final store = _ControlledStore();
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
      expect(
          (tester.state(find.byType(RoomPage)) as dynamic).controller, isNull);
      expect(find.text('正在读取本机消息…'), findsNothing);
      expect(find.text('暂无消息'), findsNothing,
          reason:
              'unread history must not masquerade as an empty conversation');
      expect(heldRoom.timelineHold!.isCompleted, isFalse);
      await tester.enterText(
          find.byKey(const Key('composer-input')), 'draft while held');
      await tester.pump();
      final enabledSend = tester.widget<CupertinoButton>(find.descendant(
          of: find.byKey(const Key('composer-send')),
          matching: find.byType(CupertinoButton)));
      expect(enabledSend.onPressed, isNotNull,
          reason: 'durable text admission must not wait for history');
      final heldState = tester.state(find.byType(RoomPage)) as dynamic;
      store.failInsert = true;
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(heldState.input.text, 'draft while held');
      expect(await store.inner.query(), isEmpty);
      expect(find.textContaining('无法保存'), findsOneWidget);
      store.failInsert = false;
      store.insertHold = Completer<void>();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(heldState.input.text, 'draft while held');
      expect(await store.inner.query(), isEmpty);
      // A second submit while the write is held must not allocate another txid.
      await tester.testTextInput.receiveAction(TextInputAction.send);
      final nextReply = RoomMessageViewModel(
          id: 'next-reply',
          senderId: '@peer:test',
          text: 'next reply',
          isOwn: false,
          timestamp: DateTime.utc(2026),
          deliveryState: RoomDeliveryState.sent);
      if (editWhileWriting == 'text') {
        await tester.enterText(
            find.byKey(const Key('composer-input')), 'next draft');
      } else if (editWhileWriting == 'caret') {
        heldState.input.selection = const TextSelection.collapsed(offset: 2);
      } else if (editWhileWriting == 'reply') {
        heldState.replyingTo = nextReply;
      }
      if (editWhileWriting == 'account') {
        client.matrixUserId = '@replacement:test';
      }
      if (editWhileWriting == 'epoch') await api.clearLocalSession();
      if (editWhileWriting == 'lease') {
        unawaited((heldState.widget as RoomPage).roomLease.cancel());
      }
      store.insertHold!.complete();
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      final admitted = (await PersistentOutboxManager.shared!.unsent()).single;
      if (['account', 'epoch', 'lease'].contains(editWhileWriting)) {
        expect(admitted.accountId, '@me:test');
        expect(heldState.input.text, 'draft while held');
        expect(heldState.controller, isNull);
        expect(requests, isEmpty);
        heldRoom.timelineHold!.complete(_HomeTimeline());
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 12; i++) {
          await tester.pump();
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
        await tester.pump(const Duration(seconds: 16));
        await client.dispose();
        theme.dispose();
        return;
      }
      expect(store.attemptedTxids.toSet(), {admitted.txid},
          reason:
              'retrying an uncertain disk write must reuse its transaction');
      expect(admitted.content, 'draft while held');
      expect(
          heldState.input.text, editWhileWriting == 'text' ? 'next draft' : '',
          reason: 'retain new text, but a caret change is not a new draft');
      if (editWhileWriting == 'reply') {
        expect(heldState.replyingTo, same(nextReply));
      }
      expect(find.text('draft while held'), findsOneWidget);
      expect(heldRoom.timelineHold!.isCompleted, isFalse);
      if (editWhileWriting.startsWith('ack')) {
        final manager = PersistentOutboxManager.shared!;
        await manager.updateStatus(
            admitted.localId, OutboxStatus.waitingNetwork);
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }
        expect(
            find.byKey(const Key('message-delivery-waiting')), findsOneWidget);
        final delayedRead = Completer<void>();
        store.readHold = delayedRead;
        if (editWhileWriting == 'ack-stale') {
          store.holdOneRead = true;
          store.captureBeforeReadHold = true;
          await manager.updateStatus(
              admitted.localId, OutboxStatus.waitingNetwork);
        }
        await manager.updateStatus(admitted.localId, OutboxStatus.sent);
        await manager.removeOrArchive(admitted.localId);
        expect(await store.inner.query(), isEmpty);
        // Other rooms can settle a large recovered backlog while this read waits.
        for (var i = 0; i < 513; i++) {
          final other = admitted.copyWith(
              localId: 'other-$i',
              txid: 'other-tx-$i',
              roomId: '!other:test',
              receiverId: '!other:test');
          await store.inner.insert(other);
          await manager.updateStatus(other.localId, OutboxStatus.sent);
          await store.inner.delete(other.localId);
        }
        expect(manager.wasAcknowledged(admitted.localId), isFalse);
        delayedRead.complete();
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }
        expect(find.byKey(const Key('message-delivery-waiting')), findsNothing);
      }
      if (editWhileWriting == 'caret') {
        heldRoom.timelineHold!
            .completeError(StateError('synthetic history failure'));
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }
        expect(find.text('draft while held'), findsOneWidget);
        expect(find.text('重试读取'), findsOneWidget);
        heldRoom.timelineHold = Completer<Timeline>();
        await tester.tap(find.text('重试读取'));
        await tester.pump();
      }
      heldRoom.timelineHold!.complete(_HomeTimeline());
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect((tester.state(find.byType(RoomPage)) as dynamic).controller,
          isNotNull);
      expect(find.textContaining('文字将在本机保存'), findsNothing);
      expect(find.byKey(const Key('composer-input')), findsOneWidget);
      final rows = await PersistentOutboxManager.shared!.unsent();
      if (editWhileWriting.startsWith('ack')) {
        expect(rows, isEmpty);
      } else {
        expect(rows.single.txid, admitted.txid);
      }
      final projected = (tester.state(find.byType(RoomPage)) as dynamic)
          .controller
          .messages
          .single;
      expect(projected.transactionId, admitted.txid);
      expect(projected.isOwn, isTrue);
      if (editWhileWriting == 'text') {
        // The page must register send intent before disk I/O, then leave any
        // later reader navigation alone when persistence completes.
        final timeline = heldState.controller as RoomTimelineController;
        store.insertHold = Completer<void>();
        await tester.tap(find.byKey(const Key('composer-send')));
        await tester.pump();
        final intentDuringWrite = timeline.latestLocalSendIntent;
        expect(intentDuringWrite, isNotNull);
        store.insertHold!.complete();
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }
        expect(timeline.latestLocalSendIntent, intentDuringWrite);
        expect(heldState.input.text, isEmpty);
      }
      expect(requests, isEmpty,
          reason: 'cached room and pending send remain local');
      final roomState = tester.state(find.byType(RoomPage));
      final roomRoute = ModalRoute.of(tester.element(find.byType(RoomPage)));
      final txid = admitted.txid;
      (client.snapshotRooms.single as _CachedRoom).refresh.complete(const []);
      localMode.value = false;
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(tester.state(find.byType(RoomPage)), same(roomState));
      expect(ModalRoute.of(tester.element(find.byType(RoomPage))),
          same(roomRoute));
      expect(
          tester.state(find.byType(AppHome, skipOffstage: false)), same(home));
      final remaining = await PersistentOutboxManager.shared!.unsent();
      if (editWhileWriting.startsWith('ack')) {
        expect(remaining, isEmpty);
      } else {
        expect(remaining.where((r) => r.txid == txid), hasLength(1));
        expect(remaining, hasLength(editWhileWriting == 'text' ? 2 : 1));
      }
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
  }

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
