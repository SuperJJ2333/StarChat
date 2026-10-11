import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/media_message_service.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:liuhetong_mobile/features/matrix/media_transfer_budget.dart';

const mib = 1024 * 1024;

class _Gateway implements MatrixEncryptedMediaGateway {
  final settle = Completer<void>();
  int sends = 0;
  @override
  Future<String> sendEncryptedMedia(
      String roomId, List<int> plaintext, String mimeType,
      {Map<String, dynamic>? extraContent,
      String? txid,
      String? filename,
      Uint8List? thumbnailBytes,
      int? thumbnailWidth,
      int? thumbnailHeight}) async {
    sends++;
    await settle.future;
    return 'synthetic-event';
  }
}

class _ReadSpy implements File {
  _ReadSpy(this.file);
  final File file;
  int reads = 0;
  List<int> fullBytes = [0];
  @override
  String get path => file.path;
  @override
  Future<FileStat> stat() => file.stat();
  @override
  Future<Uint8List> readAsBytes() async {
    reads++;
    return Uint8List(1);
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    if (end != 12) reads++;
    yield end == 12 ? [0] : fullBytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.record/messages'),
            (_) async => null);
    final root = Directory(
        '../../docs/verification/artifacts/2026-10-11/im-media-budget/fixtures');
    await root.create(recursive: true);
    directory = await root.createTemp('admission-');
    file = File('${directory.path}/synthetic.bin');
  });
  tearDown(() => directory.delete(recursive: true));
  Future<void> resize(int size) async {
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(size);
    await handle.close();
  }

  Future<void> pump() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  test(
      '100MiB operation rejects before reading with actionable budget feedback',
      () async {
    await resize(100 * mib);
    final spy = _ReadSpy(file);
    final gateway = _Gateway()..settle.complete();
    await IOOverrides.runZoned(() async {
      await expectLater(
          MediaMessageService(gateway)
              .sendSelectedFile('room', XFile(file.path)),
          throwsA(predicate((e) =>
              e.toString().contains('压缩') && e.toString().contains('预算'))));
    }, createFile: (_) => spy);
    expect(spy.reads, 0);
    expect(gateway.sends, 0);
  });

  test('five 10MiB sends across service instances share one peak byte budget',
      () async {
    await resize(10 * mib);
    final spy = _ReadSpy(file);
    final gateway = _Gateway();
    await IOOverrides.runZoned(() async {
      final sends = [
        for (var i = 0; i < 5; i++)
          MediaMessageService(gateway)
              .sendSelectedFile('room-$i', XFile(file.path))
      ];
      try {
        await pump();
        expect(gateway.sends, 4);
        expect(spy.reads, 4);
      } finally {
        gateway.settle.complete();
        await Future.wait(sends);
      }
    }, createFile: (_) => spy);
    expect(gateway.sends, 5);
  });

  test('a file that grows after stat is rejected before SDK dispatch',
      () async {
    await resize(1);
    final spy = _ReadSpy(file)..fullBytes = [0, 1];
    final gateway = _Gateway()..settle.complete();
    await IOOverrides.runZoned(() async {
      await expectLater(
          MediaMessageService(gateway)
              .sendSelectedFile('room', XFile(file.path)),
          throwsA(isA<MediaTransferLimitException>()));
    }, createFile: (_) => spy);
    expect(gateway.sends, 0);
    expect(sharedMediaTransferBudget.activeBytes, 0);
  });

  test('canceling a per-service slot waiter does not wait for active uploads',
      () async {
    await resize(10 * mib);
    final spy = _ReadSpy(file);
    final gateway = _Gateway();
    final service = MediaMessageService(gateway);
    final scope = MediaConsumerScope();
    await IOOverrides.runZoned(() async {
      final active = [
        for (var i = 0; i < 3; i++)
          service.sendSelectedFile('room', XFile(file.path))
      ];
      await pump();
      final pending =
          scope.run(() => service.sendSelectedFile('room', XFile(file.path)));
      final canceled = expectLater(pending, throwsA(isA<MediaLoadCanceled>()));
      await pump();
      scope.cancel();
      await canceled.timeout(const Duration(seconds: 2));
      expect(gateway.sends, 3);
      expect(spy.reads, 3);
      gateway.settle.complete();
      await Future.wait(active);
    }, createFile: (_) => spy);
    expect(sharedMediaTransferBudget.activeBytes, 0);
  });
}
