import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chatflow/media_storage');

  testWidgets(
      'native pending files are protected and excluded with no path API',
      (tester) async {
    final info =
        await channel.invokeMapMethod<String, Object?>('pendingMediaDirectory');
    expect(info?['protected'], true);
    expect(info?['backupExcluded'], true);
    expect(info?['availableBytes'], greaterThanOrEqualTo(0));
    final root = Directory(info!['path'] as String);
    expect(root.path.split(Platform.pathSeparator).last, 'pending-media-v1');
    final token = const Uuid().v4().replaceAll('-', '');
    final scope = '$token$token';
    final folder = Directory('${root.path}/$scope');
    final sources = Directory('${folder.path}/sources');
    await sources.create(recursive: true);
    addTearDown(() async {
      final actual = await folder.resolveSymbolicLinks();
      final parent = await root.resolveSymbolicLinks();
      if (!actual.startsWith('$parent${Platform.pathSeparator}')) {
        throw StateError('Synthetic fixture escaped fixed root');
      }
      await folder.delete(recursive: true);
    });
    await File('${folder.path}/manifest-v1.db')
        .writeAsBytes([1, 2, 3], flush: true);
    final source = 'e' * 64;
    final original = File('${sources.path}/$source.bin.part');
    await original.writeAsBytes([4, 5, 6], flush: true);
    Future<Map<String, Object?>?> seal() =>
        channel.invokeMapMethod<String, Object?>(
            'sealPendingFiles', {'scope': scope, 'sourceId': source});
    expect((await seal())?['protected'], true);
    expect((await seal())?['backupExcluded'], true);
    expect(await original.readAsBytes(), [4, 5, 6]);
    await original.rename('${sources.path}/$source.bin');
    expect((await seal())?['protected'], true);
    await expectLater(
        channel.invokeMethod<Object?>(
            'sealPendingFiles', {'scope': '../outside', 'sourceId': source}),
        throwsA(isA<PlatformException>()));
    await expectLater(
        channel.invokeMethod<Object?>(
            'pendingMediaDirectory', {'path': '/caller-selected-path'}),
        throwsA(isA<PlatformException>()));
    if (Platform.isIOS) {
      final cache = await channel
          .invokeMapMethod<String, Object?>('documentsChatMediaPolicy');
      expect(cache?['protected'], true);
      expect(cache?['backupExcluded'], true);
    }
  }, skip: !Platform.isAndroid && !Platform.isIOS);
}
