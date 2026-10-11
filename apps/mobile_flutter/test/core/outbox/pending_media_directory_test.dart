import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chatflow/media_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
      'directory and seal require positive native readback, exact opaque identifiers',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'path': '/private/pending-media-v1',
        'availableBytes': 100000000,
        'protected': true,
        'backupExcluded': true
      };
    });
    expect((await PendingMediaDirectory.directory()).path,
        '/private/pending-media-v1');
    expect(await PendingMediaDirectory.availableBytes(), 100000000);
    await PendingMediaDirectory.seal('a' * 64, 'b' * 64);
    expect(calls.map((c) => c.method),
        ['pendingMediaDirectory', 'pendingMediaDirectory', 'sealPendingFiles']);
    expect(calls.first.arguments, isNull);
    expect(calls.last.arguments, {'scope': 'a' * 64, 'sourceId': 'b' * 64});
  });
  for (final key in ['protected', 'backupExcluded']) {
    test('negative $key readback cannot fall back to ordinary directory',
        () async {
      messenger.setMockMethodCallHandler(
          channel,
          (_) async => {
                'path': '/private/pending-media-v1',
                'availableBytes': 100000000,
                'protected': true,
                'backupExcluded': true,
                key: false
              });
      await expectLater(PendingMediaDirectory.directory(),
          throwsA(isA<MediaOutboxException>()));
      await expectLater(PendingMediaDirectory.seal('a' * 64, null),
          throwsA(isA<MediaOutboxException>()));
    });
  }
  test('missing platform implementation is a refusal, not cache fallback',
      () async {
    await expectLater(PendingMediaDirectory.directory(),
        throwsA(isA<MissingPluginException>()));
  });
}
