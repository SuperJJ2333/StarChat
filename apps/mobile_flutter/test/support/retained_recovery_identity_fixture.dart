import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/client_init_exception.dart';
import 'package:olm/olm.dart' as olm;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Synthetic HTTP only: initialization, encryption, keyed database, and binding
/// persistence use the actual SDK/application implementations.
class RetainedRecoveryIdentityFixture {
  RetainedRecoveryIdentityFixture(this.path, this.cipher, this.sessions,
      {this.preserveStoreOnInvalidToken = true});

  static final endpoint = Uri.parse('https://synthetic.example.test');
  static const user = '@continuity:synthetic.example.test';
  static const roomId = '!retained:synthetic.example.test';
  static const eventId = r'$retained-five-day';
  static const clientName = 'retained-recovery-identity';
  final String path;
  final String cipher;
  final SecureSessionStore sessions;
  final bool preserveStoreOnInvalidToken;
  late Client client;
  late HeldRecoveryDatabase database;
  late MatrixSdkE2eeClient matrix;
  late final factory =
      MatrixClientFactory(sessionStore: sessions, homeserver: endpoint);
  String responseDevice = 'RETAINED';
  String responseUser = user;
  int closes = 0;
  bool failUpload = false;
  Map<String, dynamic>? uploadedDeviceKeys;
  Completer<void>? loginEntered;
  Completer<void>? loginRelease;

  Future<http.Response> _respond(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/versions')) {
      return http.Response('{"versions":["v1.1","v1.2","v1.11"]}', 200);
    }
    if (path.endsWith('/login') && request.method == 'GET') {
      return http.Response('{"flows":[{"type":"m.login.token"}]}', 200);
    }
    if (path.endsWith('/login')) {
      loginEntered?.complete();
      await loginRelease?.future;
      return http.Response(
          jsonEncode({
            'user_id': responseUser,
            'device_id': responseDevice,
            'access_token': 'synthetic-renewed',
            'refresh_token': 'synthetic-refresh-renewed',
            'expires_in_ms': 3600000,
          }),
          200);
    }
    if (path.endsWith('/keys/upload')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['device_keys'] != null) {
        uploadedDeviceKeys = body['device_keys'] as Map<String, dynamic>;
      }
      if (failUpload) {
        return http.Response('{"errcode":"M_UNKNOWN","error":"synthetic"}', 503,
            headers: {'content-type': 'application/json'});
      }
      return http.Response(
          jsonEncode({
            'one_time_key_counts': {
              'signed_curve25519':
                  (jsonDecode(request.body)['one_time_keys'] as Map?)?.length ??
                      0
            }
          }),
          200);
    }
    if (path.endsWith('/filter')) {
      return http.Response('{"filter_id":"synthetic"}', 200);
    }
    if (path.endsWith('/keys/query')) {
      return http.Response('{"device_keys":{}}', 200);
    }
    if (path.endsWith('/sync')) {
      return http.Response('{"next_batch":"synthetic-head","rooms":{}}', 200);
    }
    if (path.endsWith('/messages')) {
      return http.Response('{"chunk":[],"start":"synthetic"}', 200);
    }
    return http.Response('{}', 200);
  }

  Future<Client> openClient({bool seed = false}) async {
    final sqlFactory =
        createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final encryption = SQfLiteEncryptionHelper(
        factory: sqlFactory, path: path, cipher: cipher);
    final sql = await sqlFactory.openDatabase(path,
        options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
    expect((await sql.rawQuery('PRAGMA cipher_version')).isNotEmpty, isTrue);
    database = HeldRecoveryDatabase(sql, sqlFactory);
    await database.open();
    client = Client(clientName,
        databaseBuilder: (_) => database,
        supportedLoginTypes: {'m.login.token'},
        httpClient: MockClient(_respond),
        preserveStoreOnInvalidToken: preserveStoreOnInvalidToken)
      ..backgroundSync = false;
    // Factory production order: real SDK init precedes the wrapper constructor.
    if (seed) {
      await client.init(
          newToken: 'synthetic-original',
          newRefreshToken: 'synthetic-refresh-original',
          newTokenExpiresAt: DateTime.utc(2040),
          newHomeserver: endpoint,
          newUserID: user,
          newDeviceID: 'RETAINED',
          newDeviceName: 'retained-device');
    } else {
      await client.init();
    }
    client.rooms.add(Room(id: roomId, client: client));
    return client;
  }

  void wrap() {
    matrix = MatrixSdkE2eeClient(client,
        homeserver: endpoint,
        readContinuityMetadata: factory.continuityMetadata,
        rotateDeviceBinding: factory.rotateDeviceBinding,
        lifecycleDrainTimeout: const Duration(milliseconds: 30),
        suspendClient: (active) async {
          closes++;
          await active.dispose();
        },
        resumeClient: () => openClient(),
        selectClientAccount: (server, account) =>
            sessions.selectMatrixAccount(server, account));
  }

  Future<void> seedHistory() async {
    final outbound = olm.OutboundGroupSession()..create();
    try {
      final sessionId = outbound.session_id();
      final key = outbound.session_key();
      await client.encryption!.keyManager
          .setInboundGroupSession(roomId, sessionId, 'synthetic-sender', {
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'session_key': key,
      });
      await database.storeEventUpdate(
          EventUpdate(roomID: roomId, type: EventUpdateType.timeline, content: {
            'event_id': eventId,
            'sender': user,
            'origin_server_ts': DateTime.now()
                .subtract(const Duration(days: 5))
                .millisecondsSinceEpoch,
            'type': EventTypes.Encrypted,
            'content': {
              'algorithm': AlgorithmTypes.megolmV1AesSha2,
              'sender_key': 'synthetic-sender',
              'session_id': sessionId,
              'ciphertext': outbound.encrypt(jsonEncode({
                'room_id': roomId,
                'type': EventTypes.Message,
                'content': {
                  'msgtype': 'm.text',
                  'body': 'synthetic retained history'
                }
              }))
            }
          }),
          client);
    } finally {
      outbound.free();
    }
  }

  Future<void> expectHistory() async {
    final lease = await matrix.openRoomLease(roomId);
    expect(client.recoveryOwner?.active, isTrue,
        reason: 'First real continuity validation must admit retained owner.');
    final timeline = await lease.openRoomTimeline(onUpdate: () {});
    try {
      final event =
          await (timeline as RoomMessageLookupSource).lookupMessage(eventId);
      expect(event?.text, 'synthetic retained history');
    } finally {
      timeline.dispose();
      await lease.cancel();
    }
  }

  Future<void> renew() => matrix.loginWithToken(
      loginToken: 'synthetic-login',
      homeserver: endpoint,
      deviceId: 'RETAINED');

  Future<void> rotateAfterHeldWrite() async {
    await matrix.currentSessionCredentials();
    final original = client;
    final owner = client.recoveryOwner!;
    final fingerprint = client.fingerprintKey;
    final before = await database.getClient(clientName);
    final token = client.accessToken;
    final expiry = client.accessTokenExpiresAt;
    final name = client.deviceName;
    final groupSession = client.groupCallSessionId;
    final binding = await sessions.matrixBinding();
    database.hold = true;
    var published = false;
    final write =
        owner.write(() => database.storeRecoveryRecord('held', {'v': 1}));
    final publication = write.then((_) {
      owner.check();
      published = true;
    });
    final rejectedPublication = expectLater(publication, throwsStateError);
    await database.entered.future;
    responseDevice = 'ROTATED';
    try {
      await expectLater(renew(), throwsA(isA<ClientInitException>()));
      expect(identical(client, original), isTrue);
      expect(client.deviceID, 'RETAINED');
      expect(client.userID, user);
      expect(client.homeserver, endpoint);
      expect(client.accessToken == token, isTrue);
      expect(client.accessTokenExpiresAt, expiry);
      expect(client.deviceName, name);
      expect(client.groupCallSessionId == groupSession, isTrue);
      expect(
          jsonEncode(await database.getClient(clientName)) ==
              jsonEncode(before),
          isTrue);
      expect((await sessions.matrixBinding())?.deviceId, binding?.deviceId);
      expect(owner.active, isFalse);
      expect(() => owner.write(() async {}), throwsStateError);
      await expectLater(matrix.suspend(), throwsA(isA<TimeoutException>()));
      expect(closes, 0, reason: 'A deadline cannot close a live write.');
      expect(identical(client.recoveryOwner, owner), isTrue);
    } finally {
      database.release.complete();
      await write;
      await rejectedPublication;
    }
    expect(published, isFalse);
    await renew();
    expect(identical(client, original), isTrue);
    expect(client.deviceID, 'ROTATED');
    expect(client.recoveryOwner?.active, isTrue);
    expect((await database.getClient(clientName))?['device_id'], 'ROTATED');
    expect((await sessions.matrixBinding())?.deviceId, 'ROTATED');
    expect(client.fingerprintKey == fingerprint, isTrue);
    expect(uploadedDeviceKeys?['device_id'], 'ROTATED');
    expect(
        uploadedDeviceKeys?['keys']['ed25519:ROTATED'] == fingerprint, isTrue);
    expect(
        uploadedDeviceKeys?['signatures'][user]['ed25519:ROTATED'], isNotNull);
    await expectHistory();
  }
}

class HeldRecoveryDatabase extends MatrixSdkDatabase {
  HeldRecoveryDatabase(Database sql, DatabaseFactory factory)
      : super(RetainedRecoveryIdentityFixture.clientName,
            database: sql, sqfliteFactory: factory);
  bool hold = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> storeRecoveryRecord(
      String key, Map<String, dynamic> value) async {
    if (hold && key == 'held') {
      entered.complete();
      await release.future;
    }
    await super.storeRecoveryRecord(key, value);
  }
}
