import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/moments/moment_image_viewer_page.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_viewer.dart';

const _origin = 'https://media.example.test';
const _keys = [
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
];

List<String> _urls(String suffix) => List.generate(
    3, (index) => '$_origin/api/v1/profile/avatar/content/$suffix-$index');

Widget _page({
  required List<String> urls,
  String account = 'matrix:alice',
  String origin = _origin,
  int initialIndex = 0,
  List<String?> imageCacheKeys = _keys,
}) =>
    CupertinoApp(
      home: MomentImageViewerPage(
        key: const ValueKey('viewer'),
        imageUrls: urls,
        imageCacheKeys: imageCacheKeys,
        initialIndex: initialIndex,
        mediaAccountKey: account,
        mediaOrigin: origin,
      ),
    );

void main() {
  testWidgets('preserves the same current image across signed-url reordering',
      (tester) async {
    final original = _urls('old');
    await tester.pumpWidget(_page(urls: original));
    await tester.pump();
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.pumpWidget(_page(
      urls: [original[1], original[0], original[2]],
      imageCacheKeys: [_keys[1], _keys[0], _keys[2]],
    ));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('account replacement safely resets the selected image',
      (tester) async {
    final urls = _urls('image');
    await tester.pumpWidget(_page(urls: urls, initialIndex: 0));
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);

    await tester
        .pumpWidget(_page(urls: urls, account: 'matrix:bob', initialIndex: 0));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('source replacement at the same index resets safely',
      (tester) async {
    await tester.pumpWidget(_page(urls: _urls('old')));
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_page(urls: _urls('new'), imageCacheKeys: const [
      'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
      'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
    ]));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('empty collection has a safe non-paged state', (tester) async {
    await tester.pumpWidget(_page(urls: const []));
    expect(find.byKey(const Key('moment-image-viewer-empty')), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('legacy viewer also safely handles an empty collection',
      (tester) async {
    await tester.pumpWidget(const CupertinoApp(
      home: WeChatMomentViewer(urls: []),
    ));
    expect(find.byKey(const Key('moment-image-viewer-empty')), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('legacy viewer keeps its page for an equal rebuilt source',
      (tester) async {
    final urls = _urls('legacy');
    await tester.pumpWidget(CupertinoApp(
        home: WeChatMomentViewer(
            urls: urls,
            imageCacheKeys: _keys,
            mediaAccountKey: 'matrix:alice',
            mediaOrigin: _origin)));
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    final before = tester.widget<PageView>(find.byType(PageView)).controller!;

    await tester.pumpWidget(CupertinoApp(
        home: WeChatMomentViewer(
            urls: List.of(urls),
            imageCacheKeys: List.of(_keys),
            mediaAccountKey: 'matrix:alice',
            mediaOrigin: _origin)));
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(find.byType(PageView)).controller,
        same(before));
    expect(before.page, closeTo(1, .01));
  });
}
