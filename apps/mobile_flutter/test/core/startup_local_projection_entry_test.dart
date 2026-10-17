import 'package:audioplayers/audioplayers.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection_store.dart';
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
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/features/matrix/room_navigation_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';
import 'package:liuhetong_mobile/ui/chat/group_avatar_mosaic.dart';

class _MemorySecure implements SecureKeyValueStore {
  final values = <String, String>{};
  Completer<void>? diagnosticHold;
  Completer<void>? admissionHold;
  final admissionEntered = Completer<void>();
  @override
  Future<String?> read(String key) async {
    if (admissionHold != null && key == 'liuhetong.matrix_account_slots.v1') {
      if (!admissionEntered.isCompleted) admissionEntered.complete();
      await admissionHold!.future;
    }
    if (key == 'liuhetong.diagnostic_salt.v1') await diagnosticHold?.future;
    return values[key];
  }

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
  Completer<void>? warmRoomRead;
  final warmRoomReadEntered = Completer<void>();
  @override
  Future<List<Event>> getEventList(Room room,
      {int start = 0, bool onlySending = false, int? limit}) async {
    if (warmRoomRead != null && room.id == '!room-64:synthetic.test') {
      if (!warmRoomReadEntered.isCompleted) warmRoomReadEntered.complete();
      await warmRoomRead!.future;
    }
    return super.getEventList(room,
        start: start, onlySending: onlySending, limit: limit);
  }

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

class _PreflightBarrier implements MatrixLocalIdentityReader {
  final release = Completer<void>();
  int originalCalls = 0;
  final delegate = const ReadOnlySqlCipherIdentityReader();
  @override
  Future<bool> exists(String path) async {
    await release.future;
    originalCalls++;
    return delegate.exists(path);
  }

  @override
  Future<MatrixLocalIdentityRecord> read(String path, String cipher) async {
    await release.future;
    originalCalls++;
    return delegate.read(path, cipher);
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
    for (final name in [
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers.global'
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (_) async => null);
    }
    await AudioPlayer.global.ensureInitialized();
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
  for (final scenario in [
    (hidden: false, independent: true, avatarHandoff: false),
    (hidden: false, independent: false, avatarHandoff: false),
    (hidden: true, independent: false, avatarHandoff: false),
    (hidden: true, independent: true, avatarHandoff: false),
    (hidden: false, independent: true, avatarHandoff: true)
  ]) {
    final avatarHandoff = scenario.avatarHandoff;
    final allHidden = scenario.hidden;
    final independent = scenario.independent;
    testWidgets(
        avatarHandoff
            ? 'actual main visible avatar remains painted through canonical handoff'
            : independent
                ? (allHidden
                    ? 'actual main valid empty independent projection releases content frame'
                    : 'actual main independent projection precedes held whole-store preflight')
                : 'actual main cached rows and room interact while SDK recovery stays held; hidden=$allHidden',
        (tester) async {
      final oldPaths = PathProviderPlatform.instance;
      late Directory directory;
      late SecureSessionStore store;
      final rawSecure = _MemorySecure();
      MatrixClientFactory? latestFactory;
      late DatabaseFactory sqlFactory;
      late String cipher;
      late SqliteOutboxStore outbox;
      final host = Uri.parse(AppConfig.matrixHomeserver);
      final user =
          '@startup-${independent ? 'projection' : 'legacy'}-${allHidden ? 'empty' : 'rows'}:synthetic.test';
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
        store = SecureSessionStore(rawSecure);
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
      var encryptedTransport = false;
      final preflight = _PreflightBarrier();
      var priming = false;
      var databaseOpens = 0;

      Client buildClient(
          {required String clientName,
          required String databasePath,
          required String cipher}) {
        final result = Client(clientName,
            databaseBuilder: (_) async {
              databaseOpens++;
              final sql = await sqlFactory.openDatabase(databasePath,
                  options: OpenDatabaseOptions(
                      onConfigure: (db) =>
                          db.execute("PRAGMA key = '$cipher'")));
              held = _HeldDatabase(clientName,
                  database: sql, sqfliteFactory: sqlFactory);
              await held.open();
              if (priming || independent) held.release.complete();
              opened = true;
              return held;
            },
            preserveStoreOnInvalidToken: true,
            httpClient: MockClient((request) async {
              if (request.url.path.contains('/send/')) {
                transportSends++;
                final payload = jsonDecode(request.body) as Map;
                encryptedTransport = request.url.path
                        .contains('/m.room.encrypted/') &&
                    payload['algorithm'] == AlgorithmTypes.megolmV1AesSha2 &&
                    payload['ciphertext'] is String &&
                    !payload.containsKey('body') &&
                    !request.body.contains('Synthetic pending text');
                transportTxids.add(request.url.pathSegments.last);
                return http.Response('{"event_id":"synthetic-ack"}', 200);
              }
              if (request.url.path.endsWith('/sync')) {
                return http.Response(
                    '{"next_batch":"synthetic","rooms":{}}', 200);
              }
              if (request.url.path.endsWith('/filter')) {
                return http.Response('{"filter_id":"synthetic"}', 200);
              }
              if (request.url.path.contains('/profile/')) {
                final member =
                    Uri.decodeComponent(request.url.pathSegments.last);
                if (avatarHandoff && member.startsWith('@avatar-')) {
                  final index = member.startsWith('@avatar-0:') ? 0 : 1;
                  return http.Response(
                      jsonEncode({
                        'displayname': 'Synthetic member $index',
                        'avatar_url': 'mxc://synthetic.test/avatar-$index'
                      }),
                      200);
                }
                return http.Response('{"displayname":"Synthetic member"}', 200);
              }
              if (request.url.path.endsWith('/members')) {
                return http.Response('{"chunk":[]}', 200);
              }
              if (request.url.path.endsWith('/keys/query')) {
                return http.Response('{"device_keys":{}}', 200);
              }
              if (request.url.path.endsWith('/keys/upload')) {
                return http.Response(
                    '{"one_time_key_counts":{"signed_curve25519":50}}', 200);
              }
              return http.Response('{}', 404);
            }))
          ..backgroundSync = false;
        client = result;
        return result;
      }

      MatrixClientFactory matrixFactory(Future<void> resumeBackground) =>
          latestFactory = MatrixClientFactory(
              sessionStore: store,
              homeserver: host,
              supportDirectoryPath: () async => directory.path,
              startupBackgroundResume: independent
                  ? Future.wait([resumeBackground, preflight.release.future])
                  : resumeBackground,
              localIdentityPreflight: independent && !priming
                  ? MatrixLocalIdentityPreflight(reader: preflight)
                  : null,
              startupClientBuilder: buildClient,
              opener: (
                      {required clientName,
                      required databasePath,
                      required cipher}) async =>
                  MatrixClientFactory.initializeClient(buildClient(
                      clientName: clientName,
                      databasePath: databasePath,
                      cipher: cipher)),
              startupOpener: (
                      {required clientName,
                      required databasePath,
                      required cipher}) async =>
                  MatrixClientFactory.initializeStartupClient(
                      buildClient(clientName: clientName, databasePath: databasePath, cipher: cipher),
                      resumeBackground: resumeBackground));
      final api = BusinessApiClient(
          baseUri: Uri.parse(AppConfig.businessApiBaseUrl),
          sessionStore: store,
          client: MockClient((_) async => http.Response('{}', 503)));
      var auditVisibleFrames = false;
      var firstVisibleContent = false;
      var firstRoomContent = false;
      void auditFrame() {
        if (!auditVisibleFrames || !tester.binding.sendFramesToEngine) return;
        for (final text in [
          '正在启动畅聊',
          '正在打开本地聊天，请稍候',
          '正在恢复本机会话…',
          '正在读取本机会话…',
          '正在读取本机消息…'
        ]) {
          expectSync(find.text(text), findsNothing,
              reason:
                  'every visible cache-hit frame must contain ready content');
        }
        if (!firstVisibleContent) {
          expectSync(find.byType(AppHome), findsOneWidget);
          expectSync(databaseOpens, 0);
          expectSync(preflight.originalCalls, 0);
          firstVisibleContent = true;
        }
        if (!firstRoomContent && find.byType(RoomPage).evaluate().isNotEmpty) {
          expectSync(find.text('Cached message 59'), findsWidgets,
              reason:
                  'the first room frame must already contain cached bubbles');
          firstRoomContent = true;
        }
      }

      Future<void> flush([int count = 30]) async {
        for (var i = 0; i < count; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
          auditFrame();
        }
      }

      if (independent) {
        await tester.runAsync(() async {
          priming = true;
          await store.registrationDeviceKey();
          final factory = matrixFactory(Future<void>.value());
          final full = await factory.create();
          if (!allHidden) {
            final room = full.getRoomById('!room-64:synthetic.test')!;
            for (var member = 0; member < 2; member++) {
              room.setState(Event(
                  room: room,
                  eventId: 'avatar-member-$member',
                  type: EventTypes.RoomMember,
                  originServerTs: DateTime.utc(2026, 10, 17),
                  stateKey: '@avatar-$member:synthetic.test',
                  senderId: user,
                  content: {
                    'membership': 'join',
                    'displayname': 'Synthetic member $member',
                    'avatar_url': 'mxc://synthetic.test/avatar-$member'
                  }));
              // The fifth scenario verifies the real canonical member state,
              // not just the independent display projection's member list.
              if (avatarHandoff) {
                await full.database!.storeEventUpdate(
                    EventUpdate(
                        roomID: room.id,
                        type: EventUpdateType.state,
                        content: {
                          'event_id': 'avatar-member-$member',
                          'type': EventTypes.RoomMember,
                          'state_key': '@avatar-$member:synthetic.test',
                          'sender': user,
                          'origin_server_ts': 10000,
                          'content': {
                            'membership': 'join',
                            'displayname': 'Synthetic member $member',
                            'avatar_url': 'mxc://synthetic.test/avatar-$member'
                          }
                        }),
                    full);
              }
            }
            final outbound = olm.OutboundGroupSession()..create();
            try {
              await full.encryption!.keyManager.setInboundGroupSession(
                  room.id, outbound.session_id(), 'synthetic-sender', {
                'algorithm': AlgorithmTypes.megolmV1AesSha2,
                'session_key': outbound.session_key()
              });
              await full.database!.storeEventUpdate(
                  EventUpdate(
                      roomID: room.id,
                      type: EventUpdateType.timeline,
                      content: {
                        'event_id': 'cached-58',
                        'type': EventTypes.Encrypted,
                        'sender': user,
                        'origin_server_ts': 10058,
                        'content': {
                          'algorithm': AlgorithmTypes.megolmV1AesSha2,
                          'session_id': outbound.session_id(),
                          'sender_key': 'synthetic-sender',
                          'ciphertext': outbound.encrypt(jsonEncode({
                            'room_id': room.id,
                            'type': EventTypes.Message,
                            'content': {
                              'msgtype': 'm.text',
                              'body': 'Synthetic encrypted head'
                            }
                          }))
                        }
                      }),
                  full);
              full.encryption!.keyManager.clearInboundGroupSessions();
              for (final entry in [
                'm.image',
                'm.video',
                'm.audio',
                'm.file',
                'm.sticker',
                'com.changliao.red_packet'
              ].indexed) {
                await full.database!.storeEventUpdate(
                    EventUpdate(
                        roomID: room.id,
                        type: EventUpdateType.timeline,
                        content: {
                          'event_id': 'cached-${57 - entry.$1}',
                          'type': entry.$2 == 'm.sticker'
                              ? EventTypes.Sticker
                              : EventTypes.Message,
                          'sender': user,
                          'origin_server_ts': 10057 - entry.$1,
                          'content': {
                            'msgtype': entry.$2,
                            'body': 'Synthetic media ${entry.$1}',
                            'info': {
                              'mimetype': 'image/png',
                              'w': 20,
                              'h': 30,
                              'size': 50,
                              'duration': 100
                            },
                            'file': {
                              'key': {'k': 'forbidden-synthetic-key'}
                            },
                            'packet_id': 'forbidden-authority'
                          }
                        }),
                    full);
              }
            } finally {
              outbound.free();
            }
          }
          final owner = MatrixSdkE2eeClient(full,
              homeserver: host,
              secureSessionStore: store,
              readContinuityMetadata: factory.continuityMetadata);
          if (!allHidden) {
            for (final index in [63, 62]) {
              final room = full.getRoomById('!room-$index:synthetic.test')!;
              if (index == 62) {
                room.setState(Event(
                    room: room,
                    eventId: 'budget-name',
                    type: EventTypes.RoomName,
                    stateKey: '',
                    senderId: user,
                    originServerTs: DateTime.utc(2026, 10, 17),
                    content: {'name': List.filled(4000, 'n').join()}));
              }
              for (var member = 0; member < (index == 63 ? 1 : 9); member++) {
                room.setState(Event(
                    room: room,
                    eventId: 'budget-member-$index-$member',
                    type: EventTypes.RoomMember,
                    stateKey:
                        '@${List.filled(170, 'u').join()}$member:synthetic.test',
                    senderId: user,
                    originServerTs: DateTime.utc(2026, 10, 17),
                    content: {
                      'membership': 'join',
                      'displayname':
                          List.filled(index == 63 ? 257 : 200, 'm').join(),
                      'avatar_url':
                          'mxc://synthetic.test/${List.filled(980, 'a').join()}'
                    }));
              }
            }
            for (var member = 0; member < 2; member++) {
              final url = MatrixAvatarUrlResolver.authenticatedCacheUrl(
                  avatarUri: Uri.parse('mxc://synthetic.test/avatar-$member'),
                  homeserver: host)!;
              await AvatarCache.manager.putFile(
                  url,
                  base64Decode(
                      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
                  key: AvatarCache.cacheKey(
                      userId: owner.avatarCacheIdentity(
                          '@avatar-$member:synthetic.test')!,
                      avatarUrl: url),
                  fileExtension: 'png');
            }
          }
          final cache = StartupProjectionStore(
              Directory('${directory.path}/startup_projection_v1'));
          // Synthetic fully restored owner, admitted by the fixture's Business authority.
          await owner.primeStartupProjection(cache);
          final installation = await cache.readInstallation();
          expect(installation, isNotNull);
          final admitted =
              await store.readStartupProjectionAdmission(installation!);
          expect(admitted, isNotNull,
              reason: 'verified writer must commit a readable head');
          final projection = await cache.read(admitted!);
          expect(projection!.rooms, allHidden ? isEmpty : isNotEmpty);
          if (!allHidden) {
            expect(projection.rooms.map((room) => room.id),
                contains('!room-63:synthetic.test'),
                reason:
                    'one oversized member must not remove a valid cached room');
            expect(projection.rooms.map((room) => room.id),
                contains('!room-62:synthetic.test'),
                reason:
                    'aggregate member budget must trim members, not remove the room');
            expect(
                projection.rooms
                    .singleWhere((room) => room.id == '!room-63:synthetic.test')
                    .members,
                isEmpty);
            final boundedMembers = projection.rooms
                .singleWhere((room) => room.id == '!room-62:synthetic.test')
                .members;
            expect(boundedMembers, isNotEmpty);
            expect(boundedMembers.length, lessThan(9));
            final head = projection.rooms
                .firstWhere((r) => r.id == '!room-64:synthetic.test');
            expect(head.encrypted, isTrue);
            expect(head.membership, 'join');
            expect(head.events.firstWhere((e) => e.id == 'cached-58').body,
                'Synthetic encrypted head');
            expect(
                head.events.map((e) => e.kind).toSet(),
                containsAll([
                  'm.text',
                  'm.image',
                  'm.video',
                  'm.audio',
                  'm.file',
                  'm.sticker',
                  'com.changliao.red_packet'
                ]));
            expect(utf8.decode(projection.encode()),
                isNot(contains('forbidden-synthetic-key')));
            expect(utf8.decode(projection.encode()),
                isNot(contains('forbidden-authority')));
          }
          if (!allHidden) {
            // Canonical head advances after the last committed projection, with
            // no event replay in the resumed mock sync.
            await full.database!.storeEventUpdate(
                EventUpdate(
                    roomID: '!room-64:synthetic.test',
                    type: EventUpdateType.timeline,
                    content: {
                      'event_id': 'canonical-new-head',
                      'type': EventTypes.Message,
                      'sender': user,
                      'origin_server_ts': 10060,
                      'content': {
                        'msgtype': 'm.text',
                        'body': 'Canonical newer head'
                      }
                    }),
                full);
          }
          await held.previewSettled.future.timeout(const Duration(seconds: 5));
          await full.dispose();
          store.startupProjectionCoordinator =
              null; // process-restart fixture boundary
          priming = false;
          opened = false;
          databaseOpens = 0;
          if (const bool.fromEnvironment('STARTUP_PROJECTION_BASELINE')) {
            // Safe baseline adapter: cache miss follows the prior full-preflight path.
            await File('${directory.path}/startup_projection_v1/installation')
                .delete();
          }
        });
      }
      if (independent) {
        rawSecure.diagnosticHold = Completer<void>();
        rawSecure.admissionHold = Completer<void>();
      }
      try {
        await app.main(
            dependencies: app.StartupDependencies(
                store: store,
                matrixFactory: matrixFactory,
                api: api,
                reconcile: () async => InstallationResetOutcome.notNeeded,
                outboxStoreFactory: () => outbox));
        if (independent) {
          for (var i = 0;
              i < 100 && !rawSecure.admissionEntered.isCompleted;
              i++) {
            await flush(1);
          }
          expect(rawSecure.admissionEntered.isCompleted, isTrue);
          await tester.pump(const Duration(seconds: 2));
          expect(find.text('正在启动畅聊'), findsNothing,
              reason: 'cache admission must not expose a loading frame');
          expect(tester.binding.sendFramesToEngine, isFalse);
          auditVisibleFrames = true;
          void observeFrame(Duration _) {
            if (!auditVisibleFrames) return;
            auditFrame();
            WidgetsBinding.instance.addPostFrameCallback(observeFrame);
          }

          WidgetsBinding.instance.addPostFrameCallback(observeFrame);
          rawSecure.admissionHold!.complete();
        }
        // SQLCipher/secure-store work uses real I/O; wait for its semantic
        // local-ready milestone while pumping both zones, not a fixed count.
        for (var attempt = 0;
            attempt < 300 && find.byType(AppHome).evaluate().isEmpty;
            attempt++) {
          await flush(1);
        }
        expect(tester.takeException(), isNull,
            reason: "fixture setup must succeed");
        await tester.pump(const Duration(seconds: 4));
        expect(find.byType(AppHome), findsOneWidget,
            reason: tester.allWidgets
                .whereType<Text>()
                .map((w) => w.data)
                .join(' | '));
        expect(find.text('正在打开本地聊天，请稍候'), findsNothing);
        if (independent) {
          expect(rawSecure.diagnosticHold!.isCompleted, isFalse,
              reason:
                  'optional diagnostic salt must not block first content frame');
          rawSecure.diagnosticHold!.complete();
          await flush(10);
          expect(latestFactory!.diagnosticHasher, isNotNull);
          expect(
              latestFactory!.diagnosticHasher!
                  .of(matrixUserId: user)
                  .hashed['matrix_user'],
              isNot(user));
        }
        if (independent) {
          expect(databaseOpens, 0);
          expect(preflight.originalCalls, 0);
          expect(client.isLogged(), isFalse,
              reason: 'display cache does not fabricate SDK login');
        } else {
          expect(held.release.isCompleted, isFalse);
          expect(held.fullRead, isFalse);
        }
        expect(client.rooms, hasLength(independent && allHidden ? 0 : 40));
        if (allHidden) {
          if (independent) {
            expect(firstVisibleContent, isTrue);
            auditVisibleFrames = false;
          }
          expect(find.text('Synthetic room 64'), findsNothing);
          if (independent) {
            expect(preflight.originalCalls, 0);
            expect(databaseOpens, 0);
            preflight.release.complete();
          } else {
            expect(held.entered.isCompleted, isTrue,
                reason: 'empty visible snapshot must release frame barrier');
            held.release.complete();
          }
          var sdkReady = false;
          client.initializationCompleted.then((_) => sdkReady = true);
          for (var attempt = 0; attempt < 300 && !sdkReady; attempt++) {
            await flush(1);
          }
          expect(sdkReady, isTrue, reason: 'full SDK continuation must settle');
          await flush(100);
          expect(held.fullRead, isTrue);
          report?.call({
            'scenario': independent
                ? 'actual-main-empty-independent'
                : 'actual-main-hidden-sdk',
            'content_ready_ms': clock.elapsedMilliseconds,
            if (independent) 'first_visible_content': firstVisibleContent,
            if (independent) 'no_loading_frames': true,
            'projected_rooms': 0,
            'network_sends_while_held': 0,
            'network_sends_after_recovery': 0
          });
          return;
        }
        expect(find.text('Synthetic room 64'), findsOneWidget);
        if (independent) {
          expect(find.text('网络不可用，点击重试'), findsNothing,
              reason: 'ongoing SDK restore is not an offline determination');
          final matrix = tester.widget<AppHome>(find.byType(AppHome)).matrix;
          final snapshot = await matrix.conversations.snapshot();
          final group = snapshot.rooms
              .singleWhere((room) => room.id == '!room-64:synthetic.test');
          expect(group.avatar, isNull,
              reason: 'absent custom avatar must preserve mosaic selection');
          expect(
              group.members.where((member) => member.id.startsWith('@avatar-')),
              hasLength(2));
          expect(find.byType(GroupAvatarMosaic), findsWidgets);
          bool localAvatarPainted() => tester
              .widgetList<RawImage>(find.descendant(
                  of: find.byType(GroupAvatarMosaic),
                  matching: find.byType(RawImage)))
              .any((image) => image.image != null);
          for (var attempt = 0;
              attempt < 200 && !localAvatarPainted();
              attempt++) {
            await flush(1);
          }
          expect(preflight.originalCalls, 0);
          expect(databaseOpens, 0);
          expect(
              tester
                  .widgetList<RawImage>(find.descendant(
                      of: find.byType(GroupAvatarMosaic),
                      matching: find.byType(RawImage)))
                  .any((image) => image.image != null),
              isTrue,
              reason:
                  'isolated existing disk avatar bytes paint while original DB and SDK are unopened');
        }
        if (avatarHandoff) {
          auditVisibleFrames = false;
          final members = find.byWidgetPredicate((widget) =>
              widget is MatrixUserAvatar &&
              widget.matrixAvatarUri?.host == 'synthetic.test' &&
              widget.matrixAvatarUri!.path.startsWith('/avatar-'));
          final expectedUris = {
            'mxc://synthetic.test/avatar-0',
            'mxc://synthetic.test/avatar-1'
          };
          var auditing = true;
          var auditedFrames = 0;
          final avatarStates = <String, State>{};
          void auditAvatars(Duration _) {
            if (!auditing) return;
            expectSync(find.byType(RoomPage), findsNothing);
            expectSync(
                tester
                    .widgetList<MatrixUserAvatar>(members)
                    .map((widget) => widget.matrixAvatarUri.toString())
                    .toSet(),
                expectedUris);
            for (final element in members.evaluate()) {
              final widget = element.widget as MatrixUserAvatar;
              final key = widget.matrixAvatarUri.toString();
              final state = (element as StatefulElement).state;
              final previous = avatarStates.putIfAbsent(key, () => state);
              expectSync(state, same(previous),
                  reason: 'same admitted owner retains each mounted member');
              expectSync(
                  tester
                      .widgetList<RawImage>(find.descendant(
                          of: find.byWidget(element.widget),
                          matching: find.byType(RawImage)))
                      .any((image) => image.image != null),
                  isTrue,
                  reason:
                      'every visible member remains painted through SDK handoff');
            }
            auditedFrames++;
            WidgetsBinding.instance.addPostFrameCallback(auditAvatars);
          }

          auditAvatars(Duration.zero);
          var sdkReady = false;
          client.initializationCompleted.then((_) => sdkReady = true);
          preflight.release.complete();
          try {
            for (var attempt = 0; attempt < 300 && !sdkReady; attempt++) {
              await flush(1);
            }
            expect(sdkReady, isTrue);
            await flush(100);
            expect(auditedFrames, greaterThan(2));
            expect(tester.takeException(), isNull);
            expect(transportSends, 0);
            report?.call({
              'scenario': 'actual-main-avatar-handoff',
              'avatar_handoff_continuous': true,
              'first_visible_avatar': true,
              'audited_avatar_frames': auditedFrames,
              'network_sends_while_held': 0,
              'network_sends_after_recovery': 0
            });
          } finally {
            auditing = false;
          }
          return;
        }
        final contentReadyMs = clock.elapsedMilliseconds;
        await tester.tap(find.text('通讯录').last);
        await flush();
        expect(
            independent
                ? preflight.release.isCompleted
                : held.release.isCompleted,
            isFalse);
        await tester.tap(find.text('消息').last);
        await flush();
        await tester.tap(find.text('Synthetic room 64'));
        await flush(80);
        expect(find.byType(RoomPage), findsOneWidget);
        expect(find.text('Cached message 59'), findsWidgets);
        expect(
            independent
                ? preflight.release.isCompleted
                : held.release.isCompleted,
            isFalse);
        if (independent) {
          expect(firstVisibleContent, isTrue);
          expect(firstRoomContent, isTrue);
          auditVisibleFrames = false;
        }
        final roomState = tester.state(find.byType(RoomPage));
        final retainedRoom = client.getRoomById('!room-64:synthetic.test');
        if (independent) {
          expect(retainedRoom!.encrypted, isTrue);
          expect(retainedRoom.membership, Membership.join);
          expect(find.text('Synthetic encrypted head'), findsOneWidget);
          expect(databaseOpens, 0);
          expect(client.encryption, isNull);
        }
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
        expect(
            independent
                ? preflight.release.isCompleted
                : held.release.isCompleted,
            isFalse);
        await tester.enterText(
            find.byKey(const Key('composer-input')), 'Synthetic pending text');
        await tester.pump();
        await tester.tap(find.byKey(const Key('composer-send')));
        await flush(40);
        final rows = await tester.runAsync(() => outbox.query(accountId: user));
        expect(rows, hasLength(1));
        final txid = rows!.single.txid;
        expect(transportSends, 0);
        expect(
            independent
                ? preflight.release.isCompleted
                : held.release.isCompleted,
            isFalse);
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
        if (independent) {
          preflight.release.complete();
        } else {
          held.release.complete();
        }
        var sdkReady = false;
        client.initializationCompleted.then((_) => sdkReady = true);
        for (var attempt = 0; attempt < 300 && !sdkReady; attempt++) {
          await flush(1);
        }
        expect(sdkReady, isTrue, reason: 'full SDK continuation must settle');
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
        if (independent) {
          final dynamic activePage = roomState;
          expect(activePage.controller.findMessage('cached-57').packetId,
              'forbidden-authority',
              reason: 'decrypted media retains canonical content');
          expect(activePage.controller.findMessage('canonical-new-head').text,
              'Canonical newer head');
          expect(activePage.controller.findMessage('cached-52').packetId,
              'forbidden-authority',
              reason:
                  'same active timeline must adopt canonical custom metadata without replay');
        }
        expect(transportTxids, [txid],
            reason: 'transport retains durable transaction identity');
        if (independent) {
          expect(encryptedTransport, isTrue,
              reason:
                  'cached display cannot downgrade the actual E2EE transport');
        }
        final afterRows =
            await tester.runAsync(() => outbox.query(accountId: user));
        expect(afterRows!.where((row) => row.txid != txid), isEmpty);
        expect(transportSends, 1,
            reason: 'same queued transaction dispatches once after recovery');
        if (independent) {
          expect(client.isInitializationPending, isFalse);
          expect(client.isLogged(), isTrue);
          Navigator.of(tester.element(find.byType(RoomPage))).pop();
          await flush(80);
          expect(find.byType(RoomPage), findsNothing);
          final home =
              tester.widget<MatrixHomePage>(find.byType(MatrixHomePage));
          final navigator = Navigator.of(
              tester.element(find.byType(MatrixHomePage)),
              rootNavigator: true);
          for (final source in [
            RoomOpenSource.search,
            RoomOpenSource.contactProfile
          ]) {
            final origin = CupertinoPageRoute<void>(
                builder: (_) => const CupertinoPageScaffold(
                    child: Center(child: Text('Synthetic origin'))));
            unawaited(navigator.push(origin));
            await flush(40);
            held.warmRoomRead = Completer<void>();
            final pending = home.onOpenRoom!(RoomOpenRequest(
                roomId: '!room-64:synthetic.test',
                roomName: 'Synthetic room 64',
                source: source));
            await flush(20);
            expect(origin.isCurrent, isTrue,
                reason: 'capturing origin must never pop it');
            navigator.pop();
            await flush(40);
            held.warmRoomRead!.complete();
            await flush(40);
            await pending;
            expect(find.byType(RoomPage), findsNothing,
                reason:
                    'returning from the initiating page cancels delayed navigation');
          }
          held.warmRoomRead = Completer<void>();
          await tester.tap(find.text('Synthetic room 64'));
          await flush(20);
          await tester.tap(find.text('通讯录').last);
          await flush(10);
          held.warmRoomRead!.complete();
          await flush(40);
          expect(find.byType(RoomPage), findsNothing,
              reason:
                  'tab navigation remains interactive and cancels the pending push');
          await tester.tap(find.text('消息').last);
          await flush(10);
          held.warmRoomRead = Completer<void>();
          auditVisibleFrames = true;
          firstRoomContent = false;
          await tester.tap(find.text('Synthetic room 64'));
          await flush(20);
          expect(held.warmRoomReadEntered.isCompleted, isTrue,
              reason:
                  'ordinary post-recovery entry reads the persisted local timeline');
          expect(find.text('正在读取本机消息…'), findsNothing,
              reason:
                  'warm restored room entry must not expose a loading page while local SQL is pending');
          expect(find.byType(RoomPage), findsNothing);
          await tester.tap(find.text('Synthetic room 64'));
          await flush(5);
          held.warmRoomRead!.complete();
          await flush(80);
          expect(find.byType(RoomPage), findsOneWidget);
          expect(find.text('Cached message 59'), findsWidgets);
          expect(firstRoomContent, isTrue);
          auditVisibleFrames = false;
        }
        report?.call({
          'scenario': independent
              ? 'actual-main-held-entire-preflight'
              : 'actual-main-held-sdk',
          if (independent) 'first_visible_content': firstVisibleContent,
          if (independent) 'first_room_content': firstRoomContent,
          if (independent) 'no_loading_frames': true,
          if (independent) 'warm_room_no_loading_frames': true,
          if (independent) 'no_false_offline_during_restore': true,
          if (independent) 'cached_group_avatar_members': true,
          'original_preflight_calls_while_held': 0,
          'original_opener_calls_while_held': 0,
          'content_ready_ms': contentReadyMs,
          'interactive_ms': clock.elapsedMilliseconds,
          'projected_rooms': 40,
          'network_sends_while_held': 0,
          'network_sends_after_recovery': transportSends
        });
      } finally {
        auditVisibleFrames = false;
        if (held.warmRoomRead?.isCompleted == false) {
          held.warmRoomRead!.complete();
        }
        if (rawSecure.admissionHold?.isCompleted == false) {
          rawSecure.admissionHold!.complete();
        }
        if (rawSecure.diagnosticHold?.isCompleted == false) {
          rawSecure.diagnosticHold!.complete();
        }
        if (!preflight.release.isCompleted) preflight.release.complete();
        await flush(80);
        if (opened) {
          if (find.byType(RoomPage).evaluate().isNotEmpty) {
            final lease =
                tester.widget<RoomPage>(find.byType(RoomPage)).roomLease;
            Navigator.of(tester.element(find.byType(RoomPage)),
                    rootNavigator: true)
                .pop();
            await flush(50);
            var drained = false;
            final drain = lease.cancel().then((_) => drained = true);
            for (var i = 0; i < 300 && !drained; i++) {
              await flush(1);
            }
            expect(drained, isTrue,
                reason:
                    'room owner drain must settle before advancing teardown clock');
            await drain;
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
