import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/auth_surface_card.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

void main() {
  testWidgets('auth error message uses shared semantic feedback surface',
      (tester) async {
    await tester.pumpWidget(const CupertinoApp(
      home: AuthErrorMessage(message: '请输入正确验证码'),
    ));
    final box =
        tester.widget<Container>(find.byKey(const Key('auth-error-message')));
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, WeChatColors.errorSurface);
    expect(find.text('请输入正确验证码'), findsOneWidget);
  });

  testWidgets('auth text field consumes tokenized padding and typography',
      (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(CupertinoApp(
        home: AuthTextField(
      label: '邮箱',
      placeholder: 'name@example.test',
      controller: controller,
    )));
    final field =
        tester.widget<CupertinoTextField>(find.byType(CupertinoTextField));
    expect(field.placeholderStyle?.fontSize, WeChatTypography.callout);
  });
}
