import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import '../../core/account_chat_store_test.dart' show binding;
import '../../core/session_store_test.dart' show MemorySecureKeyValueStore;
import 'matrix_client_factory_test.dart' show LogoutTrackingClient;

void main() {
  test('concurrent selections close each client before opening the next',
      () async {
    final a = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    final events = <String>[];
    var selected = '@a:test';
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (client) async {
          events.add('close:${client.userID}');
        },
        selectClientAccount: (_, user) async {
          selected = user;
        },
        resumeClient: () async {
          events.add('open:$selected');
          return LogoutTrackingClient(selected,
              loggedIn: true, matrixUserId: selected, matrixDeviceId: selected);
        },
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: client.isLogged(),
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'key-${client.userID}',
                databaseGeneration: 'db-${client.userID}'));
    await Future.wait([
      matrix.selectAccount('@b:test', Uri.parse('https://matrix.example')),
      matrix.selectAccount('@c:test', Uri.parse('https://matrix.example')),
    ]);
    expect(events,
        ['close:@a:test', 'open:@b:test', 'close:@b:test', 'open:@c:test']);
    expect(matrix.userId, '@c:test');
  });
  test('failed account reopen does not expose previous identity', () async {
    final a = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        resumeClient: () async => throw StateError('database unavailable'),
        selectClientAccount: (_, __) async {},
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: client.isLogged(),
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'fingerprint',
                databaseGeneration: 'generation'));
    await expectLater(
        matrix.selectAccount('@b:test', Uri.parse('https://matrix.example')),
        throwsStateError);
    expect(matrix.userId, isNull);
    expect(matrix.isLoggedIn, isFalse);
  });
  test('adapter switch suspends old client without invoking destructive clear',
      () async {
    final a = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    var suspended = 0;
    var cleared = 0;
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {
          suspended++;
        },
        clearClientData: (_) async {
          cleared++;
        },
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: client.isLogged(),
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'fingerprint',
                databaseGeneration: 'generation'));
    // No selector is configured: fail closed, retaining the old encrypted store.
    await expectLater(
        (matrix as dynamic)
            .selectAccount('@b:test', Uri.parse('https://matrix.example')),
        throwsStateError);
    expect(cleared, 0);
    expect(suspended, 0);
  });
  test(
      'adapter selects restored B and revokes old A capabilities without deletion',
      () async {
    final a = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    final b = LogoutTrackingClient('B',
        loggedIn: true, matrixUserId: '@b:test', matrixDeviceId: 'B');
    var closed = 0;
    var cleared = 0;
    String? selected;
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {
          closed++;
        },
        resumeClient: () async => b,
        selectClientAccount: (home, user) async {
          selected = user;
        },
        clearClientData: (_) async {
          cleared++;
        },
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: client.isLogged(),
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'fingerprint-${client.userID}',
                databaseGeneration: 'generation-${client.userID}'));
    await matrix.selectAccount('@b:test', Uri.parse('https://matrix.example'));
    expect(closed, 1);
    expect(cleared, 0);
    expect(selected, '@b:test');
    expect(matrix.userId, '@b:test');
    expect(matrix.deviceId, 'B');
    expect(matrix.credentialsInvalid, isTrue);
    await expectLater(matrix.openRoomLease('!old:test'), throwsStateError);
  });

  test(
      'factory reopens account-specific file and original legacy file unchanged',
      () async {
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    final opened = <({String path, String cipher})>[];
    final factory = MatrixClientFactory(
        sessionStore: store,
        homeserver: Uri.parse('https://matrix.example'),
        supportDirectoryPath: () async => '/private/support',
        clientMigrator: (_, __) async {},
        opener: (
            {required clientName,
            required databasePath,
            required cipher}) async {
          opened.add((path: databasePath, cipher: cipher));
          return LogoutTrackingClient('fixture');
        });
    await factory.create();
    await (factory as dynamic)
        .selectAccount('https://matrix.example', '@b:test');
    await factory.create();
    await (factory as dynamic)
        .selectAccount('https://matrix.example', '@a:test');
    await factory.create();
    expect(opened[0].path, endsWith('liuhetong_matrix.sqlite'));
    expect(opened[1].path, isNot(opened[0].path));
    expect(opened[1].cipher, isNot(opened[0].cipher));
    expect(opened[2], opened[0]);
  });
}
