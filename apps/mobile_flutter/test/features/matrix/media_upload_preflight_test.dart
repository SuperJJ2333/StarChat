import 'dart:io';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_media_upload_limit.dart';
import 'package:liuhetong_mobile/features/matrix/media_message_service.dart';

class _Gateway
    implements MatrixEncryptedMediaGateway, MatrixMediaUploadLimitGateway {
  _Gateway(this.limit);
  final int? limit;
  var sends = 0;
  var limits = 0;
  String? lastTransaction;
  Object? limitFailure;
  @override
  Future<int?> maximumUploadBytes() async {
    limits++;
    if (limitFailure != null) throw limitFailure!;
    return limit;
  }

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
    lastTransaction = txid;
    return 'synthetic-event';
  }
}

class _ReadSpy implements File {
  _ReadSpy(this.file) : _absolute = file.absolute;
  final File file;
  final File _absolute;
  var reads = 0;
  @override
  String get path => file.path;
  @override
  File get absolute => _absolute;
  @override
  Future<int> length() => file.length();
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  Future<FileStat> stat() => file.stat();
  @override
  Future<Uint8List> readAsBytes() async {
    reads++;
    // Reading is deliberately observable without allocating a huge test buffer.
    return Uint8List(1);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  setUp(() async {
    const record = MethodChannel('com.llfbandit.record/messages');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(record, (_) async => null);
    final root = Directory(
        '../../docs/verification/artifacts/2026-10-11/im-reliability-implementation/preflight-fixtures');
    await root.create(recursive: true);
    directory = await root.createTemp('limit-');
    file = File('${directory.path}/synthetic.bin');
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(64 * 1024 * 1024);
    await handle.close();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('video_compress'), null);
    await directory.delete(recursive: true);
  });

  Future<void> resize(File target, int bytes) async {
    final handle = await target.open(mode: FileMode.write);
    await handle.truncate(bytes);
    await handle.close();
  }

  for (final (server, proxy, expected) in [
    (80, 32, 32),
    (16, 80, 16),
    (0, 80, 0),
  ]) {
    test('effective bound is min server=$server proxy=$proxy', () async {
      await resize(file, 64);
      final gateway = _Gateway(server);
      final service = MediaMessageService(gateway, proxyLimitBytes: proxy);
      final spy = _ReadSpy(file);
      await IOOverrides.runZoned(() async {
        await expectLater(
            service.sendSelectedFile('synthetic-room', XFile(file.path)),
            throwsA(isA<MediaTooLargeException>()
                .having((e) => e.limitBytes, 'effective', expected)));
      }, createFile: (_) => spy);
      expect(spy.reads, 0);
      expect(gateway.sends, 0);
    });
  }

  test('an unavailable server limit fails without reading or uploading',
      () async {
    final gateway = _Gateway(null)
      ..limitFailure = const SocketException('synthetic-offline');
    final spy = _ReadSpy(file);
    await IOOverrides.runZoned(() async {
      await expectLater(
          MediaMessageService(gateway)
              .sendSelectedFile('synthetic-room', XFile(file.path)),
          throwsA(isA<SocketException>()));
    }, createFile: (_) => spy);
    expect(spy.reads, 0);
    expect(gateway.sends, 0);
  });

  test('a server which advertises no limit still obeys the known proxy bound',
      () async {
    await resize(file, 64);
    final spy = _ReadSpy(file);
    await IOOverrides.runZoned(() async {
      await expectLater(
          MediaMessageService(_Gateway(null), proxyLimitBytes: 32)
              .sendSelectedFile('synthetic-room', XFile(file.path)),
          throwsA(isA<MediaTooLargeException>()));
    }, createFile: (_) => spy);
    expect(spy.reads, 0);
  });

  test('a file exactly at the limit is sent with the original transaction',
      () async {
    await resize(file, 64);
    final gateway = _Gateway(64);
    final spy = _ReadSpy(file);
    await IOOverrides.runZoned(() async {
      expect(
          await MediaMessageService(gateway).sendSelectedFile(
              'synthetic-room', XFile(file.path),
              txid: 'stable-tx'),
          'synthetic-event');
    }, createFile: (_) => spy);
    expect(spy.reads, 1);
    expect(gateway.sends, 1);
    expect(gateway.lastTransaction, 'stable-tx');
  });

  for (final limit in [8 * 1024 * 1024, 20 * 1024 * 1024]) {
    test(
        'video checks its 16MiB rendition against $limit, not its 64MiB source',
        () async {
      final encoded = File('${directory.path}/encoded.mp4');
      await resize(encoded, 16 * 1024 * 1024);
      var posterReads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('video_compress'),
              (call) async {
        if (call.method == 'getByteThumbnail') {
          posterReads++;
          return null;
        }
        if (call.method == 'cancelCompression') return true;
        return jsonEncode({
          'path': encoded.path,
          'duration': 1000.0,
          'width': 640,
          'height': 480
        });
      });
      final sourceSpy = _ReadSpy(file);
      final encodedSpy = _ReadSpy(encoded);
      final gateway = _Gateway(limit);
      await IOOverrides.runZoned(() async {
        final sending = MediaMessageService(gateway).sendSelectedFile(
            'synthetic-room', XFile(file.path, mimeType: 'video/mp4'));
        if (limit < 16 * 1024 * 1024) {
          await expectLater(sending, throwsA(isA<MediaTooLargeException>()));
        } else {
          expect(await sending, 'synthetic-event');
        }
      }, createFile: (path) => path == encoded.path ? encodedSpy : sourceSpy);
      expect(sourceSpy.reads, 0);
      expect(encodedSpy.reads, limit < 16 * 1024 * 1024 ? 0 : 1);
      if (limit < 16 * 1024 * 1024) expect(posterReads, 0);
      expect(await file.exists(), isTrue);
      expect(await encoded.exists(), isFalse);
    });
  }

  test('64MiB file against 50MiB server is rejected before any content read',
      () async {
    final gateway = _Gateway(50 * 1024 * 1024);
    final service = MediaMessageService(gateway);
    final spy = _ReadSpy(file);
    await IOOverrides.runZoned(() async {
      await expectLater(
          service.sendSelectedFile('synthetic-room', XFile(file.path)),
          throwsA(isA<MediaTooLargeException>()
              .having((e) => e.limitBytes, 'server limit', 50 * 1024 * 1024)));
    }, createFile: (_) => spy);
    expect(spy.reads, 0);
    expect(gateway.sends, 0);
    expect(gateway.limits, greaterThan(0));
  });

  test('voice file also resolves the lower server limit before reading',
      () async {
    final gateway = _Gateway(50 * 1024 * 1024);
    final service = MediaMessageService(gateway);
    final spy = _ReadSpy(file);
    await IOOverrides.runZoned(() async {
      await expectLater(service.sendVoicePreview('synthetic-room', file.path),
          throwsA(isA<MediaTooLargeException>()));
    }, createFile: (_) => spy);
    expect(spy.reads, 0);
    expect(gateway.sends, 0);
  });
}
