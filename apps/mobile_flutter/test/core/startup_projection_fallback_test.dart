import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection_store.dart';
import 'package:liuhetong_mobile/features/matrix/local_hidden_events.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

class _Secure implements SecureKeyValueStore {
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

class _Client extends Client {
  _Client() : super('no-database-capture');
  @override
  bool isLogged() => true;
  @override
  String get userID => '@synthetic:test';
  @override
  String get deviceID => 'SYNTHETIC';
  final localRooms = <Room>[];
  @override
  List<Room> get rooms => localRooms;
}

class _Timeline extends Timeline {
  _Timeline(Room room, List<Event> events)
      : super(room: room, chunk: TimelineChunk(events: events));
  int cancellations = 0;
  @override
  void cancelSubscriptions() {
    cancellations++;
    super.cancelSubscriptions();
  }
}

class _Room extends Room {
  _Room(Client client) : super(id: '!synthetic:test', client: client) {
    setState(Event(
        room: this,
        eventId: 'authority',
        type: EventTypes.RoomPowerLevels,
        stateKey: '',
        senderId: client.userID!,
        originServerTs: DateTime.utc(2026),
        content: {
          'events': {
            'com.changliao.group.settings': 50,
            'com.changliao.group.announcement': 50
          }
        }));
  }
  @override
  String get name => 'Synthetic room';
  int timelineCalls = 0;
  late _Timeline captured;
  @override
  Future<Timeline> getTimeline(
      {void Function(int)? onChange,
      void Function(int)? onRemove,
      void Function(int)? onInsert,
      void Function()? onNewEvent,
      void Function()? onUpdate,
      String? eventContextId}) async {
    timelineCalls++;
    return captured = _Timeline(this, [
      for (final id in ['visible', 'hidden', 'redacted'])
        Event.fromJson({
          'event_id': id,
          'type': EventTypes.Message,
          'sender': client.userID,
          'origin_server_ts': 100,
          'content': {'msgtype': 'm.text', 'body': 'Synthetic $id'},
          if (id == 'redacted')
            'unsigned': {
              'redacted_because': {
                'type': 'm.room.redaction',
                'event_id': 'redaction',
                'sender': client.userID,
                'origin_server_ts': 101,
                'content': {}
              }
            },
        }, this),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('no database capture retains timeline fallback and privacy filtering',
      () async {
    SharedPreferences.setMockInitialValues({});
    final root = Directory(
            '../../docs/verification/artifacts/2026-10-18/room-entry-readiness/fixtures')
        .absolute;
    await root.create(recursive: true);
    final directory = await root.createTemp('no-db-');
    final client = _Client();
    final room = _Room(client);
    client.localRooms.add(room);
    final secure = SecureSessionStore(_Secure());
    await secure.matrixDatabaseKey();
    await secure.registrationDeviceKey();
    await secure.saveSession(
        accessToken: 'synthetic',
        refreshToken: 'synthetic',
        matrixUserId: client.userID);
    await secure.saveMatrixBinding(MatrixLocalBinding(
        version: 2,
        matrixUserId: client.userID,
        deviceId: client.deviceID,
        homeserver: 'https://synthetic.test',
        databaseGeneration: 'generation',
        ed25519Fingerprint: 'fingerprint'));
    final history = SharedPreferencesLocalHiddenEvents(
        preferences: await SharedPreferences.getInstance(),
        accountId: client.userID,
        mutationGuard: (apply) => apply());
    await history.hide(room.id, 'hidden');
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://synthetic.test'),
        secureSessionStore: secure,
        readContinuityMetadata: (_) async => MatrixClientContinuityMetadata(
            isLoggedIn: true,
            userId: client.userID,
            deviceId: client.deviceID,
            ed25519Fingerprint: 'fingerprint',
            databaseGeneration: 'generation'));
    try {
      expect(client.database, isNull);
      final cache = StartupProjectionStore(directory);
      await owner.primeStartupProjection(cache);
      final admission = await secure
          .readStartupProjectionAdmission((await cache.readInstallation())!);
      expect(admission, isNotNull);
      final projection = await cache.read(admission!);
      expect(projection!.rooms.single.events.map((e) => e.body),
          ['Synthetic visible']);
      expect(room.timelineCalls, 1);
      expect(room.captured.cancellations, 1);
    } finally {
      await owner.suspend();
      await directory.delete(recursive: true);
    }
  });
}
