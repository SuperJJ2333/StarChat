import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:matrix/matrix.dart';

final class MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override Future<void> delete(String key) async => values.remove(key);
  @override Future<String?> read(String key) async => values[key];
  @override Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  test('uses a stable encrypted database path and secure key', () async {
    final secureStore = SecureSessionStore(MemoryStore());
    String? openedName;
    String? openedPath;
    String? openedCipher;
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      supportDirectoryPath: () async => '/support',
      opener: ({required clientName, required databasePath, required cipher}) async {
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
}
