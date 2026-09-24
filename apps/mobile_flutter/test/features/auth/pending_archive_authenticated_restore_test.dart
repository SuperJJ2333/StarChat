import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/matrix_startup_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:matrix/matrix.dart';

const _homeserver = 'https://matrix.test';
const _userId = '@old:matrix.test';
const _journalKey = 'liuhetong.matrix_archive_journal.v1';
const _archiveIndexKey = 'liuhetong.matrix_archives.v1';
const _oldDatabaseKey = 'liuhetong.matrix_database_key.v1';
const _oldBindingKey = 'liuhetong.matrix_local_binding.v1';
const _oldRecoveryKey = 'liuhetong.encrypted_recovery_key';

final class _CrashAtArchiveIndexStore implements SecureKeyValueStore {
  final values = <String, String>{};
  bool failIndexWrite = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failIndexWrite && key == _archiveIndexKey) {
      throw StateError('synthetic interruption after journal write');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

final class _AuthorizedBusiness implements DualDomainBusinessGateway {
  _AuthorizedBusiness(this.events);

  final List<String> events;
  bool wrongGrantTarget = true;
  int grants = 0;
  final bound = <String>[];

  @override
  Future<String?> currentMatrixUserId() async => _userId;

  @override
  Future<MatrixLoginGrant> issueMatrixLoginToken() async {
    grants++;
    events.add('business_grant');
    return MatrixLoginGrant(
      loginToken: 'one-time-grant',
      homeserver: _homeserver,
      expiresIn: 60,
      matrixUserId: wrongGrantTarget ? '@other:matrix.test' : _userId,
    );
  }

  @override
  Future<void> bindMatrixUserId(String matrixUserId) async {
    events.add('business_bind');
    bound.add(matrixUserId);
  }

  @override
  Future<void> loginBusiness({
    required String username,
    required String password,
    required String deviceKey,
    required String deviceName,
  }) async =>
      throw StateError('Retained Business session already authorized');

  @override
  Future<void> logoutBusiness() async =>
      throw StateError('Restore must not log out the Business session');
}

final class _FactoryBackedMatrix
    implements MatrixTokenLoginGateway, MatrixAccountSelectionGateway {
  _FactoryBackedMatrix(this.factory, this.events);

  final MatrixClientFactory factory;
  final List<String> events;
  int selections = 0;
  int tokenLogins = 0;

  @override
  bool isLoggedIn = false;
  @override
  bool credentialsInvalid = false;
  @override
  String? userId;
  @override
  String? deviceId;

  @override
  Future<void> selectAccount(String matrixUserId, Uri homeserver) async {
    selections++;
    events.add('select_account');
    await factory.selectAccount(homeserver.toString(), matrixUserId);
    await factory.create();
    events.add('open_fresh_scope');
  }

  @override
  Future<void> loginWithToken({
    required String loginToken,
    required Uri homeserver,
    String? deviceId,
  }) async {
    expect(loginToken, 'one-time-grant');
    expect(homeserver.toString(), _homeserver);
    tokenLogins++;
    events.add('matrix_token_login');
    userId = _userId;
    this.deviceId = 'NEW-DEVICE';
    isLoggedIn = true;
  }

  @override
  Future<void> sync() async => events.add('matrix_sync');

  @override
  Future<void> suspend() async => events.add('matrix_suspend');

  @override
  Future<void> clearLocalChatData() async =>
      throw StateError('Old chat data must not be cleared');
}

void main() {
  test(
      'pending archive replays only after the Business grant authorizes restore',
      () async {
    final raw = _CrashAtArchiveIndexStore();
    final oldStore = SecureSessionStore(raw);
    await oldStore.saveMatrixBinding(MatrixLocalBinding(
      version: 2,
      matrixUserId: _userId,
      deviceId: 'ORIGINAL',
      homeserver: _homeserver,
      databaseGeneration: 'old-generation',
      ed25519Fingerprint: 'original-fingerprint',
    ));
    await oldStore.matrixDatabaseKey();
    await oldStore.saveEncryptedRecoveryKey('opaque-old-recovery');
    final snapshot =
        await oldStore.peekAccountMatrixIdentity(_homeserver, _userId);
    final oldKey = raw.values[_oldDatabaseKey];
    final oldBinding = raw.values[_oldBindingKey];
    final oldRecovery = raw.values[_oldRecoveryKey];

    final artifacts = Directory(
        '../../docs/verification/artifacts/2026-09-25/ios-auth-journal-test');
    await artifacts.create(recursive: true);
    final databaseDirectory = await artifacts.createTemp('retained-');
    addTearDown(() => databaseDirectory.delete(recursive: true));
    final oldDatabase = File(
        '${databaseDirectory.path}${Platform.pathSeparator}${MatrixClientFactory.databaseFileName}');
    final oldBytes = <int>[13, 17, 19, 23, 29, 31];
    await oldDatabase.writeAsBytes(oldBytes);

    raw.failIndexWrite = true;
    await expectLater(
      oldStore.prepareFreshDeviceForConfirmedRecovery(
        expectedHomeserver: _homeserver,
        expectedUserId: _userId,
        expectedSnapshot: snapshot,
        scopeHasDatabaseFiles: (_) async => false,
      ),
      throwsStateError,
    );
    raw.failIndexWrite = false;
    final journal = raw.values[_journalKey];
    expect(journal, contains('"phase":"prepared"'));
    expect(raw.values[_archiveIndexKey], isNull);

    final restarted = SecureSessionStore(raw);
    expect(await loadStartupDiagnosticSalt(restarted), isNull);
    await validateLocalLoginStorageForAuthentication(restarted);
    expect(raw.values[_journalKey], journal);

    final events = <String>[];
    final openedPaths = <String>[];
    final factory = MatrixClientFactory(
      sessionStore: restarted,
      homeserver: Uri.parse(_homeserver),
      supportDirectoryPath: () async => databaseDirectory.path,
      opener: ({
        required clientName,
        required databasePath,
        required cipher,
      }) async {
        openedPaths.add(databasePath);
        expect(cipher, isNot(oldKey));
        return Client(clientName);
      },
      clientMigrator: (_, __) async {},
    );
    final business = _AuthorizedBusiness(events);
    final matrix = _FactoryBackedMatrix(factory, events);
    final login = DualDomainLoginService(
      business: business,
      matrix: matrix,
      deviceKey: () => 'device',
      retainedHomeserver: Uri.parse(_homeserver),
    );

    await expectLater(login.restoreAuthenticatedSession(_userId),
        throwsA(isA<LoginStageException>()));
    expect(matrix.selections, 0);
    expect(raw.values[_journalKey], journal);
    expect(raw.values[_archiveIndexKey], isNull);
    expect(await oldDatabase.readAsBytes(), oldBytes);

    business.wrongGrantTarget = false;
    await login.restoreAuthenticatedSession(_userId);

    expect(events, [
      'business_grant',
      'business_grant',
      'select_account',
      'open_fresh_scope',
      'matrix_token_login',
      'business_bind',
      'matrix_sync',
    ]);
    expect(business.grants, 2);
    expect(business.bound, [_userId]);
    expect(matrix.selections, 1);
    expect(matrix.tokenLogins, 1);
    expect(openedPaths, hasLength(1));
    expect(openedPaths.single, isNot(oldDatabase.path));
    expect(raw.values[_journalKey], isNull);
    expect(raw.values[_archiveIndexKey], contains('"kind":"fresh_device"'));
    expect(raw.values[_oldDatabaseKey], oldKey);
    expect(raw.values[_oldBindingKey], oldBinding);
    expect(raw.values[_oldRecoveryKey], oldRecovery);
    expect(await oldDatabase.readAsBytes(), oldBytes);
  });
}
