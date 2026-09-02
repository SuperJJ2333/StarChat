import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/main.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';

final class _FakeStore implements ThemePreferenceStore {
  String? stored;
  @override
  Future<String?> read() async => stored;
  @override
  Future<void> write(String value) async => stored = value;
}

void main() {
  testWidgets('app follows the system dark mode switch live', (tester) async {
    final controller = ThemeController(store: _FakeStore());
    await tester.pumpWidget(LiuhetongApp(
      home: const Placeholder(),
      themeController: controller,
    ));

    Brightness themeBrightness() => CupertinoTheme.of(
          tester.element(find.byType(Placeholder)),
        ).brightness ?? Brightness.light;

    expect(controller.preference, ThemePreference.system);
    expect(themeBrightness(), Brightness.light);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(themeBrightness(), Brightness.dark,
        reason: '系统切换深色后，App 应自动跟随为深色主题');

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    expect(themeBrightness(), Brightness.light);
  });

  testWidgets('explicit theme preference overrides the system brightness',
      (tester) async {
    final controller = ThemeController(store: _FakeStore());
    await controller.load();
    await controller.setPreference(ThemePreference.light);
    await tester.pumpWidget(LiuhetongApp(
      home: const Placeholder(),
      themeController: controller,
    ));

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(
      CupertinoTheme.of(tester.element(find.byType(Placeholder))).brightness,
      Brightness.light,
    );
  });
}
