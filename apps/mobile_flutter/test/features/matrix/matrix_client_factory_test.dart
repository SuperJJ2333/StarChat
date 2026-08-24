import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';

final class MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final class LogoutTrackingClient extends Client {
  LogoutTrackingClient(super.name);

  var logoutCalls = 0;

  @override
  Future<void> logout() async => logoutCalls++;
}

void main() {
  test('uses a stable encrypted database path and secure key', () async {
    final secureStore = SecureSessionStore(MemoryStore());
    String? openedName;
    String? openedPath;
    String? openedCipher;
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://liuhetong888.com'),
      supportDirectoryPath: () async => '/support',
      opener: (
          {required clientName, required databasePath, required cipher}) async {
        openedName = clientName;
        openedPath = databasePath.replaceAll('\\', '/');
        openedCipher = cipher;
        return Client(clientName);
      },
    );

    final client = await factory.create();

    expect(client.clientName, 'liuhetong_mobile');
    expect(openedName, 'liuhetong_mobile');
    expect(openedPath, '/support/liuhetong_matrix.sqlite');
    expect(openedCipher, isNotEmpty);
    expect(await secureStore.matrixDatabaseKey(), openedCipher);
  });

  test('migrates an existing client to the configured public homeserver',
      () async {
    final secureStore = SecureSessionStore(MemoryStore());
    Uri? migratedHomeserver;
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://liuhetong888.com'),
      supportDirectoryPath: () async => '/support',
      opener: (
          {required clientName, required databasePath, required cipher}) async {
        return Client(clientName);
      },
      clientMigrator: (client, homeserver) async {
        migratedHomeserver = homeserver;
      },
    );

    await factory.create();

    expect(migratedHomeserver, Uri.parse('https://liuhetong888.com'));
  });

  test('explicit logout resets the persistent client before it can be reused',
      () async {
    final original = LogoutTrackingClient('original');
    final replacement = LogoutTrackingClient('replacement');
    Client? resetArgument;
    final matrix = MatrixSdkE2eeClient(
      original,
      homeserver: Uri.parse('http://matrix.localhost'),
      resetClient: (client) async {
        resetArgument = client;
        return replacement;
      },
    );

    await matrix.logout();

    expect(original.logoutCalls, 1);
    expect(resetArgument, same(original));
    expect(matrix.sdkClient, same(replacement));
  });

  test('reset closes and deletes the old database and rotates its cipher key',
      () async {
    final values = <String, String>{};
    final secureStore =
        SecureSessionStore(MemoryStore()..values.addAll(values));
    final oldClient = LogoutTrackingClient('old');
    final newClient = LogoutTrackingClient('new');
    final events = <String>[];
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://liuhetong888.com'),
      supportDirectoryPath: () async => '/support',
      disposer: (client) async => events.add('dispose:${client.clientName}'),
      databaseDeleter: (path) async =>
          events.add('delete:${path.replaceAll('\\', '/')}'),
      opener: (
          {required clientName, required databasePath, required cipher}) async {
        events.add('open:$clientName');
        return newClient;
      },
    );
    final oldKey = await secureStore.matrixDatabaseKey();

    final reset = await factory.reset(oldClient);
    final newKey = await secureStore.matrixDatabaseKey();

    expect(reset, same(newClient));
    expect(events, [
      'dispose:old',
      'delete:/support/liuhetong_matrix.sqlite',
      'open:liuhetong_mobile',
    ]);
    expect(newKey, isNot(oldKey));
  });

  test(
      'suspend reopens encrypted Matrix storage without deleting database or key',
      () async {
    final secureStore = SecureSessionStore(MemoryStore());
    final oldClient = LogoutTrackingClient('old');
    final newClient = LogoutTrackingClient('new');
    final events = <String>[];
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://liuhetong888.com'),
      supportDirectoryPath: () async => '/support',
      disposer: (client) async => events.add('dispose:${client.clientName}'),
      opener: (
          {required clientName, required databasePath, required cipher}) async {
        events.add('open:$clientName');
        return newClient;
      },
    );
    final oldKey = await secureStore.matrixDatabaseKey();

    final reopened = await factory.reopen(oldClient);

    expect(reopened, same(newClient));
    expect(events, ['dispose:old', 'open:liuhetong_mobile']);
    expect(await secureStore.matrixDatabaseKey(), oldKey);
  });
}
