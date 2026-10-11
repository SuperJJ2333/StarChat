import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';

/// Must run on the actual Android/iOS candidate. No mocked channel/factory,
/// credentials, Matrix session, network, or media library permission required.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native protected pending source and SQLite survive reopen',
      (tester) async {
    final root = await PendingMediaDirectory.directory();
    final owner = MediaOutboxOwner(
        accountId: '@synthetic-native:invalid',
        homeserver: 'https://synthetic.invalid',
        generation: 'synthetic-${DateTime.now().microsecondsSinceEpoch}');
    var store = SqliteMediaOutboxStore(owner: owner);
    try {
      final task = await store.persistBytes(
          txid: 'native-fixed-transaction',
          roomId: '!synthetic:invalid',
          bytes: Uint8List.fromList([1, 2, 3, 4]),
          mimeType: 'application/octet-stream',
          filename: 'synthetic.bin',
          prepared: true,
          asFile: true);
      final before = await store.verifiedSource(task);
      expect(p.isWithin(root.absolute.path, before.absolute.path), isTrue);
      await store.close();
      store = SqliteMediaOutboxStore(owner: owner);
      final reopened = (await store.byTxid(task.txid))!;
      expect(reopened.stage, MediaOutboxStage.queued);
      expect(reopened.prepared && reopened.asFile, isTrue);
      expect(await (await store.verifiedSource(reopened)).readAsBytes(),
          [1, 2, 3, 4]);
      await store.setStage(task.txid, MediaOutboxStage.canceled);
      await store.releaseTerminalSource(task.txid);
      expect(await before.exists(), isFalse);
    } finally {
      await store.close();
      final scope = Directory(p.join(root.path, owner.scope));
      expect(p.isWithin(root.absolute.path, scope.absolute.path), isTrue);
      if (await scope.exists()) await scope.delete(recursive: true);
    }
  });
}
