import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/group_avatar_mosaic.dart';

void main() {
  test('group avatar uses the approved centered row table', () {
    expect(GroupAvatarLayout.rowsForCount(1), [1]);
    expect(GroupAvatarLayout.rowsForCount(2), [2]);
    expect(GroupAvatarLayout.rowsForCount(3), [1, 2]);
    expect(GroupAvatarLayout.rowsForCount(4), [2, 2]);
    expect(GroupAvatarLayout.rowsForCount(5), [2, 3]);
    expect(GroupAvatarLayout.rowsForCount(6), [3, 3]);
    expect(GroupAvatarLayout.rowsForCount(7), [2, 2, 3]);
    expect(GroupAvatarLayout.rowsForCount(8), [3, 3, 2]);
    expect(GroupAvatarLayout.rowsForCount(12), [3, 3, 3]);
  });

  testWidgets('every mosaic member keeps an equal rounded square',
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
    expect(rects.map((rect) => rect.width).toSet(), hasLength(1));
    expect(rects.map((rect) => rect.height).toSet(), hasLength(1));
    expect(rects.every((rect) => rect.width == rect.height), isTrue);
  });
}
