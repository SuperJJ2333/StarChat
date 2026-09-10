import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/client_init_exception.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('store retention is opt in for upstream callers', () async {
    final client = Client('default');
    expect(client.preserveStoreOnInvalidToken, isFalse);
    await client.dispose();
  });

  for (final preserve in [true, false]) {
    for (final softLogout in [false, true]) {
      test('invalid token preserve=$preserve softLogout=$softLogout', () async {
        final root = Directory(
            '../../docs/verification/artifacts/2026-09-10/chat-reliability-2084/accounts/sdk');
        await root.create(recursive: true);
        final temp = await root.createTemp('token-');
        final path = '${temp.absolute.path}/matrix.sqlite';
        final sqlite = await databaseFactoryFfi.openDatabase(path);
        final database = MatrixSdkDatabase(path,
            database: sqlite, sqfliteFactory: databaseFactoryFfi);
        await database.open();
        var syncCalls = 0;
        var rejectedRequests = 0;
        final client = Client('fixture',
            preserveStoreOnInvalidToken: preserve,
            databaseBuilder: (_) async => database,
            httpClient: MockClient((request) async {
              if (request.url.path.endsWith('/logout')) {
                return http.Response('{}', 200,
                    headers: {'content-type': 'application/json'});
              }
              if (request.url.path.endsWith('/sync')) {
                syncCalls++;
              } else {
                rejectedRequests++;
              }
              return http.Response(
                  jsonEncode({
                    'errcode': 'M_UNKNOWN_TOKEN',
                    'error': 'synthetic revoked session',
                    'soft_logout': softLogout,
                  }),
                  401,
                  headers: {'content-type': 'application/json'});
            }))
          ..backgroundSync = false
          ..syncErrorTimeoutSec = 0;
        try {
          // Initialize a real SDK store without logging in/creating an Olm account.
          await client.init();
          const opaqueState = '{"fixture":"encrypted-session-state"}';
          await sqlite.insert('box_inbound_group_session',
              {'k': 'fixture-key', 'v': opaqueState});
          await database.insertClient(
              'fixture',
              'https://matrix.example.test',
              'synthetic-revoked-token',
              null,
              null,
              '@fixture:example.test',
              'EXISTING-DEVICE',
              'fixture device',
              'retained-sync-cursor',
              'sealed-olm-fixture');
          client.homeserver = Uri.parse('https://matrix.example.test');
          client.accessToken = 'synthetic-revoked-token';
          await client.oneShotSync();
          expect(syncCalls, 1);
          expect(client.isLogged(), isFalse);
          if (preserve) {
            expect(client.onLoginStateChanged.value, LoginState.softLoggedOut);
            expect(client.database, same(database));
            expect(await File(path).exists(), isTrue);
            expect(
                (await sqlite.query('box_inbound_group_session')).single['v'],
                opaqueState);
            expect((await database.getClient('fixture'))?['prev_batch'],
                'retained-sync-cursor');
            await client.oneShotSync();
            expect(syncCalls, 1,
                reason: 'invalid credentials cannot restart sync');
            await expectLater(
                client.getAccountData('@fixture:example.test', 'm.test'),
                throwsA(isA<TypeError>()));
            expect(rejectedRequests, 0,
                reason:
                    'SDK required-token guard refuses request before transport');
            await client.init(
                newToken: 'synthetic-new-token',
                newHomeserver: Uri.parse('https://matrix.example.test'),
                newUserID: '@fixture:example.test',
                newDeviceID: 'EXISTING-DEVICE',
                newDeviceName: 'fixture device');
            final restored = await database.getClient('fixture');
            expect(restored?['token'], 'synthetic-new-token',
                reason:
                    'same-device reauthentication must persist without refresh token');
            expect(restored?['olm_account'], 'sealed-olm-fixture');
            expect(restored?['prev_batch'], 'retained-sync-cursor');
            expect(restored?['device_id'], 'EXISTING-DEVICE');
            await sqlite.execute(
                "CREATE TRIGGER fail_token_write BEFORE INSERT ON box_client WHEN NEW.k = 'token' BEGIN SELECT RAISE(ABORT, 'synthetic credential write failure'); END");
            client.onLoginStateChanged.add(LoginState.softLoggedOut);
            final errors = client.onLoginStateChanged.stream
                .listen((_) {}, onError: (Object _) {});
            try {
              await expectLater(
                  client.init(
                      newToken: 'synthetic-second-token',
                      newHomeserver: Uri.parse('https://matrix.example.test'),
                      newUserID: '@fixture:example.test',
                      newDeviceID: 'EXISTING-DEVICE',
                      newDeviceName: 'fixture device'),
                  throwsA(isA<ClientInitException>()));
              expect(await File(path).exists(), isTrue,
                  reason: 'credential write failure must preserve the store');
              expect(client.database, same(database));
              expect(client.isLogged(), isFalse);
              expect(
                  client.onLoginStateChanged.value, LoginState.softLoggedOut);
              expect((await database.getClient('fixture'))?['olm_account'],
                  'sealed-olm-fixture');
            } finally {
              await errors.cancel();
            }
            expect(
                (await sqlite.query('box_inbound_group_session')).single['v'],
                opaqueState);
          } else {
            expect(client.onLoginStateChanged.value, LoginState.loggedOut);
            expect(client.database, isNull);
            expect(await File(path).exists(), isFalse);
          }
        } finally {
          await client.dispose();
          if (await temp.exists()) await temp.delete(recursive: true);
        }
      });
    }
  }
}
