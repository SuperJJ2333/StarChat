import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/installation_container_probe.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;

  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('liuhetong-container-probe');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> write(String name) async =>
      File(p.join(directory.path, name)).writeAsString('x');

  FileSystemInstallationContainerProbe probe() =>
      FileSystemInstallationContainerProbe(
          supportDirectoryPath: () async => directory.path);

  test('识别空槽与带槽的加密库文件', () async {
    await write('liuhetong_matrix.sqlite');
    expect(await probe().hasPreviousMatrixStore(), isTrue);
  });

  test('识别带 64 位十六进制槽后缀的库文件', () async {
    await write('liuhetong_matrix_${'a' * 64}.sqlite');
    expect(await probe().hasPreviousMatrixStore(), isTrue);
  });

  test('识别迁移期临时文件', () async {
    await write('liuhetong_matrix.sqlite.encrypted');
    expect(await probe().hasPreviousMatrixStore(), isTrue);
  });

  test('目录不存在时报告没有产物', () async {
    final missing = FileSystemInstallationContainerProbe(
        supportDirectoryPath: () async =>
            p.join(directory.path, 'never-created'));
    expect(await missing.hasPreviousMatrixStore(), isFalse);
  });

  test('只有无关文件时报告没有产物', () async {
    await write('account_chat_store.json');
    await write('media_cache.db');
    expect(await probe().hasPreviousMatrixStore(), isFalse);
  });

  test('目录不可解析时抛出而不是谎报没有产物', () async {
    // 路径本身取不到（path_provider 失败）时必须抛出：谎报"没有产物"会让
    // 协调器把覆盖升级误判为全新安装并删掉仍在使用的密钥。
    final failing = FileSystemInstallationContainerProbe(
        supportDirectoryPath: () async => throw StateError('no support dir'));
    await expectLater(failing.hasPreviousMatrixStore(), throwsStateError);
  });

  test('路径不是目录时报告没有产物而不是抛错', () async {
    await directory.delete(recursive: true);
    await File(directory.path).writeAsBytes(const []);
    expect(await probe().hasPreviousMatrixStore(), isFalse);
  });
}
