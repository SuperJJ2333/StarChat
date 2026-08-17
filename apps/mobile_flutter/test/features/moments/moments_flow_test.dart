import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_image_grid.dart';

void main() {
  testWidgets('moment image grid supports 1 4 and 9 images', (tester) async {
    for (final count in [1, 4, 9]) {
      await tester.pumpWidget(CupertinoApp(
          home: WeChatMomentImageGrid(
              imageUrls: List.generate(count, (i) => 'invalid://$i'))));
      expect(find.byKey(const ValueKey('moment-image')), findsNWidgets(count));
    }
  });
}
