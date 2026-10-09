import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/voice_playback_controller.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  Future<void> Function()? beforeRead;
  @override
  Future<String?> getApplicationDocumentsPath() async {
    await beforeRead?.call();
    return path;
  }

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Client extends Client {
  _Client(http.Client transport)
      : super('voice-refresh-fixture', httpClient: transport);
  late _Room room;
  String account = '@synthetic:example.test';
  @override
  String get userID => account;
  @override
  String get deviceID => 'SYNTHETIC';
  @override
  bool get encryptionEnabled => true;
  @override
  Room? getRoomById(String id) => room;
}

class _Room extends Room {
  _Room(Client client) : super(id: '!synthetic:example.test', client: client);
  late Timeline fixtureTimeline;
  @override
  bool get encrypted => true;
  @override
  Membership get membership => Membership.join;
  @override
  bool get canSendDefaultMessages => true;
  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
  }) async =>
      fixtureTimeline;
}

class _Engine implements VoiceAudioEngine {
  final completedController = StreamController<void>.broadcast();
  final positionController = StreamController<Duration>.broadcast();
  int playCalls = 0;
  @override
  Future<void> play(Uint8List bytes, {required bool earpiece}) async {
    playCalls++;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<void> get completed => completedController.stream;
  @override
  Stream<Duration> get position => positionController.stream;
}

RoomMessageViewModel _voice() => RoomMessageViewModel(
      id: r'$synthetic-voice',
      senderId: '@peer:example.test',
      text: '',
      isOwn: false,
      deliveryState: RoomDeliveryState.sent,
      timestamp: DateTime.utc(2026, 10, 7),
      kind: RoomMessageKind.voice,
      voiceDuration: const Duration(seconds: 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final thumbnail in [false, true]) {
    for (final scenario in [
      'baseline',
      'identical-refresh',
      'cached-refresh',
      'descriptor-url',
      'descriptor-key',
      'descriptor-iv',
      'descriptor-hash',
      'content-hash',
      'sender',
      'room-envelope',
      'room-envelope-sender',
      'mutable-descriptor',
      'hidden',
      'redaction',
      'account-change',
      'revoked',
      'disposed',
    ]) {
      test('${thumbnail ? 'thumbnail' : 'voice'} media load $scenario',
          () async {
        SharedPreferences.setMockInitialValues({});
        clearMediaMemoryCaches();
        final previousPaths = PathProviderPlatform.instance;
        final root = await Directory(
          '../../docs/verification/artifacts/2026-10-07/voice-network-2204/client-tests',
        ).absolute.create(recursive: true);
        final directory = await root.createTemp('$scenario-');
        final paths = _Paths(directory.path);
        PathProviderPlatform.instance = paths;
        addTearDown(() => PathProviderPlatform.instance = previousPaths);
        // Synthetic container bytes; neither a user recording nor a room key.
        final bytes = Uint8List.fromList([
          0,
          0,
          0,
          24,
          ...'ftypM4A '.codeUnits,
          ...List.filled(16, 0),
        ]);
        final encrypted =
            await MatrixFile(bytes: bytes, name: 'synthetic.m4a').encrypt();
        final started = Completer<void>(), release = Completer<void>();
        var requests = 0;
        final client = _Client(MockClient((request) async {
          if (request.url.path.endsWith('/versions')) {
            return http.Response('{"versions":["v1.11"]}', 200);
          }
          requests++;
          if (!started.isCompleted) started.complete();
          await release.future;
          return http.Response.bytes(encrypted.data, 200);
        }))
          ..homeserver = Uri.parse('https://example.test')
          ..accessToken = 'synthetic';
        final room = _Room(client);
        client.room = room;
        final descriptor = <String, dynamic>{
          'url': 'mxc://example.test/synthetic',
          'v': 'v2',
          'key': {
            'kty': 'oct',
            'alg': 'A256CTR',
            'k': encrypted.k,
            'key_ops': ['encrypt', 'decrypt'],
            'ext': true,
          },
          'iv': encrypted.iv,
          'hashes': {'sha256': encrypted.sha256},
        };
        final json = <String, dynamic>{
          'event_id': r'$synthetic-voice',
          'sender': '@peer:example.test',
          'origin_server_ts': DateTime.utc(2026, 10, 7).millisecondsSinceEpoch,
          'type': EventTypes.Message,
          'original_source': {
            'event_id': r'$synthetic-voice',
            'sender': '@peer:example.test',
            'origin_server_ts':
                DateTime.utc(2026, 10, 7).millisecondsSinceEpoch,
            'type': EventTypes.Encrypted,
            'content': {
              'algorithm': AlgorithmTypes.megolmV1AesSha2,
              'session_id': 'synthetic-session',
              'ciphertext': 'synthetic-room-envelope',
            },
          },
          'content': {
            'msgtype': MessageTypes.Audio,
            'body': 'synthetic.m4a',
            'file': descriptor,
            'info': {
              'duration': 1000,
              'mimetype': 'audio/mp4',
              'size': bytes.length,
              'thumbnail_file': jsonDecode(jsonEncode(descriptor)),
            },
            'chatflow_media': {
              'v': 1,
              'content_sha256': sha256.convert(bytes).toString(),
              'thumbnail_sha256': sha256.convert(bytes).toString(),
            },
          },
        };
        final original = Event.fromJson(json, room);
        room.fixtureTimeline =
            Timeline(room: room, chunk: TimelineChunk(events: [original]));
        final owner = MatrixSdkE2eeClient(
          client,
          homeserver: client.homeserver!,
          readContinuityMetadata: (active) async =>
              MatrixClientContinuityMetadata(
            isLoggedIn: false,
            userId: active.userID,
            deviceId: active.deviceID,
            ed25519Fingerprint: null,
            databaseGeneration: 'synthetic-voice',
          ),
        );
        final lease = await owner.openRoomLease(room.id);
        final capability = await lease.openRoomTimeline(onUpdate: () {});
        final engine = _Engine();
        final playback = VoicePlaybackController(
            loadAttachment: capability.loadAttachment, engine: engine);
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          playback.dispose();
          capability.dispose();
          await lease.cancel();
          await engine.completedController.close();
          await engine.positionController.close();
          await client.dispose();
          clearMediaMemoryCaches();
        });
        var thumbnailFailed = false;
        Future<void> load() async {
          if (!thumbnail) {
            await playback.toggle(_voice());
          } else {
            try {
              expect(await capability.loadThumbnail(original.eventId), bytes);
            } catch (_) {
              thumbnailFailed = true;
            }
          }
        }

        final cacheEntered = Completer<void>(),
            cacheRelease = Completer<void>();
        if (scenario == 'cached-refresh') {
          release.complete();
          await (thumbnail
              ? capability.loadThumbnail(original.eventId)
              : capability.loadAttachment(original.eventId));
          expect(requests, 1);
          paths.beforeRead = () async {
            if (!cacheEntered.isCompleted) cacheEntered.complete();
            await cacheRelease.future;
          };
        }
        final first = load();
        await (scenario == 'cached-refresh'
                ? cacheEntered.future
                : started.future)
            .timeout(const Duration(seconds: 5));
        if (![
          'baseline',
          'mutable-descriptor',
          'hidden',
          'account-change',
          'revoked',
          'disposed'
        ].contains(scenario)) {
          final update = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
          final content = update['content'] as Map<String, dynamic>;
          final file = thumbnail
              ? (content['info'] as Map)['thumbnail_file'] as Map
              : content['file'] as Map;
          switch (scenario) {
            case 'descriptor-url':
              file['url'] = 'mxc://example.test/replaced';
            case 'descriptor-key':
              (file['key'] as Map)['k'] = 'changed-key';
            case 'descriptor-iv':
              file['iv'] = 'changed-iv';
            case 'descriptor-hash':
              (file['hashes'] as Map)['sha256'] = 'changed-hash';
            case 'content-hash':
              (content['chatflow_media'] as Map)[
                  thumbnail ? 'thumbnail_sha256' : 'content_sha256'] = '0' * 64;
            case 'sender':
              update['sender'] = '@other:example.test';
            case 'room-envelope':
              (update['original_source'] as Map)['content']['session_id'] =
                  'other-session';
            case 'room-envelope-sender':
              (update['original_source'] as Map)['sender'] =
                  '@other:example.test';
            case 'redaction':
              update['unsigned'] = {
                'redacted_because': {
                  'event_id': r'$synthetic-redaction',
                  'type': EventTypes.Redaction,
                  'sender': '@peer:example.test',
                  'content': {},
                },
              };
            default:
              // A legitimate refresh can differ in unsigned age and map order.
              update['unsigned'] = {'age': 42};
              update['content'] = Map<String, dynamic>.fromEntries(
                  content.entries.toList().reversed);
          }
          client.onEvent.add(EventUpdate(
              roomID: room.id,
              type: EventUpdateType.timeline,
              content: update));
          await Future<void>.delayed(Duration.zero);
          expect(
              identical(room.fixtureTimeline.events.first, original), isFalse);
          if (['identical-refresh', 'cached-refresh'].contains(scenario)) {
            final refreshed = room.fixtureTimeline.events.first;
            expect(refreshed.content, original.content);
            expect(refreshed.originalSource?.content,
                original.originalSource?.content);
            expect(refreshed.senderId, original.senderId);
            expect(refreshed.type, original.type);
            expect(refreshed.originServerTs, original.originServerTs);
            expect(
                refreshed.originalSource?.type, original.originalSource?.type);
            expect(identical(refreshed.room, original.room), isTrue);
            expect(refreshed.redacted, isFalse);
          }
        } else if (scenario == 'mutable-descriptor') {
          final file = thumbnail
              ? (original.content['info'] as Map)['thumbnail_file'] as Map
              : original.content['file'] as Map;
          (file['key'] as Map)['k'] = 'mutated-in-place';
        } else if (scenario == 'hidden') {
          (capability as RoomWindowedTimelineSource)
              .setHiddenFilter((_, __) => true);
        } else if (scenario == 'account-change') {
          client.account = '@other:example.test';
        } else if (scenario == 'revoked') {
          client.recoveryOwner!.revoke();
        } else if (scenario == 'disposed') {
          capability.dispose();
        }
        if (!release.isCompleted) release.complete();
        if (!cacheRelease.isCompleted) cacheRelease.complete();
        await first;
        final failed =
            thumbnail ? thumbnailFailed : playback.hasFailed(original.eventId);
        final allowed = ['baseline', 'identical-refresh', 'cached-refresh']
            .contains(scenario);
        expect(failed, !allowed);
        expect(engine.playCalls, !thumbnail && allowed ? 1 : 0);
        expect(requests, 1);
      });
    }
  }
}
