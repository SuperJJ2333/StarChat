import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 回答"上一次安装是否在应用容器里留下了 Matrix 加密库"。
///
/// 容器随卸载消失、钥匙串不会，因此这是区分"覆盖升级的延续"与"全新安装"的
/// 可靠证据：加密库文件不可能在卸载后留下，故对全新安装没有假阳性；而只要
/// 应用成功启动过一次，`MatrixClientFactory.create()` 就会建立该文件，
/// 故对覆盖升级几乎不会漏判。
abstract interface class InstallationContainerProbe {
  Future<bool> hasPreviousMatrixStore();
}

final class FileSystemInstallationContainerProbe
    implements InstallationContainerProbe {
  FileSystemInstallationContainerProbe({
    Future<String> Function()? supportDirectoryPath,
  }) : supportDirectoryPath = supportDirectoryPath ?? _defaultSupportPath;

  final Future<String> Function() supportDirectoryPath;

  /// 与 `MatrixClientFactory.databaseFileName` 及其按槽后缀的拼法保持一致。
  /// 改名时必须同时更新这里，否则探测会永远看不到产物，覆盖升级会被误判为
  /// 全新安装。
  static final _storeFileName =
      RegExp(r'^liuhetong_matrix.*\.sqlite(\.encrypted)?$');

  static Future<String> _defaultSupportPath() async =>
      (await getApplicationSupportDirectory()).path;

  @override
  Future<bool> hasPreviousMatrixStore() async {
    final directory = Directory(await supportDirectoryPath());
    if (!await directory.exists()) return false;
    await for (final entry in directory.list()) {
      if (entry is File && _storeFileName.hasMatch(p.basename(entry.path))) {
        return true;
      }
    }
    return false;
  }
}
