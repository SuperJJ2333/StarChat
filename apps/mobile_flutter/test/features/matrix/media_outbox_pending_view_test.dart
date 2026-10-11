import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_recovery_service.dart';
import 'package:liuhetong_mobile/features/matrix/media_outbox_pending_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets(
      'restarted failed source has visible reselect explanation and cancel',
      (tester) async {
    late Directory root;
    late SqliteMediaOutboxStore store;
    await tester.runAsync(() async {
      sqfliteFfiInit();
      root = await Directory.systemTemp.createTemp('media-pending-view-');
      store = SqliteMediaOutboxStore(
          owner: const MediaOutboxOwner(
              accountId: '@a:test',
              homeserver: 'https://test',
              generation: 'db'),
          directory: () async => root,
          availableBytes: () async => 1 << 30,
          seal: (_, __) async {});
      final source = await File('${root.path}/source').writeAsBytes([1]);
      await store.persistFile(
          txid: 'pending',
          roomId: '!r:test',
          source: source,
          mimeType: 'application/octet-stream',
          filename: 'synthetic.bin');
      await store.setStage('pending', MediaOutboxStage.failed,
          failure: 'source-missing');
    });
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (_, __) async => r'$event');
    await tester.pumpWidget(CupertinoApp(
        home: CupertinoPageScaffold(
            child:
                MediaOutboxPendingView(service: service, roomId: '!r:test'))));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(find.text('待发附件 1'), findsOneWidget);
    await tester.tap(find.text('待发附件 1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请重新选择'), findsOneWidget);
    await tester.tap(find.text('取消此附件'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect((await tester.runAsync(() => store.byTxid('pending')))!.stage,
        MediaOutboxStage.canceled);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await tester.runAsync(() async {
      await store.close();
      await root.delete(recursive: true);
    });
  });
}
