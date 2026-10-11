import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_recovery_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Synthetic interruption, deliberately outside recoverable Exception handling.
class _ProcessDeath extends Error {}

void main() {
  setUpAll(sqfliteFfiInit);
  for (final boundary in [
    'intent',
    'copy',
    'source',
    'queued',
    'upload',
    'event',
    'ack'
  ]) {
    test(
        '100 synthetic process interruptions at $boundary retain intent or fixed-tx delivery',
        () async {
      final base =
          await Directory.systemTemp.createTemp('media-fault-$boundary-');
      try {
        for (var iteration = 0; iteration < 100; iteration++) {
          final root = await Directory('${base.path}/$iteration').create();
          final original =
              await File('${root.path}/selected').writeAsBytes([1, 3, 5]);
          const owner = MediaOutboxOwner(
              accountId: '@synthetic:test',
              homeserver: 'https://synthetic.invalid',
              generation: 'same-database');
          var interrupted = false;
          Future<void> checkpoint(String stage) async {
            if (stage == boundary && !interrupted) {
              interrupted = true;
              throw _ProcessDeath();
            }
          }

          SqliteMediaOutboxStore open({bool faults = false}) =>
              SqliteMediaOutboxStore(
                  owner: owner,
                  directory: () async => root,
                  availableBytes: () async => 1 << 30,
                  seal: (_, __) async {},
                  checkpoint: faults ? checkpoint : null);
          var store = open(faults: true);
          final events = <String, String>{};
          var actualEventCreates = 0;
          Future<String> sender(MediaOutboxTask task, File file) async {
            expect(task.txid, 'stable-$iteration');
            expect(await file.readAsBytes(), [1, 3, 5]);
            await checkpoint('upload');
            final event = events.putIfAbsent(task.txid, () {
              actualEventCreates++;
              return r'$synthetic-event';
            });
            await checkpoint('event');
            return event;
          }

          try {
            final task = await store.persistFile(
                txid: 'stable-$iteration',
                roomId: '!synthetic:test',
                source: original,
                mimeType: 'application/octet-stream',
                filename: 'synthetic.bin');
            final first = MediaOutboxRecoveryService(
                store: store,
                isCurrentOwner: () => true,
                authorize: (_) async => true,
                send: sender,
                checkpoint: checkpoint);
            try {
              await first.dispatch(task);
            } finally {
              first.dispose();
            }
            fail('boundary did not interrupt');
          } on _ProcessDeath {
            /* Destroy/recreate the real file/SQLite store. */
          }
          await store.close();
          await original.delete();
          store = open();
          final restarted = MediaOutboxRecoveryService(
              store: store,
              isCurrentOwner: () => true,
              authorize: (_) async => true,
              send: sender);
          await restarted.recover(waitForSettlement: true);
          final restored = (await store.byTxid('stable-$iteration'))!;
          expect(interrupted, isTrue);
          if (['intent', 'copy', 'source'].contains(boundary)) {
            expect(restored.stage, MediaOutboxStage.failed);
            expect(restored.failure, 'source-incomplete');
            expect(actualEventCreates, 0);
          } else {
            expect(restored.stage, MediaOutboxStage.sent);
            expect(actualEventCreates, 1);
          }
          // A different persistent generation cannot discover or replay it.
          final foreign = SqliteMediaOutboxStore(
              owner: const MediaOutboxOwner(
                  accountId: '@other:test',
                  homeserver: 'https://synthetic.invalid',
                  generation: 'other-database'),
              directory: () async => root,
              availableBytes: () async => 1 << 30,
              seal: (_, __) async {});
          expect(await foreign.pending(), isEmpty);
          await foreign.close();
          restarted.dispose();
          await store.close();
        }
      } finally {
        await base.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
