import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/wechat_date_picker.dart';

void main() {
  testWidgets('date picker provides cancel and confirm wheel actions', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: WeChatDatePicker(initialDate: DateTime(2026, 8, 23)),
    ));
    expect(find.byType(CupertinoDatePicker), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
  });
}
