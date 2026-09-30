import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/native_media_download.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/background_media');
  NativeMediaRequest matrix(
          {String? url,
          String origin = 'https://matrix.test',
          int max = 1024}) =>
      NativeMediaRequest(
          id: 'content-key',
          url: Uri.parse(url ??
              '$origin/_matrix/client/v1/media/download/test/id?allow_redirect=false'),
          trustedOrigin: origin,
          kind: 'matrix',
          maxBytes: max,
          authorization: 'Bearer test-token');
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  test('origin path protocol and byte budget reject before transport', () {
    expect(
        () =>
            matrix(url: 'https://evil.test/_matrix/media/v3/download/test/id'),
        throwsArgumentError);
    expect(() => matrix(origin: 'http://matrix.test'), throwsArgumentError);
    expect(() => matrix(url: 'https://matrix.test/admin'), throwsArgumentError);
    expect(() => matrix(max: 64 * 1024 * 1024 + 1), throwsArgumentError);
    expect(
        () => NativeMediaRequest(
            id: 'x',
            url: Uri.parse('https://api.test/api/v1/moments/media/content/id'),
            trustedOrigin: 'https://api.test',
            kind: 'moments',
            maxBytes: 1024,
            authorization: 'Bearer test'),
        throwsArgumentError);
  });
  test(
      'native registration is immediate and deduplicated, only ciphertext request authority crosses bridge',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'activate') return 'nonce';
      return null;
    });
    final session = NativeMediaDownloadSession('alice', channel: channel);
    await Future.wait([session.prepare(matrix()), session.prepare(matrix())]);
    expect(calls.map((call) => call.method), ['activate', 'enqueue']);
    final args = calls.last.arguments as Map;
    expect(args.keys.toSet(), {
      'account',
      'nonce',
      'id',
      'url',
      'origin',
      'kind',
      'mediaType',
      'maxBytes',
      'authorization'
    });
    expect(args['account'], isNot('alice'));
    await session.dispose();
    expect(calls.last.method, 'revoke');
    expect(() => session.prepare(matrix()), throwsStateError);
  });
  test(
      'logout during activation revokes the returned persistent nonce without enqueuing',
      () async {
    final gate = Completer<String>();
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'activate') return gate.future;
      return null;
    });
    final session = NativeMediaDownloadSession('alice', channel: channel);
    final pending = session.prepare(matrix());
    final assertion = expectLater(pending, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final dispose = session.dispose();
    gate.complete('old-nonce');
    await assertion;
    await dispose;
    expect(methods, ['activate', 'revoke']);
  });
  test(
      'foreground joins and promotes a pending transfer with one native read and consume',
      () async {
    final directory = Directory(
        '../../docs/verification/artifacts/2026-09-30/mobile-perf-mute-media/native-test-${DateTime.now().microsecondsSinceEpoch}');
    await directory.create(recursive: true);
    final file = File('${directory.path}/cipher.bin');
    await file.writeAsBytes([1, 2, 3]);
    final ready = Completer<Map<String, dynamic>>();
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'activate') return 'nonce';
      if (call.method == 'status') return ready.future;
      return null;
    });
    final session = NativeMediaDownloadSession('alice', channel: channel);
    await session.prepare(matrix());
    final foreground =
        NativeMediaDownloadSession.joinPending('alice', 'content-key')!;
    final background = session.download(matrix());
    expect(identical(foreground, background), isTrue);
    ready.complete({'state': 'complete', 'path': file.absolute.path});
    expect(await foreground, [1, 2, 3]);
    expect(await background, [1, 2, 3]);
    expect(methods.where((value) => value == 'enqueue').length, 1);
    expect(methods.where((value) => value == 'status').length, 1);
    expect(methods.where((value) => value == 'consume').length, 1);
    expect(methods, contains('promote'));
    await session.dispose();
    await file.delete();
  });
  test(
      'candidate release retains a shared descriptor until its final owner leaves',
      () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'activate') return 'nonce';
      return null;
    });
    final session =
        NativeMediaDownloadSession('shared-owner', channel: channel);
    addTearDown(session.dispose);
    final a = Object(), b = Object();
    await session.prepare(matrix(), owner: a);
    await session.prepare(matrix(), owner: b);
    await session.release(matrix(), owner: a);
    expect(methods.where((x) => x == 'consume'), isEmpty);
    await session.release(matrix(), owner: b);
    expect(methods.where((x) => x == 'enqueue').length, 1);
    expect(methods.where((x) => x == 'consume').length, 1);
    expect(
        NativeMediaDownloadSession.joinPending('shared-owner', 'content-key'),
        isNull);
  });
}
