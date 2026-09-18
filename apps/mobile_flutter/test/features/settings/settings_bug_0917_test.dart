import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/settings/notification/notification_settings_page.dart';
import 'package:liuhetong_mobile/main.dart';
import 'package:liuhetong_mobile/ui/motion/motion_page_route.dart';
import 'package:liuhetong_mobile/ui/motion/motion_preferences.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';

final class _MemoryMotionStore implements MotionPreferenceStore {
  _MemoryMotionStore([this.value]);
  bool? value;
  int writes = 0;
  @override
  Future<bool?> read() async => value;
  @override
  Future<void> write(bool next) async {
    writes++;
    value = next;
  }
}

final class _FailingMotionStore implements MotionPreferenceStore {
  @override
  Future<bool?> read() async => false;
  @override
  Future<void> write(bool next) async => throw StateError('disk full');
}

final class _ThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    motionReduceMotionResolver = () => motionPreferences.reduceMotion;
    motionPreferences.attachStore(_MemoryMotionStore());
  });

  test('BUG-07 notification settings never leak the internal PRD reference',
      () {
    expect(
        notificationSettingsSectionTitles, isNot(contains('勿扰模式（PRD §30）')));
    expect(
        notificationSettingsSectionTitles.where((title) =>
            title.contains('PRD') ||
            title.contains('§') ||
            title.contains('prd')),
        isEmpty);
    expect(notificationSettingsSectionTitles, contains('勿扰模式'));
  });

  testWidgets('BUG-07 the do-not-disturb section shows plain user copy',
      (tester) async {
    await tester.pumpWidget(
        const CupertinoApp(home: NotificationSettingsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 逐段滚动收集整页文案（列表懒加载，单帧只看得到首屏）。
    final seen = <String>{};
    for (var step = 0; step < 12; step++) {
      seen.addAll(tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .whereType<String>());
      await tester.drag(find.byType(ListView).first, const Offset(0, -200));
      await tester.pump();
    }
    seen.addAll(tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>());

    expect(seen, contains(notificationSettingsDndSection));
    expect(seen, contains('勿扰模式'));
    expect(seen.where((text) => text.contains('PRD') || text.contains('§')),
        isEmpty);
  });

  test('BUG-08 the reduce-motion preference is persisted and reloaded',
      () async {
    final store = _MemoryMotionStore();
    final preferences = MotionPreferences(store: store);
    await preferences.load();
    expect(preferences.reduceMotion, isFalse);

    await preferences.setReduceMotion(true);
    expect(preferences.reduceMotion, isTrue);
    expect(store.value, isTrue);

    final reloaded = MotionPreferences(store: _MemoryMotionStore(true));
    await reloaded.load();
    expect(reloaded.reduceMotion, isTrue);
  });

  test('BUG-08 a failed write rolls back instead of pretending to be saved',
      () async {
    final preferences = MotionPreferences(store: _FailingMotionStore());
    await preferences.load();
    await preferences.setReduceMotion(true);
    expect(preferences.reduceMotion, isFalse);
    expect(preferences.errorMessage, '设置保存失败，请重试');
  });

  test('BUG-08 page transitions collapse while reduce motion is on', () async {
    final preferences = MotionPreferences(store: _MemoryMotionStore());
    await preferences.setReduceMotion(true);
    motionReduceMotionResolver = () => preferences.reduceMotion;

    final route = MotionPageRoute<void>(builder: (_) => const SizedBox());
    // 与框架处理系统级「减少动态效果」一致：压到 5%，肉眼等同于无转场。
    expect(route.transitionDuration,
        const Duration(milliseconds: 500) * 0.05);

    await preferences.setReduceMotion(false);
    final full = MotionPageRoute<void>(builder: (_) => const SizedBox());
    expect(full.transitionDuration, const Duration(milliseconds: 500));
  });

  testWidgets(
      'BUG-08 the app root projects the setting into MediaQuery so every '
      'motion component follows it', (tester) async {
    await motionPreferences.setReduceMotion(false);
    await tester.pumpWidget(LiuhetongApp(
      themeController: ThemeController(store: _ThemeStore()),
      home: Builder(
        builder: (context) => Text(
          MediaQuery.disableAnimationsOf(context) ? 'reduced' : 'full',
        ),
      ),
    ));
    expect(find.text('full'), findsOneWidget);

    await motionPreferences.setReduceMotion(true);
    await tester.pump();
    expect(find.text('reduced'), findsOneWidget);

    // 关掉后恢复跟随系统。
    await motionPreferences.setReduceMotion(false);
    await tester.pump();
    expect(find.text('full'), findsOneWidget);
  });
}
