import 'dart:async';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/room_event_context_capability.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_index.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:olm/olm.dart' as olm;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Client extends Client {
  _Client(this.storage, this.downloads)
      : super('old-event-fixture', httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/versions')) {
            return http.Response('{"versions":["v1.11"]}', 200);
          }
          final bytes = downloads[request.url.pathSegments.last];
          if (bytes != null) return http.Response.bytes(bytes, 200);
          throw StateError('Unexpected fixture request: ${request.url.path}');
        }));
  final MatrixSdkDatabase storage;
  final Map<String, Uint8List> downloads;
  @override
  DatabaseApi get database => storage;
  @override
  String get userID => account;
  String account = '@historical:example.test';
  @override
  String get deviceID => 'RETAINED';
  late final crypto = Encryption(client: this);
  @override
  Encryption get encryption => crypto;
  @override
  bool get encryptionEnabled => true;
}

class _Database extends MatrixSdkDatabase {
  _Database(Database sql, DatabaseFactory factory)
      : super('historical', database: sql, sqfliteFactory: factory);
  Future<void> Function()? beforeRead;
  Future<void> Function()? beforeIndexWrite;
  int reads = 0;
  @override
  Future<Event?> getEventById(String id, Room room) async {
    reads++;
    await beforeRead?.call();
    return super.getEventById(id, room);
  }

  @override
  Future<void> updateInboundGroupSessionIndexes(
      String indexes, String roomId, String sessionId) async {
    await beforeIndexWrite?.call();
    await super.updateInboundGroupSessionIndexes(indexes, roomId, sessionId);
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Room extends Room {
  _Room({required super.id, required super.client});
  @override
  Future<Timeline> getTimeline(
      {void Function(int)? onChange,
      void Function(int)? onRemove,
      void Function(int)? onInsert,
      void Function()? onNewEvent,
      void Function()? onUpdate,
      String? eventContextId}) async {
    if (eventContextId != null) throw const SocketException('Offline fixture');
    return Timeline(
        room: this, chunk: TimelineChunk(events: []), onUpdate: onUpdate);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(olm.init);
  test('single network event rejects explicit foreign room binding', () async {
    final client = Client('foreign-event',
        httpClient: MockClient((_) async => http.Response(
            jsonEncode({
              'event_id': r'$foreign',
              'room_id': '!foreign:example.test',
              'sender': '@synthetic:example.test',
              'origin_server_ts': 1,
              'type': EventTypes.Message,
              'content': {'msgtype': 'm.text', 'body': 'synthetic'}
            }),
            200)))
      ..homeserver = Uri.parse('https://example.test')
      ..accessToken = 'synthetic';
    final room = Room(id: '!expected:example.test', client: client);
    try {
      expect(await room.getEventById(r'$foreign'), isNull);
    } finally {
      await client.dispose();
    }
  });
  for (final scenario in [
    'text',
    'image',
    'video',
    'wrong-room',
    'wrong-sender',
    'wrong-session',
    'bad-key',
    'redacted',
    'hidden',
    'retry-key',
    'canceled',
    'revoked',
    'foreign-account',
    'held-index',
    'hidden-after-cache',
    'redacted-after-cache'
  ]) {
    final kind =
        ['text', 'image', 'video'].contains(scenario) ? scenario : 'image';
    test('five-day SQLCipher ciphertext resolves $scenario outside live window',
        () async {
      SharedPreferences.setMockInitialValues({});
      final artifacts = p.normalize(p.absolute(
          '../../docs/verification/artifacts/2026-10-04/history-anchor-media-ios'));
      final directory = await Directory(artifacts).createTemp('task1-crypto-');
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final path = p.join(directory.path, 'synthetic.sqlite');
      final helper = SQfLiteEncryptionHelper(
          factory: factory, path: path, cipher: 'synthetic-only-fixture-key');
      Future<_Database> open() async {
        final sql = await factory.openDatabase(path,
            options: OpenDatabaseOptions(onConfigure: helper.applyPragmaKey));
        expect(
            (await sql.rawQuery('PRAGMA cipher_version')).isNotEmpty, isTrue);
        final db = _Database(sql, factory);
        await db.open();
        return db;
      }

      var db = await open();
      final downloads = <String, Uint8List>{};
      var client = _Client(db, downloads)
        ..homeserver = Uri.parse('https://example.test')
        ..accessToken = 'synthetic';
      var room = Room(id: '!historical:example.test', client: client);
      final outbound = olm.OutboundGroupSession()..create();
      final sessionId = outbound.session_id();
      final sessionKey = outbound.session_key();
      final body = Uint8List.fromList([1, 7, 4, 2, kind.length]);
      final thumbnail = Uint8List.fromList([9, 4, 3, kind.length]);
      Future<Map<String, dynamic>> descriptor(
          Uint8List bytes, String name) async {
        final encrypted = await MatrixFile(bytes: bytes, name: name).encrypt();
        downloads[name] = encrypted.data;
        return {
          'url': 'mxc://example.test/$name',
          'v': 'v2',
          'key': {
            'kty': 'oct',
            'alg': 'A256CTR',
            'ext': true,
            'key_ops': ['encrypt', 'decrypt'],
            'k': scenario == 'bad-key' && name.endsWith('body')
                ? base64Url.encode(List.filled(32, 0)).replaceAll('=', '')
                : encrypted.k
          },
          'iv': encrypted.iv,
          'hashes': {'sha256': encrypted.sha256}
        };
      }

      final content = <String, dynamic>{
        'msgtype': 'm.$kind',
        'body': 'synthetic.$kind'
      };
      if (kind != 'text') {
        content.addAll({
          'file': await descriptor(body, '$kind-body'),
          'info': {
            'thumbnail_file': await descriptor(thumbnail, '$kind-thumb'),
            'mimetype': kind == 'image' ? 'image/png' : 'video/mp4'
          },
          'chatflow_media': {
            'v': 1,
            'content_sha256': sha256.convert(body).toString(),
            'thumbnail_sha256': sha256.convert(thumbnail).toString()
          }
        });
      }
      final timestamp = DateTime.now().subtract(const Duration(days: 5));
      final json = <String, dynamic>{
        'event_id': '\$old-$kind',
        'sender': client.userID,
        'origin_server_ts': timestamp.millisecondsSinceEpoch,
        'type': EventTypes.Encrypted,
        'content': {
          'algorithm': AlgorithmTypes.megolmV1AesSha2,
          'sender_key':
              scenario == 'wrong-sender' ? 'wrong-sender' : 'synthetic-sender',
          'session_id':
              scenario == 'wrong-session' ? 'missing-session' : sessionId,
          'ciphertext': outbound.encrypt(jsonEncode({
            'room_id':
                scenario == 'wrong-room' ? '!foreign:example.test' : room.id,
            'type': EventTypes.Message,
            'content': content
          }))
        }
      };
      if (scenario != 'retry-key') {
        await client.crypto.keyManager.setInboundGroupSession(
            room.id, sessionId, 'synthetic-sender', {
          'algorithm': AlgorithmTypes.megolmV1AesSha2,
          'session_key': sessionKey
        });
      }
      if (scenario == 'redacted') {
        json['unsigned'] = <String, dynamic>{
          'redacted_because': {
            'type': 'm.room.redaction',
            'event_id': r'$redaction',
            'sender': client.userID,
            'content': {}
          }
        };
      }
      await db.storeEventUpdate(
          EventUpdate(
              roomID: room.id, type: EventUpdateType.timeline, content: json),
          client);
      client.crypto.keyManager.clearInboundGroupSessions();
      await db.database!.close();
      db = await open();
      client = _Client(db, downloads)
        ..homeserver = Uri.parse('https://example.test')
        ..accessToken = 'synthetic';
      room = _Room(id: room.id, client: client);
      client.rooms.add(room);
      final matrix = MatrixSdkE2eeClient(client,
          homeserver: client.homeserver!,
          readContinuityMetadata: (_) async => MatrixClientContinuityMetadata(
              isLoggedIn: true,
              userId: client.userID,
              deviceId: client.deviceID,
              ed25519Fingerprint: 'synthetic',
              databaseGeneration: 'synthetic'));
      final lease = await matrix.openRoomLease(room.id);
      final capability = await lease.openRoomTimeline(onUpdate: () {});
      // The historical row exists only in the retained encrypted store.
      final eventId = json['event_id'] as String;
      (capability as RoomWindowedTimelineSource).enableWindow();
      expect(capability.snapshot(), isEmpty);
      if (scenario == 'hidden') {
        (capability as RoomWindowedTimelineSource)
            .setHiddenFilter((_, __) => true);
      }
      PathProviderPlatform.instance = _Paths(directory.path);
      try {
        if ([
          'wrong-room',
          'wrong-sender',
          'wrong-session',
          'redacted',
          'hidden'
        ].contains(scenario)) {
          expect(
              await (capability as RoomEventContextCapability)
                  .locateEvent(eventId),
              isFalse);
          await expectLater(
              (capability).loadAttachment(eventId), throwsStateError);
        } else if (['canceled', 'revoked', 'foreign-account']
            .contains(scenario)) {
          final entered = Completer<void>(), release = Completer<void>();
          db.beforeRead = () async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          };
          final pending = capability.loadAttachment(eventId);
          final rejected = expectLater(pending, throwsStateError);
          await entered.future;
          if (scenario == 'canceled') capability.dispose();
          if (scenario == 'revoked') client.recoveryOwner!.revoke();
          if (scenario == 'foreign-account') {
            client.account = '@foreign:example.test';
          }
          release.complete();
          await rejected;
          expect(lease.mediaCacheKey(eventId).contentSha256, isNull);
        } else if (scenario == 'held-index') {
          final entered = Completer<void>(), release = Completer<void>();
          db.beforeIndexWrite = () async {
            entered.complete();
            await release.future;
          };
          final pending = capability.loadAttachment(eventId);
          final rejected = expectLater(pending, throwsStateError);
          await entered.future;
          expect(client.recoveryOwner!.pendingWrites, 1);
          client.recoveryOwner!.revoke();
          await expectLater(
              client.recoveryOwner!
                  .drain()
                  .timeout(const Duration(milliseconds: 20)),
              throwsA(isA<TimeoutException>()));
          expect(db.database!.isOpen, isTrue);
          release.complete();
          await rejected;
          await client.recoveryOwner!.drain();
          expect(lease.mediaCacheKey(eventId).contentSha256, isNull);
        } else if (['hidden-after-cache', 'redacted-after-cache']
            .contains(scenario)) {
          await capability.loadAttachment(eventId);
          if (scenario == 'hidden-after-cache') {
            (capability as RoomWindowedTimelineSource)
                .setHiddenFilter((_, __) => true);
          } else {
            json['unsigned'] = <String, dynamic>{
              'redacted_because': {
                'type': 'm.room.redaction',
                'event_id': r'$redaction',
                'sender': client.userID,
                'content': {}
              }
            };
            final update = EventUpdate(
                roomID: room.id, type: EventUpdateType.timeline, content: json);
            await db.storeEventUpdate(update, client);
            client.onEvent.add(update);
            await Future<void>.delayed(Duration.zero);
          }
          await expectLater(
              capability.loadAttachment(eventId), throwsStateError);
        } else if (scenario == 'retry-key') {
          await expectLater(
              capability.loadAttachment(eventId), throwsStateError);
          await client.crypto.keyManager.setInboundGroupSession(
              room.id, sessionId, 'synthetic-sender', {
            'algorithm': AlgorithmTypes.megolmV1AesSha2,
            'session_key': sessionKey
          });
          expect(
              sha256
                  .convert(await capability.loadAttachment(eventId))
                  .toString(),
              sha256.convert(body).toString());
        } else if (scenario == 'bad-key') {
          await expectLater(capability.loadAttachment(eventId),
              throwsA(isA<FormatException>()));
        } else if (kind == 'text') {
          expect(
              await (capability as RoomEventContextCapability)
                  .locateEvent(eventId),
              isTrue);
          expect(
              (capability)
                  .snapshot()
                  .any((m) => m.id == eventId && m.text == content['body']),
              isTrue);
        } else {
          final reads = db.reads;
          final results = await Future.wait([
            capability.loadThumbnail(eventId),
            capability.loadAttachment(eventId)
          ]);
          expect(sha256.convert(results[0]!).toString(),
              sha256.convert(thumbnail).toString());
          expect(sha256.convert(results[1]!).toString(),
              sha256.convert(body).toString());
          expect(db.reads - reads, 1,
              reason: 'concurrent consumers share one event read/decrypt');
          expect(lease.mediaCacheKey(eventId).contentSha256,
              sha256.convert(body).toString());
        }
      } finally {
        capability.dispose();
        await lease.cancel();
        await client.recoveryOwner?.drain();
        client.crypto.keyManager.clearInboundGroupSessions();
        outbound.free();
        await db.database!.close();
        clearMediaMemoryCaches();
        await MediaIndex.shared.close();
        MediaIndex.shared.resetForTest();
        if (!p.isWithin(artifacts, directory.path)) {
          throw StateError('fixture path');
        }
        await directory.delete(recursive: true);
      }
    });
  }
}
