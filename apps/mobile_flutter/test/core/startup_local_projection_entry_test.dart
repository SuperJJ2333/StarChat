import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:liuhetong_mobile/features/push/native_message_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:olm/olm.dart' as olm;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/main.dart' as app;
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/session_gate.dart';
import 'package:liuhetong_mobile/core/app_config.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/installation_reconciler.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';

class _MemorySecure implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _HeldDatabase extends MatrixSdkDatabase {
  _HeldDatabase(super.name, {super.database, super.sqfliteFactory});
  final entered = Completer<void>();
  final release = Completer<void>();
  bool fullRead = false;
  final previewSettled = Completer<void>();
  @override
  Future<void> refreshRoomListPreviews(List<Room> rooms, Client client,
      {bool Function()? isCurrent}) async {
    try {
      await super.refreshRoomListPreviews(rooms, client, isCurrent: isCurrent);
    } finally {
      if (!previewSettled.isCompleted) previewSettled.complete();
    }
  }

  @override
  Future<Map<String, DeviceKeysList>> getUserDeviceKeys(Client client) async {
    entered.complete();
    await release.future;
    return super.getUserDeviceKeys(client);
  }

  @override
  Future<List<Room>> getCachedRoomList(Client client) {
    fullRead = true;
    return super.getCachedRoomList(client);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerStartupProjectionEntryTests();
}

void registerStartupProjectionEntryTests(
    {void Function(Map<String, Object>)? report}) {
  final channels = <String>{};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(() async {
    NativeMessagePolicy.shared;
    await Future<void>.delayed(Duration.zero);
  });
  setUp(() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'native_call',
      'chatflow/call',
      'chatflow/native_messages',
      'FlutterWebRTC.Event',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers',
      'dev.fluttercommunity.plus/connectivity_status',
      'dev.fluttercommunity.plus/connectivity'
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
          if (call.method == 'bind') return {'scope': 'a' * 64, 'revision': 1};
          if (call.method == 'takeTap') return null;
          return true;
        }
        if (name == 'dev.fluttercommunity.plus/connectivity') return ['wifi'];
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
  for (final allHidden in [false, true]) {
    testWidgets(
        'actual main cached rows and room interact while SDK recovery stays held; hidden=$allHidden',
        (tester) async {
      final oldPaths = PathProviderPlatform.instance;
      late Directory directory;
      late SecureSessionStore store;
      late DatabaseFactory sqlFactory;
      late String cipher;
      late SqliteOutboxStore outbox;
      final host = Uri.parse(AppConfig.matrixHomeserver);
      const user = '@startup:synthetic.test';
      final clock = Stopwatch()..start();
      await tester.runAsync(() async {
        await olm.init();
        final evidence = Platform.isAndroid
            ? Directory.systemTemp
            : Directory(
                '../../docs/verification/artifacts/2026-10-17/startup-local-projection/fixtures');
        await evidence.create(recursive: true);
        directory = (await evidence.createTemp('entry-')).absolute;
        PathProviderPlatform.instance = _Paths(directory.path);
        SharedPreferences.setMockInitialValues({});
        store = SecureSessionStore(_MemorySecure());
        cipher = await store.matrixDatabaseKey();
        await store.saveSession(
            accessToken: 'synthetic-token',
            refreshToken: 'synthetic-refresh',
            matrixUserId: user);
        sqlFactory =
            createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
        final path =
            '${directory.path}/${MatrixClientFactory.databaseFileName}';
        final sql = await sqlFactory.openDatabase(path,
            options: OpenDatabaseOptions(
                onConfigure: (db) => db.execute("PRAGMA key = '$cipher'")));
        final db = MatrixSdkDatabase(MatrixClientFactory.clientName,
            database: sql, sqfliteFactory: sqlFactory);
        await db.open();
        final account = olm.Account()..create();
        final fingerprint =
            (jsonDecode(account.identity_keys()) as Map)['ed25519'] as String;
        await db.insertClient(
            MatrixClientFactory.clientName,
            host.toString(),
            'synthetic-token',
            null,
            null,
            user,
            'SYNTHETIC',
            'fixture',
            null,
            account.pickle(user));
        account.free();
        await store.saveMatrixBinding(MatrixLocalBinding(
            version: 2,
            matrixUserId: user,
            deviceId: 'SYNTHETIC',
            homeserver: host.toString(),
            databaseGeneration: 'synthetic-generation',
            ed25519Fingerprint: fingerprint));
        final seed = Client(MatrixClientFactory.clientName)..setUserId(user);
        for (var i = 0; i < 65; i++) {
          final room = Room(id: '!room-$i:synthetic.test', client: seed);
          room.lastEvent = Event(
              room: room,
              eventId: 'preview-$i',
              type: EventTypes.Message,
              senderId: user,
              originServerTs: DateTime.fromMillisecondsSinceEpoch(10000 + i),
              content: {'msgtype': 'm.text', 'body': 'cached preview $i'});
          await sql.insert(
              'box_rooms', {'k': room.id, 'v': jsonEncode(room.toJson())});
          for (final item in <String, Map<String, Object>>{
            EventTypes.RoomName: {'name': 'Synthetic room $i'},
            EventTypes.Encryption: {'algorithm': 'm.megolm.v1.aes-sha2'},
            EventTypes.RoomPowerLevels: {
              'users': {user: 100},
              'events_default': 0,
              'events': {
                'com.changliao.group.settings': 50,
                'com.changliao.group.announcement': 50
              }
            },
          }.entries) {
            await sql.insert('box_preload_room_states', {
              'k': '${room.id}|${item.key}',
              'v': jsonEncode({
                '': {
                  'event_id': 'state-$i-${item.key}',
                  'type': item.key,
                  'state_key': '',
                  'sender': user,
                  'origin_server_ts': 1,
                  'content': item.value
                }
              })
            });
          }
          if (allHidden) {
            await sql.insert('box_room_account_data', {
              'k': '${room.id}|com.liuhetong.conversation.settings.v2',
              'v': jsonEncode({
                'type': 'com.liuhetong.conversation.settings.v2',
                'content': {'hidden': true, 'hidden_at': '2099-01-01T00:00:00Z'}
              })
            });
          }
          if (i == 64) {
            for (var n = 0; n < 60; n++) {
              await db.storeEventUpdate(
                  EventUpdate(
                      roomID: room.id,
                      type: EventUpdateType.timeline,
                      content: {
                        'event_id': 'cached-$n',
                        'type': EventTypes.Message,
                        'sender': user,
                        'origin_server_ts': 10000 + n,
                        'content': {
                          'msgtype': 'm.text',
                          'body': 'Cached message $n'
                        }
                      }),
                  seed);
            }
          }
        }
        await db.close();
        await seed.dispose();
        outbox = SqliteOutboxStore(
            databasePath: '${directory.path}/synthetic-outbox.sqlite',
            factory: sqlFactory);
      });
      late Client client;
      var opened = false;
      late _HeldDatabase held;
      var transportSends = 0;
      final transportTxids = <String>[];
      MatrixClientFactory matrixFactory(Future<void> resumeBackground) =>
          MatrixClientFactory(
              sessionStore: store,
              homeserver: host,
              supportDirectoryPath: () async => directory.path,
              startupOpener: (
                  {required clientName,
                  required databasePath,
                  required cipher}) async {
                final sql = await sqlFactory.openDatabase(databasePath,
                    options: OpenDatabaseOptions(
                        onConfigure: (db) =>
                            db.execute("PRAGMA key = '$cipher'")));
                held = _HeldDatabase(clientName,
                    database: sql, sqfliteFactory: sqlFactory);
                await held.open();
                client = Client(clientName,
                    databaseBuilder: (_) async => held,
                    preserveStoreOnInvalidToken: true,
                    httpClient: MockClient((request) async {
                      if (request.url.path.contains('/send/')) {
                        transportSends++;
                        transportTxids.add(request.url.pathSegments.last);
                        return http.Response(
                            '{"event_id":"synthetic-ack"}', 200);
                      }
                      if (request.url.path.endsWith('/sync')) {
                        return http.Response(
                            '{"next_batch":"synthetic","rooms":{}}', 200);
                      }
                      if (request.url.path.endsWith('/filter')) {
                        return http.Response('{"filter_id":"synthetic"}', 200);
                      }
                      if (request.url.path.contains('/profile/')) {
                        return http.Response(
                            '{"displayname":"Synthetic member"}', 200);
                      }
                      if (request.url.path.endsWith('/members')) {
                        return http.Response('{"chunk":[]}', 200);
                      }
                      if (request.url.path.endsWith('/keys/query')) {
                        return http.Response('{"device_keys":{}}', 200);
                      }
                      if (request.url.path.endsWith('/keys/upload')) {
                        return http.Response(
                            '{"one_time_key_counts":{"signed_curve25519":50}}',
                            200);
                      }
                      return http.Response('{}', 404);
                    }))
                  ..backgroundSync = false;
                opened = true;
                return MatrixClientFactory.initializeStartupClient(client,
                    resumeBackground: resumeBackground);
              });
      final api = BusinessApiClient(
          baseUri: Uri.parse(AppConfig.businessApiBaseUrl),
          sessionStore: store,
          client: MockClient((_) async => http.Response('{}', 503)));
      Future<void> flush([int count = 30]) async {
        for (var i = 0; i < count; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      try {
        await app.main(
            dependencies: app.StartupDependencies(
                store: store,
                matrixFactory: matrixFactory,
                api: api,
                reconcile: () async => InstallationResetOutcome.notNeeded,
                outboxStoreFactory: () => outbox));
        await flush(80);
        expect(tester.takeException(), isNull,
            reason: "fixture setup must succeed");
        await tester.pump(const Duration(seconds: 4));
        expect(find.byType(AppHome), findsOneWidget,
            reason: tester.allWidgets
                .whereType<Text>()
                .map((w) => w.data)
                .join(' | '));
        expect(find.text('正在打开本地聊天'), findsNothing);
        expect(held.release.isCompleted, isFalse);
        expect(held.fullRead, isFalse);
        expect(client.rooms, hasLength(40));
        if (allHidden) {
          expect(find.text('Synthetic room 64'), findsNothing);
          expect(held.entered.isCompleted, isTrue,
              reason: 'empty visible snapshot must release frame barrier');
          held.release.complete();
          await flush(100);
          expect(held.fullRead, isTrue);
          return;
        }
        expect(find.text('Synthetic room 64'), findsOneWidget);
        final contentReadyMs = clock.elapsedMilliseconds;
        await tester.tap(find.text('通讯录').last);
        await flush();
        expect(held.release.isCompleted, isFalse);
        await tester.tap(find.text('消息').last);
        await flush();
        await tester.tap(find.text('Synthetic room 64'));
        await flush(80);
        expect(find.byType(RoomPage), findsOneWidget);
        expect(find.text('Cached message 59'), findsWidgets);
        expect(held.release.isCompleted, isFalse);
        final roomState = tester.state(find.byType(RoomPage));
        final retainedRoom = client.getRoomById('!room-64:synthetic.test');
        final viewport = find
            .descendant(
                of: find.byType(RoomPage),
                matching: find.byType(CustomScrollView))
            .first;
        final scroll = tester.state<ScrollableState>(find
            .descendant(of: viewport, matching: find.byType(Scrollable))
            .first);
        final beforeOffset = scroll.position.pixels;
        await tester.drag(viewport, const Offset(0, 300));
        await flush(30);
        expect(scroll.position.pixels, isNot(beforeOffset));
        expect(held.release.isCompleted, isFalse);
        await tester.enterText(
            find.byKey(const Key('composer-input')), 'Synthetic pending text');
        await tester.pump();
        await tester.tap(find.byKey(const Key('composer-send')));
        await flush(40);
        final rows = await tester.runAsync(() => outbox.query(accountId: user));
        expect(rows, hasLength(1));
        final txid = rows!.single.txid;
        expect(transportSends, 0);
        expect(held.release.isCompleted, isFalse);
        final viewportBounds = tester.getRect(viewport);
        final visibleMessages = find
            .descendant(of: viewport, matching: find.byType(Text))
            .evaluate()
            .where((element) =>
                (element.widget as Text).data?.startsWith('Cached message ') ==
                true)
            .where((element) {
          final bounds = tester.getRect(find.byElementPredicate(
              (candidate) => identical(candidate, element)));
          return viewportBounds.contains(bounds.topLeft) &&
              viewportBounds.contains(bounds.bottomRight);
        }).toList();
        expect(visibleMessages, isNotEmpty,
            reason: 'capture an actually visible stable cached bubble');
        final anchorText =
            (visibleMessages[visibleMessages.length ~/ 2].widget as Text).data!;
        final anchor =
            find.descendant(of: viewport, matching: find.text(anchorText));
        final anchorY = tester.getTopLeft(anchor).dy - viewportBounds.top;
        held.release.complete();
        await flush(100);
        expect(anchor, findsOneWidget);
        final restoredViewport = tester.getRect(viewport);
        expect(restoredViewport.overlaps(tester.getRect(anchor)), isTrue);
        expect(tester.getTopLeft(anchor).dy - restoredViewport.top,
            closeTo(anchorY, 8.0),
            reason:
                'same stable cached message must retain its viewport reading position');
        expect(tester.state(find.byType(RoomPage)), same(roomState));
        expect(
            client.getRoomById('!room-64:synthetic.test'), same(retainedRoom));
        expect(transportTxids, [txid],
            reason: 'transport retains durable transaction identity');
        final afterRows =
            await tester.runAsync(() => outbox.query(accountId: user));
        expect(afterRows!.where((row) => row.txid != txid), isEmpty);
        expect(transportSends, 1,
            reason: 'same queued transaction dispatches once after recovery');
        report?.call({
          'scenario': 'actual-main-held-sdk',
          'content_ready_ms': contentReadyMs,
          'interactive_ms': clock.elapsedMilliseconds,
          'projected_rooms': 40,
          'network_sends_while_held': 0,
          'network_sends_after_recovery': transportSends
        });
      } finally {
        if (opened) {
          if (find.byType(RoomPage).evaluate().isNotEmpty) {
            Navigator.of(tester.element(find.byType(RoomPage)),
                    rootNavigator: true)
                .pop();
            await flush(50);
          }
          if (!held.release.isCompleted) held.release.complete();
          await flush(50);
          await tester.runAsync(() => client.initializationCompleted
              .timeout(const Duration(seconds: 3)));
          for (var i = 0; i < 200 && !held.previewSettled.isCompleted; i++) {
            await flush(1);
          }
          expect(held.previewSettled.isCompleted, isTrue);
          final session = tester
              .widget<SessionGate>(
                  find.byType(SessionGate, skipOffstage: false))
              .controller;
          await tester.pumpWidget(const SizedBox.shrink());
          session.dispose();
          await flush(5);
          var closed = false;
          final closing = client
              .dispose()
              .then((_) => outbox.close())
              .then((_) => closed = true);
          await flush(80);
          expect(closed, isTrue,
              reason: 'all SDK/outbox resources must settle');
          await closing;
          await tester.pump(const Duration(seconds: 16));
        }
        PersistentOutboxManager.shared?.dispose();
        PersistentOutboxManager.shared = null;
        PathProviderPlatform.instance = oldPaths;
      }
    });
  }
}
