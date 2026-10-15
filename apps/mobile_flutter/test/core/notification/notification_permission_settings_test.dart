import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/notification/app_state_manager.dart';
import 'package:liuhetong_mobile/core/notification/badge_service.dart';
import 'package:liuhetong_mobile/core/notification/foreground_sound_service.dart';
import 'package:liuhetong_mobile/core/notification/haptic_service.dart';
import 'package:liuhetong_mobile/core/notification/in_app_banner_controller.dart';
import 'package:liuhetong_mobile/core/notification/notification_coordinator.dart';
import 'package:liuhetong_mobile/core/notification/notification_preferences.dart';
import 'package:liuhetong_mobile/core/notification/system_notification_presenter.dart';
import 'package:liuhetong_mobile/features/settings/notification/notification_settings_page.dart';

class _Presenter extends Fake
    implements
        SystemNotificationPresenter,
        DetailedNotificationPermissionPresenter {
  NotificationPermissionState permission = const NotificationPermissionState(
      NotificationAuthorizationStatus.undetermined);
  int requests = 0;
  @override
  Future<NotificationPermissionState> permissionState() async => permission;
  @override
  Future<bool> requestAuthorization() async {
    requests++;
    permission = const NotificationPermissionState(
        NotificationAuthorizationStatus.granted,
        alertEnabled: true,
        soundEnabled: true,
        badgeEnabled: true);
    return true;
  }
}

class _Sound extends Fake implements SoundEngine {}

class _Haptic extends Fake implements HapticDriver {}

class _Badge extends Fake implements LauncherBadgeGateway {}

class _Events extends Fake implements NotificationEventSource {}

class _Unread extends Fake implements UnreadSnapshotSource {}

NotificationCoordinator _coordinator(_Presenter presenter) =>
    NotificationCoordinator(
      preferenceStore: const SharedPreferencesNotificationPreferenceStore(),
      systemNotifications: presenter,
      soundService: ForegroundSoundService(engine: _Sound()),
      hapticService: HapticService(driver: _Haptic()),
      badgeGateway: _Badge(),
      appState: AppStateManager(),
      banners: InAppBannerController(),
      eventSource: _Events(),
      unreadSource: _Unread(),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(
      {'notification.permission_prompted_v2': true}));
  testWidgets(
      'explicit notification settings action recovers an old prompted flag',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final presenter = _Presenter();
    await tester.pumpWidget(CupertinoApp(
        home: NotificationSettingsPage(coordinator: _coordinator(presenter))));
    await tester.pumpAndSettle();
    expect(presenter.requests, 0);
    await tester.tap(find.text('开启通知'));
    await tester.pumpAndSettle();
    expect(presenter.requests, 1);
    expect(find.text('开启系统通知'), findsNothing);
  });
  testWidgets(
      'settings return refreshes individual native presentation options without requesting',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final presenter = _Presenter()
      ..permission = const NotificationPermissionState(
          NotificationAuthorizationStatus.provisional,
          alertEnabled: false,
          soundEnabled: false,
          badgeEnabled: true);
    await tester.pumpWidget(CupertinoApp(
        home: NotificationSettingsPage(coordinator: _coordinator(presenter))));
    await tester.pumpAndSettle();
    expect(find.text('横幅：关闭 · 声音：关闭 · 角标：开启'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    presenter.permission = const NotificationPermissionState(
        NotificationAuthorizationStatus.granted,
        alertEnabled: true,
        soundEnabled: true,
        badgeEnabled: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('系统通知提醒未完全开启'), findsNothing);
    expect(presenter.requests, 0);
  });
  testWidgets(
      'denied settings action opens existing native settings gateway without requesting',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final presenter = _Presenter()
      ..permission = const NotificationPermissionState(
          NotificationAuthorizationStatus.denied);
    const channel = MethodChannel('chatflow/notification');
    var opens = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openNotificationSettings') {
        opens++;
        return true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(CupertinoApp(
        home: NotificationSettingsPage(coordinator: _coordinator(presenter))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('前往系统设置'));
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(presenter.requests, 0);
  });
}
