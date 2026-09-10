import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import '../../core/account_chat_store_test.dart' show binding;
import '../../core/session_store_test.dart' show MemorySecureKeyValueStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test(
      'real disk timelines survive A B A reopen and repeated offline event delivery',
      () async {
    final evidence = Directory(
        '../../docs/verification/artifacts/2026-09-10/chat-reliability-2084/accounts/disk');
    await evidence.create(recursive: true);
    final root = await evidence.createTemp('histories-');
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    late MatrixSdkDatabase db;
    final paths = <String>[];
    final factory = MatrixClientFactory(
        sessionStore: store,
        homeserver: Uri.parse('https://matrix.example'),
        supportDirectoryPath: () async => root.absolute.path,
        clientMigrator: (_, __) async {},
        opener: (
            {required clientName,
            required databasePath,
            required cipher}) async {
          paths.add(databasePath);
          // SQLite exercises SDK persistence; SQLCipher/keychain are covered separately.
          db = MatrixSdkDatabase(databasePath,
              database: await databaseFactoryFfi.openDatabase(databasePath),
              sqfliteFactory: databaseFactoryFfi);
          await db.open();
          return Client(clientName);
        });
    Future<void> deliver(Client client, String id, int order) =>
        db.storeEventUpdate(
            EventUpdate(
                roomID: '!fixture:test',
                type: EventUpdateType.timeline,
                content: {
                  'event_id': id,
                  'type': 'm.room.encrypted',
                  'sender': '@fixture:test',
                  'origin_server_ts': order,
                  'content': {
                    'algorithm': 'm.megolm.v1.aes-sha2',
                    'ciphertext': 'synthetic-$id'
                  },
                }),
            client);
    Future<List<String>> timeline(Client client) async =>
        (await db.getEventList(Room(id: '!fixture:test', client: client)))
            .map((e) => e.eventId)
            .toList();
    Future<void> close(Client client) async {
      await db.close();
      await client.dispose();
    }

    var client = await factory.create();
    await deliver(client, r'$A-old', 1);
    await close(client);
    await factory.selectAccount('https://matrix.example', '@b:test');
    client = await factory.create();
    expect(await timeline(client), isEmpty);
    await deliver(client, r'$B-old', 2);
    await store.saveMatrixBinding(binding('@b:test', 'device-B'));
    await close(client);
    await factory.selectAccount('https://matrix.example', '@a:test');
    client = await factory.create();
    expect(await timeline(client), [r'$A-old']);
    await deliver(client, r'$A-offline-1', 3);
    await deliver(client, r'$A-offline-2', 4);
    await deliver(client, r'$A-offline-1', 3);
    expect(
        await timeline(client), [r'$A-offline-2', r'$A-offline-1', r'$A-old']);
    await close(client);
    await factory.selectAccount('https://matrix.example', '@b:test');
    client = await factory.create();
    expect(await timeline(client), [r'$B-old']);
    await close(client);
    expect(paths[0], paths[2]);
    expect(paths[1], paths[3]);
    expect(paths[0], isNot(paths[1]));
    for (final path in paths.toSet()) {
      await databaseFactoryFfi.deleteDatabase(path);
    }
    await root.delete();
  });
}
