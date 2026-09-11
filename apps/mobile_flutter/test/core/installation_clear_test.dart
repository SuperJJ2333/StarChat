import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'account_chat_store_test.dart' show binding;
import 'session_store_test.dart' show MemorySecureKeyValueStore;

const _home = 'https://matrix.example';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('清除覆盖全部账号槽与固定元数据键', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    await store.saveSession(accessToken: 'a', refreshToken: 'r');
    await store.registrationDeviceKey();
    await store.selectMatrixAccount(_home, '@a:test');
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    await store.matrixDatabaseKey();
    await store.selectMatrixAccount(_home, '@b:test');
    await store.saveMatrixBinding(binding('@b:test', 'device-B'));
    await store.matrixDatabaseKey();
    expect(memory.values.keys.where((k) => k.startsWith('liuhetong.')),
        isNotEmpty);

    await store.clearInstallation();

    expect(
        memory.values.keys.where((k) => k.startsWith('liuhetong.')), isEmpty);
  });

  test('无后缀的遗留键一并清除', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    await memory.write('liuhetong.matrix_database_key.v1', 'legacy-key');
    await memory.write('liuhetong.matrix_local_binding.v1', '{"version":2}');

    await store.clearInstallation();

    expect(
        memory.values.containsKey('liuhetong.matrix_database_key.v1'), isFalse);
    expect(memory.values.containsKey('liuhetong.matrix_local_binding.v1'),
        isFalse);
  });

  test('注册表损坏不阻断清除，仍按可识别后缀删除', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    final suffix = 'a' * 64;
    // 结构非法但含有合法槽标识：解析必须失败，回退仍须命中。
    await memory.write('liuhetong.matrix_account_slots.v1', '{"$suffix":');
    await memory.write(
        'liuhetong.matrix_database_key.v1.$suffix', 'scoped-key');

    await store.clearInstallation();

    expect(
        memory.values.containsKey('liuhetong.matrix_database_key.v1.$suffix'),
        isFalse);
    expect(memory.values.containsKey('liuhetong.matrix_account_slots.v1'),
        isFalse);
  });

  test('单个键删除失败时抛出首个错误且不静默通过', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    await memory.write('liuhetong.business_session.v1', 'value');
    memory.deleteErrors['liuhetong.business_session.v1'] =
        StateError('keychain unavailable');

    await expectLater(store.clearInstallation(), throwsStateError);
  });

  test('清除覆盖的按槽键名与存储层的作用域集合一致', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    final suffix = 'b' * 64;
    // 该列表在存储层重复出现三处：加键时漏改会静默少清，正是本次要修的错误类型。
    for (final name in const [
      'liuhetong.matrix_database_key.v1',
      'liuhetong.matrix_local_binding.v1',
      'liuhetong.encrypted_recovery_key',
      'liuhetong.diagnostic_salt.v1',
      'liuhetong.matrix_clear_tombstone.v1',
    ]) {
      await memory.write('$name.$suffix', 'value');
    }
    await memory.write(
        'liuhetong.matrix_account_slots.v1', '{"$suffix":"$suffix"}');

    await store.clearInstallation();

    expect(memory.values.keys.where((k) => k.contains(suffix)), isEmpty);
  });
}
