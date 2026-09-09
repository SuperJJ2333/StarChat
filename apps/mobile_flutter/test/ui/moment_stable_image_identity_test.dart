import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';
import 'package:liuhetong_mobile/ui/moments/moment_media_cache.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_viewer.dart';

void main() {
  testWidgets(
      'comment thumbnail and viewer retain account-scoped signed URL identity',
      (tester) async {
    const origin = 'https://media.example.test';
    const digest =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const url =
        '$origin/api/v1/profile/avatar/content/comment-A?expires_in=300';
    final item = MomentItem.fromJson({
      'id': 'post',
      'author': {'user_id': 'a', 'username': 'author'},
      'comments': [
        {
          'id': 'comment',
          'text': '',
          'author': {'user_id': 'a', 'username': 'author'},
          'image_urls': [url],
          'image_cache_keys': [digest],
        }
      ],
    });
    await tester.pumpWidget(CupertinoApp(
        home: WeChatMomentTile(
            item: item, mediaAccountKey: 'matrix:alice', mediaOrigin: origin)));
    final imageFinder = find.byWidgetPredicate((widget) =>
        widget is Image &&
        widget.image is CachedNetworkImageProvider &&
        (widget.image as CachedNetworkImageProvider).url == url);
    final thumbnail = tester.widget<Image>(imageFinder).image;
    final expected = MomentMediaCache.imageProvider(url,
        cacheKey: digest, accountKey: 'matrix:alice', trustedOrigin: origin);
    expect(
        (thumbnail as CachedNetworkImageProvider).cacheKey, expected.cacheKey);
    expect(expected.cacheKey, isNotNull);
    await tester.tap(imageFinder);
    await tester.pumpAndSettle();
    expect(tester.widgetList<Image>(imageFinder).last.image, expected);
  });

  testWidgets('DTO stable image identity reaches the displayed provider',
      (tester) async {
    final item = MomentItem.fromJson({
      'id': 'post',
      'author': {'user_id': 'a', 'username': 'author'},
      'image_urls': [
        'https://media.example.test/api/v1/profile/avatar/content/random-A?expires_in=300'
      ],
      'image_cache_keys': [
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      ],
    });
    await tester.pumpWidget(CupertinoApp(
        home: WeChatMomentTile(
            item: item,
            mediaAccountKey: 'matrix:alice',
            mediaOrigin: 'https://media.example.test')));
    final image = tester.widgetList<Image>(find.byType(Image)).firstWhere(
        (image) =>
            image.image is CachedNetworkImageProvider &&
            (image.image as CachedNetworkImageProvider)
                .url
                .contains('random-A'));
    final provider = image.image as CachedNetworkImageProvider;
    expect(provider.cacheKey, isNotNull);
    await tester.tap(find.byKey(const ValueKey('moment-image')));
    await tester.pumpAndSettle();
    final viewed = tester
        .widgetList<Image>(find.byType(Image))
        .where((image) =>
            image.image is CachedNetworkImageProvider &&
            (image.image as CachedNetworkImageProvider)
                .url
                .contains('random-A'))
        .last;
    expect(viewed.image, provider);
    expect(item.copyWith(liked: true).imageCacheKeys, item.imageCacheKeys);
  });
  testWidgets('cover replacement changes both URL and key', (tester) async {
    const before =
        'https://media.example.test/api/v1/profile/avatar/content/old';
    const after =
        'https://media.example.test/api/v1/profile/avatar/content/new';
    const keyA =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const keyB =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    await tester.pumpWidget(CupertinoApp(
        home: WeChatMomentCoverViewer(
      url: before,
      cacheKey: keyA,
      mediaAccountKey: 'matrix:alice',
      mediaOrigin: 'https://media.example.test',
      onChangeCover: (_) async => after,
      cacheKeyForUrl: (url) => url == after ? keyB : null,
    )));
    expect(
        tester.widget<Image>(find.byType(Image)).image,
        MomentMediaCache.imageProvider(before,
            cacheKey: keyA,
            accountKey: 'matrix:alice',
            trustedOrigin: 'https://media.example.test'));
    await tester.tap(find.byKey(const Key('moment-change-cover')));
    await tester.pumpAndSettle();
    expect(
        tester.widget<Image>(find.byType(Image)).image,
        MomentMediaCache.imageProvider(after,
            cacheKey: keyB,
            accountKey: 'matrix:alice',
            trustedOrigin: 'https://media.example.test'));
  });

  test('legacy and mismatched cache-key arrays preserve URL fallback', () {
    for (final keys in [
      null,
      ['one', 'two'],
      'invalid'
    ]) {
      final item = MomentItem.fromJson({
        'id': 'legacy',
        'author': {'user_id': 'a'},
        'image_urls': ['https://external.example/one?v=1'],
        'image_cache_keys': keys,
      });
      expect(item.imageCacheKeys, isEmpty);
    }
  });
}
