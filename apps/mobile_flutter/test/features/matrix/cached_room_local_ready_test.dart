import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

class _Client extends Client {
  _Client(this.store) : super('cached-local-ready');
  final MatrixSdkDatabase store;
  @override
  DatabaseApi get database => store;
  @override
  String get userID => '@cached:synthetic.test';
  late final room = _Room(client: this);
  @override
  Room? getRoomById(String roomId) => roomId == room.id ? room : null;
}

class _Room extends Room {
  _Room({required super.client}) : super(id: '!cached:synthetic.test');
  final postLoadEntered = Completer<void>();
  final releasePostLoad = Completer<void>();
  @override
  Future<void> postLoad() async {
    if (!postLoadEntered.isCompleted) postLoadEntered.complete();
    await releasePostLoad.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(SQfLiteEncryptionHelper.ffiInit);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final retire in [false, true]) {
    test('SQLCipher cached head precedes SDK postLoad; retire=$retire',
        () async {
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final sql = await factory.openDatabase(inMemoryDatabasePath);
      final db = MatrixSdkDatabase('cached-local-ready',
          database: sql, sqfliteFactory: factory);
      await db.open();
      final client = _Client(db);
      final room = client.room;
      final owner = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://synthetic.test'),
          readContinuityMetadata: (_) async =>
              const MatrixClientContinuityMetadata(
                  isLoggedIn: false,
                  userId: '@cached:synthetic.test',
                  deviceId: null,
                  ed25519Fingerprint: 'synthetic',
                  databaseGeneration: 'synthetic'));
      for (var i = 0; i < 80; i++) {
        await db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': 'cached-$i',
                  'type': EventTypes.Message,
                  'sender': '@peer:synthetic.test',
                  'origin_server_ts': 1000 + i,
                  'content': {
                    'msgtype': MessageTypes.Text,
                    'body': 'cached body $i'
                  },
                }),
            client);
      }
      final lease = await owner.openRoomLease(room.id);
      var hydrated = false;
      final timeline = await lease.openLogicalRoomTimeline(
          cachedFirst: true,
          onHydrated: () => hydrated = true,
          onUpdate: () {});
      await room.postLoadEntered.future;
      expect(hydrated, isFalse);
      // Production installs this authoritative callback. Even an allow result
      // cannot send from missing encryption state while postLoad is held.
      owner.authorizeRoomSend = (_, __, ___) async => true;
      await expectLater(
          timeline.sendText('must never be plaintext'), throwsStateError);
      expect(timeline.snapshot(), hasLength(40));
      expect(timeline.snapshot().last.text, 'cached body 79');
      if (retire) lease.revokeNow();
      room.releasePostLoad.complete();
      for (var i = 0; i < 20 && !hydrated && !retire; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (retire) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(hydrated, isFalse);
        expect(() => timeline.snapshot(), throwsStateError);
      } else {
        expect(hydrated, isTrue);
        expect(timeline.snapshot().last.text, 'cached body 79');
      }
      timeline.dispose();
      await lease.cancel();
      await client.dispose();
      await db.close();
    });
  }
}
