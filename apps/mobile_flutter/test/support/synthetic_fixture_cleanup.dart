import 'dart:io';
import 'package:path/path.dart' as p;

/// Only test-owned children below this checkout's verification artifact root.
/// Retry transient Windows removal races, then preserve the original failure.
Future<void> deleteSyntheticFixture(Directory directory,
    {int attempts = 8, Future<void> Function(Directory)? remove}) async {
  final root = p.normalize(p.absolute('../../docs/verification/artifacts'));
  final target = p.normalize(p.absolute(directory.path));
  final canonicalDirectory = Directory(target);
  if (attempts < 1 || attempts > 8 || !p.isWithin(root, target)) {
    throw ArgumentError('Synthetic fixture scope');
  }
  for (var current = target;; current = p.dirname(current)) {
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw ArgumentError('Synthetic fixture link');
    }
    if (p.equals(current, p.dirname(current))) break;
  }
  final delete = remove ??
      (Directory d) async {
        await d.delete(recursive: true);
      };
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (!await canonicalDirectory.exists()) return;
    try {
      await delete(canonicalDirectory);
      return;
    } on FileSystemException catch (error) {
      if (!await canonicalDirectory.exists()) return;
      if (!Platform.isWindows ||
          !{2, 3, 5, 32, 145}.contains(error.osError?.errorCode) ||
          attempt == attempts - 1) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
