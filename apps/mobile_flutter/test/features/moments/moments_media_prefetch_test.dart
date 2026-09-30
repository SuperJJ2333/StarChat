import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/moments/moments_media_prefetch.dart';
import 'package:liuhetong_mobile/features/matrix/incoming_media_prefetch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'account source discovers images and videos without a Moments page or unread mutation',
      () async {
    var reads = 0;
    final source = MomentsMediaPrefetchSource(
        accountId: 'alice',
        trustedOrigin: 'https://api.test',
        load: () async {
          reads++;
          return {
            'items': [
              {
                'image_urls': [
                  'https://api.test/api/v1/moments/media/content/image'
                ],
                'image_cache_keys': ['a' * 64],
                'video_urls': [
                  'https://api.test/api/v1/moments/media/content/video'
                ],
                'video_cache_keys': ['b' * 64]
              },
              {
                'image_urls': ['https://evil.test/image'],
                'image_cache_keys': ['c' * 64]
              },
              {
                'kind': 'AD',
                'image_urls': [
                  'https://api.test/api/v1/moments/media/content/ad'
                ],
                'image_cache_keys': ['d' * 64]
              }
            ]
          };
        });
    final received = <IncomingMediaCandidate>[];
    final sub = source.candidates.listen(received.add);
    await source.start();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    expect(received.length, 2);
    expect(received.map((item) => item.isVideo), [false, true]);
    expect(received.every((item) => item.originalKey.accountId == 'alice'),
        isTrue);
    await source.dispose();
    await sub.cancel();
  });
  test('in-flight feed scan is shared and logout drops its late response',
      () async {
    final gate = Completer<Map<String, dynamic>>();
    var reads = 0;
    final source = MomentsMediaPrefetchSource(
        accountId: 'alice',
        trustedOrigin: 'https://api.test',
        load: () {
          reads++;
          return gate.future;
        });
    final received = <IncomingMediaCandidate>[];
    final sub = source.candidates.listen(received.add);
    final first = source.start();
    final second = source.refresh();
    expect(reads, 1);
    await source.dispose();
    gate.complete({
      'items': [
        {
          'image_urls': ['https://api.test/api/v1/moments/media/content/image'],
          'image_cache_keys': ['a' * 64]
        }
      ]
    });
    await Future.wait([first, second]);
    expect(received, isEmpty);
    await sub.cancel();
  });
}
