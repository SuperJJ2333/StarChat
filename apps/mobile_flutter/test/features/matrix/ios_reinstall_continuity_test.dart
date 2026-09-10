import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/installation_container_probe.dart';
import 'package:liuhetong_mobile/core/installation_marker.dart';
import 'package:liuhetong_mobile/core/installation_reconciler.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import '../../core/account_chat_store_test.dart' show binding;
import '../../core/session_store_test.dart' show MemorySecureKeyValueStore;
import 'matrix_client_factory_test.dart' show LogoutTrackingClient;

const _home = 'https://matrix.example';

MatrixClientFactory _factory(SecureSessionStore store) => MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse(_home),
      supportDirectoryPath: () async => '/private/support',
      clientMigrator: (_, __) async {},
      opener: (
              {required clientName,
              required databasePath,
              required cipher}) async =>
          LogoutTrackingClient(clientName),
    );

final class _Marker implements InstallationMarkerStore {
  _Marker({this.readError});
  bool registered = false;
  final Object? readError;
  var registerCalls = 0;

  @override
  Future<bool> isRegistered() async {
    if (readError != null) throw readError!;
    return registered;
  }

  @override
  Future<void> register() async {
    registerCalls++;
    registered = true;
  }
}

final class _Probe implements InstallationContainerProbe {
  _Probe({this.hasPrevious = false});
  final bool hasPrevious;

  @override
  Future<bool> hasPreviousMatrixStore() async => hasPrevious;
}

/// iOS 卸载会删掉应用沙盒（含 SQLCipher 库）但保留钥匙串，因此账号注册表、
/// 绑定与数据库密钥仍在，而库已不存在。重装后登录必须能正常建立新的加密设备，
/// 而不是被判成完整性损坏（登录流程的 account_storage 阶段 = L07）。
///
/// 反过来，覆盖升级时容器完好、标记却由本次发布才引入，因此必须判成延续，
/// 绝不能删除仍然有效的密钥。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<MemorySecureKeyValueStore> retainedKeychain() async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    await store.selectMatrixAccount(_home, '@a:test');
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    await store.matrixDatabaseKey();
    return memory;
  }

  test('iOS 重装后清除遗留，连续性检查不再抛错', () async {
    final memory = await retainedKeychain();
    final store = SecureSessionStore(memory);
    final factory = _factory(store);

    // 清除之前，重装留下的绑定确实会让空库被判成损坏。
    await expectLater(
        factory.continuityMetadata(await factory.create()),
        throwsA(isA<StateError>().having((error) => error.message, 'message',
            'Matrix continuity identity is unavailable')));

    final outcome = await InstallationReconciler(
            marker: _Marker(), probe: _Probe(), store: store)
        .reconcile();
    expect(outcome, InstallationResetOutcome.cleared);

    final next = await factory.create();
    final metadata = await factory.continuityMetadata(next);
    expect(metadata.isLoggedIn, isFalse);
    expect(metadata.userId, isNull);
    expect(metadata.deviceId, isNull);
  });

  test('重装后首次登录不再阻断在 account_storage 阶段', () async {
    final memory = await retainedKeychain();
    final store = SecureSessionStore(memory);
    await InstallationReconciler(
            marker: _Marker(), probe: _Probe(), store: store)
        .reconcile();
    final factory = _factory(store);
    final matrix = MatrixSdkE2eeClient(
      LogoutTrackingClient('liuhetong_mobile'),
      homeserver: Uri.parse(_home),
      suspendClient: factory.suspend,
      resumeClient: factory.create,
      selectClientAccount: factory.selectAccount,
      readContinuityMetadata: factory.continuityMetadata,
    );

    await matrix.selectAccount('@a:test', Uri.parse(_home));

    expect(matrix.userId, isNull);
  });

  test('覆盖升级：容器仍有加密库时不删任何密钥', () async {
    final memory = await retainedKeychain();
    final store = SecureSessionStore(memory);
    final before = Map<String, String>.from(memory.values);

    final outcome = await InstallationReconciler(
            marker: _Marker(), probe: _Probe(hasPrevious: true), store: store)
        .reconcile();

    expect(outcome, InstallationResetOutcome.adopted);
    expect(memory.values, before);
    // 绑定与库密钥都还在：升级后原有的加密库仍可解密。
    expect(await store.matrixBinding(), isNotNull);
    expect(await store.matrixDatabaseKey(), isNotEmpty);
  });

  test('Android 式干净重装：走全新安装分支且检查不抛错', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    final factory = _factory(store);

    final outcome = await InstallationReconciler(
            marker: _Marker(), probe: _Probe(), store: store)
        .reconcile();
    expect(outcome, InstallationResetOutcome.cleared);
    // 空库上断言"键集为空"是恒真的，抓不到回归；改为断言清除确实被调用过。
    expect(memory.attemptedDeletes,
        containsAll(<String>['liuhetong.business_session.v1']));

    final metadata = await factory.continuityMetadata(await factory.create());
    expect(metadata.isLoggedIn, isFalse);
  });

  test('标记读取失败时不清理，完整性守卫仍按原样失败关闭', () async {
    final memory = await retainedKeychain();
    final store = SecureSessionStore(memory);
    final factory = _factory(store);

    final outcome = await InstallationReconciler(
            marker: _Marker(readError: StateError('prefs unavailable')),
            probe: _Probe(),
            store: store)
        .reconcile();

    expect(outcome, InstallationResetOutcome.failed);
    await expectLater(
        factory.continuityMetadata(await factory.create()),
        throwsA(isA<StateError>().having((error) => error.message, 'message',
            'Matrix continuity identity is unavailable')));
  });
}
