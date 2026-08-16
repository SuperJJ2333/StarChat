import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:liuhetong_mobile/ui/theme/theme_picker_sheet.dart';

final class FakeThemePreferenceStore implements ThemePreferenceStore {
  FakeThemePreferenceStore({this.value, this.failWrite = false});

  String? value;
  bool failWrite;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    if (failWrite) throw StateError('disk unavailable');
    this.value = value;
  }
}

void main() {
  test('defaults invalid or missing preference to system', () async {
    for (final stored in <String?>[null, '', 'sepia']) {
      final controller = ThemeController(
        store: FakeThemePreferenceStore(value: stored),
      );
      await controller.load();
      expect(controller.preference, ThemePreference.system);
    }
  });

  test('restores and persists every explicit theme preference', () async {
    final store = FakeThemePreferenceStore(value: 'dark');
    final controller = ThemeController(store: store);
    await controller.load();
    expect(controller.preference, ThemePreference.dark);
    expect(controller.resolve(Brightness.light), Brightness.dark);

    await controller.setPreference(ThemePreference.light);
    expect(store.value, 'light');
    expect(controller.resolve(Brightness.dark), Brightness.light);

    await controller.setPreference(ThemePreference.system);
    expect(store.value, 'system');
    expect(controller.resolve(Brightness.dark), Brightness.dark);
  });

  test('failed persistence rolls back the visible preference', () async {
    final store = FakeThemePreferenceStore(value: 'system');
    final controller = ThemeController(store: store);
    await controller.load();
    store.failWrite = true;

    await controller.setPreference(ThemePreference.dark);

    expect(controller.preference, ThemePreference.system);
    expect(controller.errorMessage, '主题设置保存失败，请重试');
  });

  testWidgets('appearance sheet exposes and selects all three modes',
      (tester) async {
    final store = FakeThemePreferenceStore(value: 'system');
    final controller = ThemeController(store: store);
    await controller.load();

    await tester.pumpWidget(
      CupertinoApp(home: ThemePickerSheet(controller: controller)),
    );

    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浅色模式'), findsOneWidget);
    expect(find.text('深色模式'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.check_mark), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('theme-dark')));
    await tester.pumpAndSettle();

    expect(controller.preference, ThemePreference.dark);
    expect(store.value, 'dark');
  });
}
