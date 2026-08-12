import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/main.dart';
void main() {
  testWidgets('renders product identity', (tester) async {
    await tester.pumpWidget(const LiuhetongApp());
    expect(find.text('六合通'), findsOneWidget);
  });
}
