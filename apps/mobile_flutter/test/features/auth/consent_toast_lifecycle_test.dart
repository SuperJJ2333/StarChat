import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/wechat_toast.dart';

void main() {
  testWidgets(
      'toast survives removal of its triggering widget before first frame',
      (tester) async {
    late BuildContext trigger;
    await tester.pumpWidget(CupertinoApp(home: Builder(builder: (context) {
      trigger = context;
      return const SizedBox();
    })));
    showWeChatToast(trigger, '同意协议');
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });
}
