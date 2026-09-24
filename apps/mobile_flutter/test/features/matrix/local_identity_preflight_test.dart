import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;

final class _RecordingSecureStore implements SecureKeyValueStore {
  final values = <String, String>{};
  var writes = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

final class _IdentityReader implements MatrixLocalIdentityReader {
  final records = <String, MatrixLocalIdentityRecord>{};
  final unreadable = <String>{};
  var reads = 0;

  @override
  Future<bool> exists(String databasePath) async =>
      records.containsKey(databasePath.replaceAll('\\', '/')) ||
      unreadable.contains(databasePath.replaceAll('\\', '/'));

  @override
  Future<MatrixLocalIdentityRecord> read(
      String databasePath, String cipher) async {
    reads++;
    final path = databasePath.replaceAll('\\', '/');
    if (unreadable.contains(path)) throw StateError('synthetic read');
    return records[path]!;
  }
}

MatrixLocalIdentityPreflight _preflight(_IdentityReader reader) =>
    MatrixLocalIdentityPreflight(
      reader: reader,
      fingerprintReader: (_, pickle) async => pickle,
    );

MatrixLocalBinding _binding() => MatrixLocalBinding(
      version: 2,
      matrixUserId: '@old:matrix.test',
      deviceId: 'OLD-DEVICE',
      homeserver: 'https://matrix.test',
      databaseGeneration: 'original-generation',
      ed25519Fingerprint: 'original-fingerprint',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iOS Keychain inspection uses native peek for every identity item',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('chatflow/ios_secure_session');
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      final key = (call.arguments as Map)['key'] as String;
      if (key == 'liuhetong.matrix_local_binding.v1') {
        return jsonEncode(_binding().toJson());
      }
      if (key == 'liuhetong.matrix_database_key.v1') return 'existing-key';
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final snapshot = await SecureSessionStore(FlutterSecureKeyValueStore())
        .peekActiveMatrixIdentity();

    expect(snapshot.binding, _binding());
    expect(snapshot.databaseKey, 'existing-key');
    expect(methods, isNotEmpty);
    expect(methods, everyElement('peek'));
  });

  test('read-only probe accepts matching Olm identity and legacy DB URL',
      () async {
    final reader = _IdentityReader()
      ..records['/legacy.sqlite'] = const MatrixLocalIdentityRecord(
        hasRetainedData: true,
        matrixUserId: '@old:matrix.test',
        deviceId: 'ROTATED-DEVICE',
        olmAccount: 'original-fingerprint',
      );
    final result = await _preflight(reader).inspect(
      databasePath: '/legacy.sqlite',
      cipher: 'old-cipher',
      binding: _binding(),
      expectedHomeserver: 'https://matrix.test',
      expectedUserId: '@old:matrix.test',
    );
    expect(result.status, MatrixLocalIdentityStatus.verifiedRetained);
    expect(result.ed25519Fingerprint, 'original-fingerprint');
    expect(reader.reads, 1);
  });

  test('fingerprint mismatch is typed and never converted to a fresh login',
      () async {
    final reader = _IdentityReader()
      ..records['/retained.sqlite'] = const MatrixLocalIdentityRecord(
        hasRetainedData: true,
        matrixUserId: '@old:matrix.test',
        deviceId: 'OLD-DEVICE',
        olmAccount: 'different-fingerprint',
      );
    await expectLater(
      _preflight(reader).inspect(
        databasePath: '/retained.sqlite',
        cipher: 'old-cipher',
        binding: _binding(),
        expectedHomeserver: 'https://matrix.test',
      ),
      throwsA(isA<MatrixLocalIdentityPreflightException>()
          .having((error) => error.cause, 'cause',
              MatrixLocalIdentityCause.fingerprintMismatch)
          .having((error) => error.canCreateNewDevice, 'canCreateNewDevice',
              false)),
    );
  });

  test('retained credentials without Olm pickle are blocked', () async {
    final reader = _IdentityReader()
      ..records['/retained.sqlite'] = const MatrixLocalIdentityRecord(
        hasRetainedData: true,
        matrixUserId: '@old:matrix.test',
        deviceId: 'OLD-DEVICE',
      );
    await expectLater(
      _preflight(reader).inspect(
        databasePath: '/retained.sqlite',
        cipher: 'old-cipher',
        binding: _binding(),
        expectedHomeserver: 'https://matrix.test',
      ),
      throwsA(isA<MatrixLocalIdentityPreflightException>().having(
          (error) => error.cause,
          'cause',
          MatrixLocalIdentityCause.missingOlmAccount)),
    );
  });

  test('missing key and unreadable DB never look like a new installation',
      () async {
    final reader = _IdentityReader()
      ..records['/key-lost.sqlite'] = const MatrixLocalIdentityRecord(
        hasRetainedData: true,
        matrixUserId: '@old:matrix.test',
        olmAccount: 'original-fingerprint',
      )
      ..unreadable.add('/locked.sqlite');
    for (final (path, cipher, cause) in [
      ('/key-lost.sqlite', null, MatrixLocalIdentityCause.missingKey),
      ('/locked.sqlite', 'old-cipher', MatrixLocalIdentityCause.unreadable),
    ]) {
      await expectLater(
        _preflight(reader).inspect(
          databasePath: path,
          cipher: cipher,
          binding: _binding(),
          expectedHomeserver: 'https://matrix.test',
        ),
        throwsA(isA<MatrixLocalIdentityPreflightException>()
            .having((error) => error.cause, 'cause', cause)
            .having((error) => error.canCreateNewDevice, 'canCreateNewDevice',
                false)),
      );
    }
    expect(reader.reads, 1, reason: 'no DB query is allowed without a key');
  });

  test('missing retained DB stops create before key creation or SDK opener',
      () async {
    final storage = _RecordingSecureStore();
    final store = SecureSessionStore(storage);
    await store.saveMatrixBinding(_binding());
    final before = Map<String, String>.from(storage.values);
    final writesBefore = storage.writes;
    var openerCalls = 0;
    final factory = MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async =>
          '/missing-chatflow-preflight-${DateTime.now().microsecondsSinceEpoch}',
      opener: (
          {required clientName, required databasePath, required cipher}) async {
        openerCalls++;
        return Client(clientName);
      },
    );

    await expectLater(factory.create(), throwsA(isA<Exception>()));

    expect(openerCalls, 0);
    expect(storage.writes, writesBefore);
    expect(storage.values, before,
        reason: 'pre-init inspection must preserve the old Keychain material');
  });

  test('retained account selection checks target before changing active scope',
      () async {
    final storage = _RecordingSecureStore();
    final store = SecureSessionStore(storage);
    await store.selectMatrixAccount('https://matrix.test', '@old:matrix.test');
    await store.saveMatrixBinding(_binding());
    await store.matrixDatabaseKey();
    await store.selectMatrixAccount(
        'https://matrix.test', '@other:matrix.test');
    final before = Map<String, String>.from(storage.values);
    final writesBefore = storage.writes;
    final factory = MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async =>
          '/missing-chatflow-preflight-${DateTime.now().microsecondsSinceEpoch}',
    );

    await expectLater(
      factory.selectAccount('https://matrix.test', '@old:matrix.test'),
      throwsA(isA<Exception>()),
    );

    expect(storage.writes, writesBefore);
    expect(storage.values, before,
        reason: 'preflight must run before registry and active-scope writes');
  });

  test('no matching original enables an explicit new-device choice', () async {
    final reader = _IdentityReader();
    final storage = _RecordingSecureStore();
    final store = SecureSessionStore(storage);
    await store.selectMatrixAccount('https://matrix.test', '@old:matrix.test');
    await store.saveMatrixBinding(_binding());
    await store.matrixDatabaseKey();
    final scope = await store.matrixStorageScope();
    reader.records['/inventory/liuhetong_matrix_$scope.sqlite'] =
        const MatrixLocalIdentityRecord(
      hasRetainedData: true,
      matrixUserId: '@old:matrix.test',
      olmAccount: 'different-fingerprint',
    );
    final before = Map<String, String>.from(storage.values);
    final factory = MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/inventory',
      localIdentityPreflight: _preflight(reader),
      opener: (
              {required clientName,
              required databasePath,
              required cipher}) async =>
          Client(clientName),
    );

    await expectLater(
      factory.create(),
      throwsA(isA<MatrixLocalIdentityPreflightException>()
          .having((error) => error.cause, 'cause',
              MatrixLocalIdentityCause.fingerprintMismatch)
          .having(
              (error) => error.canCreateNewDevice, 'canCreateNewDevice', true)),
    );
    expect(storage.values, before);
  });

  test('verified original in legacy slot blocks new-device choice', () async {
    final reader = _IdentityReader();
    final storage = _RecordingSecureStore();
    final store = SecureSessionStore(storage);
    await store.selectMatrixAccount('https://matrix.test', '@old:matrix.test');
    await store.saveMatrixBinding(_binding());
    await store.matrixDatabaseKey();
    final scope = await store.matrixStorageScope();
    reader.records['/inventory/liuhetong_matrix_$scope.sqlite'] =
        const MatrixLocalIdentityRecord(
      hasRetainedData: true,
      matrixUserId: '@old:matrix.test',
      olmAccount: 'different-fingerprint',
    );
    storage.values['liuhetong.matrix_local_binding.v1'] =
        jsonEncode(_binding().toJson());
    storage.values['liuhetong.matrix_database_key.v1'] = 'original-cipher';
    reader.records['/inventory/liuhetong_matrix.sqlite'] =
        const MatrixLocalIdentityRecord(
      hasRetainedData: true,
      matrixUserId: '@old:matrix.test',
      olmAccount: 'original-fingerprint',
    );
    final factory = MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/inventory',
      localIdentityPreflight: _preflight(reader),
    );

    await expectLater(
      factory.create(),
      throwsA(isA<MatrixLocalIdentityPreflightException>()
          .having((error) => error.cause, 'cause',
              MatrixLocalIdentityCause.originalIdentityElsewhere)
          .having((error) => error.canCreateNewDevice, 'canCreateNewDevice',
              false)),
    );
  });

  test('two verified original candidates remain blocked and distinguishable',
      () async {
    final reader = _IdentityReader();
    final storage = _RecordingSecureStore();
    final store = SecureSessionStore(storage);
    await store.selectMatrixAccount('https://matrix.test', '@old:matrix.test');
    await store.saveMatrixBinding(_binding());
    await store.matrixDatabaseKey();
    final current = await store.matrixStorageScope();
    reader.records['/inventory/liuhetong_matrix_$current.sqlite'] =
        const MatrixLocalIdentityRecord(
      hasRetainedData: true,
      matrixUserId: '@old:matrix.test',
      olmAccount: 'different-fingerprint',
    );
    final registry =
        jsonDecode(storage.values['liuhetong.matrix_account_slots.v1']!)
            as Map<String, dynamic>;
    for (final letter in ['b', 'c']) {
      final scope = List.filled(64, letter).join();
      registry[scope] = scope;
      storage.values['liuhetong.matrix_local_binding.v1.$scope'] =
          jsonEncode(_binding().toJson());
      storage.values['liuhetong.matrix_database_key.v1.$scope'] =
          'cipher-$letter';
      reader.records['/inventory/liuhetong_matrix_$scope.sqlite'] =
          const MatrixLocalIdentityRecord(
        hasRetainedData: true,
        matrixUserId: '@old:matrix.test',
        olmAccount: 'original-fingerprint',
      );
    }
    storage.values['liuhetong.matrix_account_slots.v1'] = jsonEncode(registry);
    final factory = MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/inventory',
      localIdentityPreflight: _preflight(reader),
    );

    await expectLater(
      factory.create(),
      throwsA(isA<MatrixLocalIdentityPreflightException>()
          .having((error) => error.cause, 'cause',
              MatrixLocalIdentityCause.multipleCandidates)
          .having((error) => error.canCreateNewDevice, 'canCreateNewDevice',
              false)),
    );
  });

  test('unreadable candidate never enables new-device choice', () async {
    final reader = _IdentityReader();
    final storage = _RecordingSecureStore();
    final store = SecureSessionStore(storage);
    await store.selectMatrixAccount('https://matrix.test', '@old:matrix.test');
    await store.saveMatrixBinding(_binding());
    await store.matrixDatabaseKey();
    final current = await store.matrixStorageScope();
    reader.records['/inventory/liuhetong_matrix_$current.sqlite'] =
        const MatrixLocalIdentityRecord(
      hasRetainedData: true,
      matrixUserId: '@old:matrix.test',
      olmAccount: 'different-fingerprint',
    );
    final other = List.filled(64, 'b').join();
    final registry =
        jsonDecode(storage.values['liuhetong.matrix_account_slots.v1']!)
            as Map<String, dynamic>;
    registry[other] = other;
    storage.values['liuhetong.matrix_account_slots.v1'] = jsonEncode(registry);
    storage.values['liuhetong.matrix_local_binding.v1.$other'] =
        jsonEncode(_binding().toJson());
    storage.values['liuhetong.matrix_database_key.v1.$other'] = 'cipher-b';
    reader.unreadable.add('/inventory/liuhetong_matrix_$other.sqlite');
    final factory = MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/inventory',
      localIdentityPreflight: _preflight(reader),
    );

    await expectLater(
      factory.create(),
      throwsA(isA<MatrixLocalIdentityPreflightException>()
          .having((error) => error.cause, 'cause',
              MatrixLocalIdentityCause.unreadable)
          .having((error) => error.canCreateNewDevice, 'canCreateNewDevice',
              false)),
    );
  });

  test('fixed-name local DB absent from registry is included in inventory',
      () async {
    final evidenceRoot =
        Directory('../../docs/verification/artifacts/2026-09-24').absolute;
    await evidenceRoot.create(recursive: true);
    final directory = await evidenceRoot.createTemp('ios-preflight-fixture-');
    final unknown = List.filled(64, 'd').join();
    final candidateFile =
        File(p.join(directory.path, 'liuhetong_matrix_$unknown.sqlite'));
    await candidateFile.writeAsBytes(const [0]);
    try {
      final reader = _IdentityReader();
      final storage = _RecordingSecureStore();
      final store = SecureSessionStore(storage);
      await store.selectMatrixAccount(
          'https://matrix.test', '@old:matrix.test');
      await store.saveMatrixBinding(_binding());
      await store.matrixDatabaseKey();
      final current = await store.matrixStorageScope();
      reader.records[p
          .join(directory.path, 'liuhetong_matrix_$current.sqlite')
          .replaceAll('\\', '/')] = const MatrixLocalIdentityRecord(
        hasRetainedData: true,
        matrixUserId: '@old:matrix.test',
        olmAccount: 'different-fingerprint',
      );
      storage.values['liuhetong.matrix_local_binding.v1.$unknown'] =
          jsonEncode(_binding().toJson());
      storage.values['liuhetong.matrix_database_key.v1.$unknown'] =
          'original-cipher';
      reader.records[candidateFile.path.replaceAll('\\', '/')] =
          const MatrixLocalIdentityRecord(
        hasRetainedData: true,
        matrixUserId: '@old:matrix.test',
        olmAccount: 'original-fingerprint',
      );
      final factory = MatrixClientFactory(
        sessionStore: store,
        homeserver: Uri.parse('https://matrix.test'),
        supportDirectoryPath: () async => directory.path,
        localIdentityPreflight: _preflight(reader),
      );

      await expectLater(
        factory.create(),
        throwsA(isA<MatrixLocalIdentityPreflightException>().having(
            (error) => error.cause,
            'cause',
            MatrixLocalIdentityCause.originalIdentityElsewhere)),
      );
    } finally {
      await candidateFile.delete();
      await directory.delete();
    }
  });
}
