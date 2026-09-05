import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/group_avatar_mosaic.dart';

void main() {
  test('group avatar maps every count to a uniform square grid', () {
    expect(GroupAvatarLayout.gridDimensionForCount(1), 1);
    expect(GroupAvatarLayout.gridDimensionForCount(2), 2);
    expect(GroupAvatarLayout.gridDimensionForCount(4), 2);
    expect(GroupAvatarLayout.gridDimensionForCount(5), 3);
    expect(GroupAvatarLayout.gridDimensionForCount(9), 3);
    expect(GroupAvatarLayout.gridDimensionForCount(12), 3);
  });

  testWidgets('mosaic keeps every member avatar cell the same square size',
      (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: GroupAvatarMosaic(
            size: 72,
            avatars: List.generate(
              7,
              (index) => ColoredBox(color: Color(0xFF000000 + index)),
            ),
          ),
        ),
      ),
    );

    final rects = [
      for (var index = 0; index < 7; index++)
        tester.getRect(find.byKey(Key('group-avatar-member-$index'))),
    ];
    final first = rects.first;
    for (final rect in rects.skip(1)) {
      expect(rect.width, closeTo(first.width, .1));
      expect(rect.height, closeTo(first.height, .1));
      expect(rect.width, closeTo(rect.height, .1));
    }
  });

  testWidgets('two-member mosaic fills its avatar bounds edge to edge',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child: GroupAvatarMosaic(
          size: 72,
          avatars: const [
            ColoredBox(color: Color(0xff111111)),
            ColoredBox(color: Color(0xff222222))
          ],
        ),
      ),
    ));

    final mosaic = tester.getRect(find.byType(GroupAvatarMosaic));
    final first =
        tester.getRect(find.byKey(const Key('group-avatar-member-0')));
    final second =
        tester.getRect(find.byKey(const Key('group-avatar-member-1')));
    expect(first.left, closeTo(mosaic.left + (72 * .045), .1));
    expect(second.right, closeTo(mosaic.right - (72 * .045), .1));
    expect(first.width, closeTo(first.height, .1));
  });
}
