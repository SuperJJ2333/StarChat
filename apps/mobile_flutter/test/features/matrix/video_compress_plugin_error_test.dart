import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_compress/video_compress.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('video_compress');
  const source = '/synthetic/private-source.mov';

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    VideoCompress.dispose();
  });

  Future<Object> failureFor(String code) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'compressVideo') {
        throw PlatformException(
          code: code,
          message: 'private native failure for $source',
          details: {'path': source, 'codec': 'synthetic-codec'},
        );
      }
      return null;
    });
    try {
      await VideoCompress.compressVideo(source);
    } catch (error) {
      return error;
    }
    return StateError('compressVideo returned instead of throwing');
  }

  test('Android failure code becomes a closed typed error without raw output',
      () async {
    final printed = <String>[];
    final prior = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    try {
      final error = await failureFor('video_transcode_failed');
      expect(
          error,
          isA<VideoCompressFailure>().having((failure) => failure.kind, 'kind',
              VideoCompressFailureKind.failed));
      expect(error.toString(), 'VideoCompressFailure(failed)');
      expect(printed.join(' '), isNot(contains(source)));
      expect(printed.join(' '), isNot(contains('private native failure')));
      expect(printed.join(' '), isNot(contains('synthetic-codec')));
    } finally {
      debugPrint = prior;
    }
  });

  test('Android cancellation code is distinct from native failure', () async {
    final error = await failureFor('video_transcode_cancelled');
    expect(
        error,
        isA<VideoCompressFailure>().having((failure) => failure.kind, 'kind',
            VideoCompressFailureKind.cancelled));
    expect(error.toString(), 'VideoCompressFailure(cancelled)');
  });

  test('unknown platform code is typed without forwarding private text',
      () async {
    final error = await failureFor('synthetic_unknown');
    expect(
        error,
        isA<VideoCompressFailure>().having((failure) => failure.kind, 'kind',
            VideoCompressFailureKind.unknown));
    expect(error.toString(), 'VideoCompressFailure(unknown)');
  });

  test('legacy null compression result remains supported', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);

    expect(await VideoCompress.compressVideo(source), isNull);
  });

  test('successful result still yields MediaInfo', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'compressVideo') {
        return jsonEncode({
          'path': '/synthetic/output.mp4',
          'duration': 1000,
          'isCancel': false,
        });
      }
      return null;
    });

    final result = await VideoCompress.compressVideo(source);
    expect(result?.path, '/synthetic/output.mp4');
    expect(result?.duration, 1000);
    expect(result?.isCancel, isFalse);
  });
}
