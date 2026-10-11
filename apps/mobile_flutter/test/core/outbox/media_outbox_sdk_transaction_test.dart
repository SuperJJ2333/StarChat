import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/media_outbox_sender.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_recovery_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Actual sendFileEvent -> sendEvent -> generated HTTP sendMessage API. Matrix
// session/group encryption and local echo DB are doubles; attachment encryption
// is real. All HTTP terminates at MockClient, never a Matrix/network server.
class _SdkClient extends Client {
  _SdkClient(http.Client httpClient)
      : super('synthetic-outbox',
            httpClient: httpClient, sendTimelineEventTimeout: Duration.zero) {
    homeserver = Uri.parse('https://synthetic.invalid');
    accessToken = 'synthetic-fixture-token';
  }
  @override
  String? get userID => '@synthetic:test';
  @override
  String? get deviceID => 'SYNTHETIC';
  @override
  bool get fileEncryptionEnabled => true;
  @override
  Future<MediaConfig> getConfig() async => MediaConfig(mUploadSize: 1000000);
  @override
  Future<void> handleSync(SyncUpdate update, {Direction? direction}) async {}
  late final room = _EncryptedRoom(this);
  @override
  Room? getRoomById(String id) => id == room.id ? room : null;
}

class _EncryptedRoom extends Room {
  _EncryptedRoom(Client client) : super(id: '!synthetic:test', client: client);
  @override
  bool get encrypted => true;
  @override
  Membership get membership => Membership.join;
  @override
  bool get canSendDefaultMessages => true;
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final video in [false, true]) {
    test(
        'production sender real SDK ACK-loss retry preserves ${video ? 'prepared video' : 'image as file'} and txid',
        () async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      final root = await Directory.systemTemp.createTemp('media-sdk-tx-');
      PathProviderPlatform.instance = _Paths(root.path);
      var compressCalls = 0;
      const videoChannel = MethodChannel('video_compress');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(videoChannel, (call) async {
        if (call.method == 'compressVideo') compressCalls++;
        return null;
      });
      const owner = MediaOutboxOwner(
          accountId: '@synthetic:test',
          homeserver: 'https://synthetic.invalid',
          generation: 'db');
      SqliteMediaOutboxStore open() => SqliteMediaOutboxStore(
          owner: owner,
          directory: () async => root,
          availableBytes: () async => 1 << 30,
          seal: (_, __) async {});
      var store = open();
      var clock = DateTime.utc(2026, 10, 11);
      final requests = <Uri>[];
      final eventByTransaction = <String, String>{};
      var uploads = 0;
      var first = true;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/upload')) {
          uploads++;
          expect(request.bodyBytes, isNot([1, 2, 3, 4]));
          return http.Response(
              jsonEncode({'content_uri': 'mxc://synthetic/$uploads'}), 200,
              headers: {'content-type': 'application/json'});
        }
        if (request.url.path.contains('/send/')) {
          expect(request.method, 'PUT');
          final content = jsonDecode(request.body) as Map;
          expect(content['msgtype'], video ? 'm.video' : 'm.file');
          expect(content['file'], isA<Map>());
          expect(content['url'], isNull);
          requests.add(request.url);
          final event = eventByTransaction.putIfAbsent(
              request.url.path, () => r'$one-event');
          if (first) {
            first = false;
            throw const SocketException('synthetic ACK loss');
          }
          return http.Response(jsonEncode({'event_id': event}), 200,
              headers: {'content-type': 'application/json'});
        }
        throw StateError('unexpected synthetic endpoint ${request.url.path}');
      });
      final client = _SdkClient(transport);
      final room = client.room;
      final matrix = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse(owner.homeserver),
          suspendClient: (_) async {},
          readContinuityMetadata: (active) async =>
              MatrixClientContinuityMetadata(
                  isLoggedIn: true,
                  userId: active.userID,
                  deviceId: active.deviceID,
                  ed25519Fingerprint: 'synthetic',
                  databaseGeneration: 'db'));
      Future<String> send(MediaOutboxTask task, File source) =>
          sendPersistedMedia(matrix, task, source, current: () => true);
      try {
        final task = await store.persistBytes(
            txid: 'fixed/transaction',
            roomId: room.id,
            bytes: video
                ? Uint8List.fromList([1, 2, 3, 4])
                : base64Decode(
                    'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'),
            mimeType: video ? 'video/mp4' : 'image/gif',
            filename: video ? 'synthetic.mp4' : 'synthetic.gif',
            prepared: true,
            asFile: !video,
            durationMs: video ? 2500 : null);
        final before = MediaOutboxRecoveryService(
            store: store,
            isCurrentOwner: () => true,
            authorize: (_) async => true,
            send: send,
            now: () => clock);
        await expectLater(
            before.dispatch(task), throwsA(isA<SocketException>()));
        before.dispose();
        await store.close();
        store = open();
        clock = clock.add(const Duration(seconds: 3));
        final after = MediaOutboxRecoveryService(
            store: store,
            isCurrentOwner: () => true,
            authorize: (_) async => true,
            send: send,
            now: () => clock);
        await after.recover(waitForSettlement: true);
        expect((await store.byTxid(task.txid))!.eventId, r'$one-event');
        expect(uploads, 2);
        expect(requests, hasLength(2));
        expect(requests.first, requests.last);
        expect(requests.first.pathSegments.last, 'fixed/transaction');
        expect(eventByTransaction, hasLength(1));
        expect(compressCalls, 0);
        after.dispose();
      } finally {
        await store.close();
        await client.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(videoChannel, null);
        await root.delete(recursive: true);
      }
    });
  }
}
