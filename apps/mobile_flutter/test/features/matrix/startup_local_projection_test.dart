import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:olm/olm.dart' as olm;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';

class HeldStartupDatabase extends MatrixSdkDatabase {
  HeldStartupDatabase(super.name, {super.database, super.sqfliteFactory});
  final entered = Completer<void>();
  final release = Completer<void>();
  bool fail = false;
  bool fullRead = false;
  @override
  Future<List<Room>> getCachedRoomList(Client client) {
    fullRead = true;
    return super.getCachedRoomList(client);
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
    if (fail) throw StateError("synthetic full recovery failure");
    return super.getUserDeviceKeys(client);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    'ready',
    'failure',
    'disposed',
    'identity',
    'frame',
    'ordinary',
    'empty'
  ]) {
    test('staged encrypted startup lifecycle: $scenario', () async {
      await olm.init();
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final sql = await factory.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(onConfigure: (db) async {
        await db.execute("PRAGMA key = 'synthetic-startup-fixture'");
      }));
      final db = HeldStartupDatabase('startup-fixture',
          database: sql, sqfliteFactory: factory);
      await db.open();
      final account = olm.Account()..create();
      await db.insertClient(
          'startup-fixture',
          'https://synthetic.test',
          'synthetic-token',
          null,
          null,
          '@startup:synthetic.test',
          'SYNTHETIC',
          'fixture',
          null,
          account.pickle('@startup:synthetic.test'));
      account.free();
      final client = Client('startup-fixture',
          databaseBuilder: (_) async => db,
          preserveStoreOnInvalidToken: true,
          httpClient: MockClient((_) async => http.Response('{}', 404)))
        ..backgroundSync = false;
      for (var i = 0; i < (scenario == 'empty' ? 0 : 65); i++) {
        final room = Room(id: '!room-$i:synthetic.test', client: client);
        room.lastEvent = Event(
            room: room,
            eventId: 'event-$i',
            type: EventTypes.Message,
            senderId: '@startup:synthetic.test',
            originServerTs: DateTime.fromMillisecondsSinceEpoch(i + 1),
            content: {'msgtype': 'm.text', 'body': 'cached $i'});
        await sql.insert(
            'box_rooms', {'k': room.id, 'v': jsonEncode(room.toJson())});
      }
      const target = '!room-64:synthetic.test';
      Future<void> state(String type, Map<String, Object> content) =>
          sql.insert('box_preload_room_states', {
            'k': '$target|$type',
            'v': jsonEncode({
              '': {
                'type': type,
                'state_key': '',
                'event_id': 'state-$type',
                'sender': '@startup:synthetic.test',
                'origin_server_ts': 1,
                'content': content
              }
            })
          }).then((_) {});
      if (scenario != 'empty') {
        await state(EventTypes.RoomName, {'name': 'persisted'});
        await state(
            EventTypes.RoomAvatar, {'url': 'mxc://synthetic.test/avatar'});
        await sql.insert('box_preload_room_states', {
          'k': '$target|${EventTypes.SpaceChild}',
          'v': jsonEncode({
            for (var n = 0; n < 2000; n++)
              '!child-$n:test': {
                'type': EventTypes.SpaceChild,
                'state_key': '!child-$n:test',
                'event_id': 'child-$n',
                'sender': '@startup:synthetic.test',
                'origin_server_ts': 1,
                'content': {
                  'via': ['test']
                }
              }
          })
        });
        for (final type in [
          'm.tag',
          'synthetic.optional',
          'com.liuhetong.conversation.settings.v2'
        ]) {
          await sql.insert('box_room_account_data', {
            'k': '$target|$type',
            'v': jsonEncode({
              'type': type,
              'content': {'hidden': true}
            })
          });
        }
      }
      final frame = Completer<void>();
      var returned = false;
      final startup = (scenario == 'ordinary'
              ? MatrixClientFactory.initializeClient(client)
              : MatrixClientFactory.initializeStartupClient(client,
                  resumeBackground: scenario == 'frame' ? frame.future : null))
          .then((_) {
        returned = true;
      });
      if (scenario == 'frame') {
        await startup;
        expect(db.entered.isCompleted, isFalse);
        expect(db.fullRead, isFalse);
        frame.complete();
      }
      await db.entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      if (scenario == 'ordinary' || scenario == 'empty') {
        expect(returned, isFalse);
        db.release.complete();
        await startup;
        if (db.fullRead) await db.previewSettled.future;
        await client.dispose();
        return;
      }
      expect(returned, isTrue,
          reason: 'local projection must not await full recovery');
      expect(client.rooms.length, 40);
      expect(client.rooms.first.id, '!room-64:synthetic.test');
      expect(db.fullRead, isFalse);
      final retained = client.rooms.first;
      expect(retained.getState(EventTypes.SpaceChild, '!child-1:test'), isNull,
          reason:
              'aggregated space maps are excluded from bounded singleton projection');
      expect(
          retained.roomAccountData['com.liuhetong.conversation.settings.v2']
              ?.content['hidden'],
          isTrue);
      if (scenario == 'ready') {
        retained.setState(Event(
            room: retained,
            type: EventTypes.RoomName,
            stateKey: '',
            content: {'name': 'local mutation'},
            eventId: 'local-name',
            senderId: '@startup:synthetic.test',
            originServerTs: DateTime.now()));
        retained.states[EventTypes.RoomAvatar]?.remove('');
        retained.roomAccountData.remove('m.tag');
        client.rooms
            .removeWhere((room) => room.id == '!room-62:synthetic.test');
        client.rooms.add(Room(id: '!created:synthetic.test', client: client));
        await sql.delete('box_rooms',
            where: 'k = ?', whereArgs: ['!room-63:synthetic.test']);
      }
      if (scenario == 'failure') db.fail = true;
      if (scenario == 'disposed') await client.dispose(closeDatabase: false);
      if (scenario == 'identity') client.setUserId('@other:synthetic.test');
      final completion = expectLater(
          client.initializationCompleted,
          scenario == 'failure' ||
                  scenario == 'disposed' ||
                  scenario == 'identity'
              ? throwsA(anyOf(isA<Exception>(), isA<StateError>()))
              : completes);
      db.release.complete();
      await completion;
      if (scenario == 'ready' || scenario == 'frame') {
        expect(client.rooms.length, scenario == 'ready' ? 64 : 65);
        if (scenario == 'ready') {
          expect(retained.name, 'local mutation');
          expect(retained.getState(EventTypes.RoomAvatar), isNull);
          expect(retained.roomAccountData.containsKey('m.tag'), isFalse);
          expect(retained.roomAccountData.containsKey('synthetic.optional'),
              isTrue);
          expect(retained.getState(EventTypes.SpaceChild, '!child-1:test'),
              isNotNull);
          expect(client.getRoomById('!created:synthetic.test'), isNotNull);
          expect(client.getRoomById('!room-62:synthetic.test'), isNull);
          expect(client.getRoomById('!room-63:synthetic.test'), isNull);
        }
        expect(client.getRoomById(retained.id), same(retained));
        // Let optional bounded preview repair settle before closing its store.
        await db.previewSettled.future;
      } else {
        expect(db.fullRead, isFalse,
            reason: 'revoked continuation cannot merge rooms');
      }
      await client.dispose();
      if (scenario == 'disposed') await db.close();
    });
  }
}
