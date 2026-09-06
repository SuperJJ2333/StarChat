import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/app_state_manager.dart';
import 'package:liuhetong_mobile/core/notification/badge_service.dart';
import 'package:liuhetong_mobile/core/notification/foreground_sound_service.dart';
import 'package:liuhetong_mobile/core/notification/haptic_service.dart';
import 'package:liuhetong_mobile/core/notification/in_app_banner_controller.dart';
import 'package:liuhetong_mobile/core/notification/notification_coordinator.dart';
import 'package:liuhetong_mobile/core/notification/notification_decision.dart';
import 'package:liuhetong_mobile/core/notification/notification_event.dart';
import 'package:liuhetong_mobile/core/notification/notification_preferences.dart';
import 'package:liuhetong_mobile/core/notification/sound_cooldown_gate.dart';
import 'package:liuhetong_mobile/core/notification/sound_type.dart';
import 'package:liuhetong_mobile/core/notification/system_notification_presenter.dart';
import 'package:liuhetong_mobile/features/matrix/mute_exception_policy.dart';

IncomingNotification _incoming({
  String eventId = r'$ev1',
  String roomId = r'!room1',
  bool isOwnMessage = false,
  bool isCurrentConversation = false,
  MuteNotificationDecision muteDecision = MuteNotificationDecision.normal,
  bool isAttention = false,
  String preview = '晚上一起吃饭吗？',
}) =>
    IncomingNotification(
      event: NotificationEvent(
        eventId: eventId,
        conversationId: roomId,
        senderId: r'@peer',
        senderName: '张三',
        conversationName: '张三',
        messagePreview: preview,
        timestamp: DateTime(2026, 9, 3, 12),
      ),
      isOwnMessage: isOwnMessage,
      isCurrentConversation: isCurrentConversation,
      muteDecision: muteDecision,
      isAttention: isAttention,
    );

final class _FakePreferenceStore implements NotificationPreferenceStore {
  _FakePreferenceStore([this.values = const NotificationPreferenceValues()]);

  NotificationPreferenceValues values;

  @override
  Future<NotificationPreferenceValues> load() async => values;

  @override
  Future<void> save(NotificationPreferenceValues value) async {
    values = value;
  }
}

final class _FakeSystemPresenter implements SystemNotificationPresenter {
  final cancellations = <int>[];
  Future<void> Function()? beforeShow;
  final shows = <({
    int id,
    String title,
    String body,
    SystemNotificationChannel channel
  })>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestAuthorization() async => true;

  @override
  Future<NotificationAuthorizationStatus> authorizationStatus() async =>
      NotificationAuthorizationStatus.granted;

  @override
  Future<void> showConversationMessage({
    required int notificationId,
    required String title,
    required String body,
    required SystemNotificationChannel channel,
    required String roomIdPayload,
    String? avatarUrl,
    int? unreadCount,
  }) async {
    await beforeShow?.call();
    shows.add((
      id: notificationId,
      title: title,
      body: body,
      channel: channel,
    ));
  }

  @override
  Future<void> cancelConversation(int notificationId) async {
    cancellations.add(notificationId);
  }
}

final class _RecordingSoundEngine implements SoundEngine {
  final plays = <String>[];
  final loops = <String>[];
  int stopLoopCount = 0;

  @override
  Future<void> play(String assetPath, {double volume = 1.0}) async {
    plays.add(assetPath);
  }

  @override
  Future<void> playLoop(String assetPath) async {
    loops.add(assetPath);
  }

  @override
  Future<void> stopLoop() async {
    stopLoopCount++;
  }

  @override
  Future<void> dispose() async {}
}

final class _RecordingHapticDriver implements HapticDriver {
  final triggers = <HapticFeedbackKind>[];

  @override
  Future<void> trigger(HapticFeedbackKind kind) async {
    triggers.add(kind);
  }
}

final class _RecordingBadgeGateway implements LauncherBadgeGateway {
  int? lastCount;

  @override
  Future<void> updateCount(int count) async {
    lastCount = count;
  }
}

final class _FakeUnreadSource implements UnreadSnapshotSource {
  _FakeUnreadSource([this.snapshots = const []]);

  List<ConversationUnreadSnapshot> snapshots;

  @override
  Future<List<ConversationUnreadSnapshot>> load() async => snapshots;
}

final class _StreamEventSource implements NotificationEventSource {
  final _controller = StreamController<IncomingNotification>.broadcast();

  @override
  Stream<IncomingNotification> get events => _controller.stream;

  void emit(IncomingNotification notification) => _controller.add(notification);

  Future<void> close() => _controller.close();
}

NotificationCoordinator _buildCoordinator({
  required _RecordingSoundEngine engine,
  required _RecordingHapticDriver haptics,
  required _RecordingBadgeGateway badge,
  required _FakeSystemPresenter presenter,
  required _StreamEventSource source,
  required _FakePreferenceStore prefs,
  required _FakeUnreadSource unread,
  required AppStateManager appState,
  InAppBannerController? banners,
  SoundCooldownGate? cooldownGate,
}) =>
    NotificationCoordinator(
      preferenceStore: prefs,
      systemNotifications: presenter,
      soundService: ForegroundSoundService(engine: engine),
      hapticService: HapticService(driver: haptics),
      badgeGateway: badge,
      appState: appState,
      banners: banners ?? InAppBannerController(),
      eventSource: source,
      unreadSource: unread,
      cooldownGate: cooldownGate,
    );

/// 等待广播流事件与未 await 的 handleEvent 微任务完成。
Future<void> _drain() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  testWidgets('disposing cancels a pending push fallback', (tester) async {
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final coordinator = _buildCoordinator(
      engine: _RecordingSoundEngine(),
      haptics: _RecordingHapticDriver(),
      badge: _RecordingBadgeGateway(),
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(),
      unread: _FakeUnreadSource(),
      appState: AppStateManager()..updateLifecycle(AppRunState.background),
    );
    await coordinator.start();
    await coordinator.showPushWakeNotification();
    await tester.runAsync(() async {
      await coordinator.dispose();
      await source.close();
    });
    await tester.pump(const Duration(seconds: 6));
    expect(presenter.shows, isEmpty);
    expect(presenter.cancellations, contains(pushWakeNotificationId));
  });

  testWidgets(
      'call resolution cancels an in-flight fallback after show completes',
      (tester) async {
    final showing = Completer<void>();
    final presenter = _FakeSystemPresenter()..beforeShow = () => showing.future;
    final source = _StreamEventSource();
    final coordinator = _buildCoordinator(
      engine: _RecordingSoundEngine(),
      haptics: _RecordingHapticDriver(),
      badge: _RecordingBadgeGateway(),
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(),
      unread: _FakeUnreadSource(),
      appState: AppStateManager()..updateLifecycle(AppRunState.background),
    );
    await coordinator.start();
    await coordinator.showPushWakeNotification();
    await tester.pump(const Duration(seconds: 6));
    await coordinator.cancelPushWakeNotification();
    final cancelledBeforeShow = presenter.cancellations.length;
    showing.complete();
    await tester.pump();
    expect(presenter.shows, hasLength(1));
    expect(presenter.cancellations.length, cancelledBeforeShow + 1);
    expect(presenter.cancellations.last, pushWakeNotificationId);
    await tester.runAsync(() async {
      await coordinator.dispose();
      await source.close();
    });
  });

  testWidgets(
      'push wake waits for local sync and never duplicates an active call',
      (tester) async {
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final appState = AppStateManager()..updateLifecycle(AppRunState.background);
    final coordinator = _buildCoordinator(
      engine: _RecordingSoundEngine(),
      haptics: _RecordingHapticDriver(),
      badge: _RecordingBadgeGateway(),
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(),
      unread: _FakeUnreadSource(),
      appState: appState,
    );
    await coordinator.start();
    await coordinator.showPushWakeNotification();
    expect(presenter.shows, isEmpty, reason: 'an opaque wake is not a message');
    appState.setCallActive(true);
    await tester.pump(const Duration(seconds: 6));
    expect(presenter.shows, isEmpty);
    await coordinator.showPushWakeNotification();
    await tester.pump(const Duration(seconds: 6));
    expect(presenter.shows, isEmpty,
        reason: 'late wake must not duplicate call');
    await tester.runAsync(() async {
      await coordinator.dispose();
      await source.close();
    });
  });

  testWidgets('unresolved push retains bounded generic fallback',
      (tester) async {
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final coordinator = _buildCoordinator(
      engine: _RecordingSoundEngine(),
      haptics: _RecordingHapticDriver(),
      badge: _RecordingBadgeGateway(),
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(),
      unread: _FakeUnreadSource(),
      appState: AppStateManager()..updateLifecycle(AppRunState.background),
    );
    await coordinator.start();
    await coordinator.showPushWakeNotification();
    expect(presenter.shows, isEmpty);
    await tester.pump(const Duration(seconds: 6));
    expect(presenter.shows.single.id, pushWakeNotificationId);
    await tester.runAsync(() async {
      await coordinator.dispose();
      await source.close();
    });
  });

  testWidgets('resolved real message replaces pending generic wake',
      (tester) async {
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final coordinator = _buildCoordinator(
      engine: _RecordingSoundEngine(),
      haptics: _RecordingHapticDriver(),
      badge: _RecordingBadgeGateway(),
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(),
      unread: _FakeUnreadSource(),
      appState: AppStateManager()..updateLifecycle(AppRunState.background),
    );
    await coordinator.start();
    await coordinator.showPushWakeNotification();
    await coordinator.handleEvent(_incoming());
    await tester.pump(const Duration(seconds: 6));
    expect(presenter.shows, hasLength(1));
    expect(presenter.shows.single.id, notificationIdForConversation('!room1'));
    await tester.runAsync(() async {
      await coordinator.dispose();
      await source.close();
    });
  });

  test('前台普通消息：横幅 + 声音 + 轻震 + 角标，不出系统通知（PRD §18）', () async {
    final engine = _RecordingSoundEngine();
    final haptics = _RecordingHapticDriver();
    final badge = _RecordingBadgeGateway();
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final prefs = _FakePreferenceStore();
    final unread = _FakeUnreadSource(const [
      ConversationUnreadSnapshot(roomId: '!room1', unread: 1, isMuted: false),
    ]);
    final appState = AppStateManager()..updateLifecycle(AppRunState.foreground);
    final banners = InAppBannerController();
    final coordinator = _buildCoordinator(
      engine: engine,
      haptics: haptics,
      badge: badge,
      presenter: presenter,
      source: source,
      prefs: prefs,
      unread: unread,
      appState: appState,
      banners: banners,
    );
    await coordinator.start();
    source.emit(_incoming());
    await _drain();
    expect(banners.current, isNotNull);
    expect(engine.plays, [SoundType.messageReceived.assetPath]);
    expect(haptics.triggers, [HapticFeedbackKind.light]);
    expect(presenter.shows, isEmpty);
    expect(badge.lastCount, 1);
    await coordinator.dispose();
    await source.close();
  });

  test('后台消息：只出系统通知，Flutter 不播放声音（PRD §19）', () async {
    final engine = _RecordingSoundEngine();
    final haptics = _RecordingHapticDriver();
    final badge = _RecordingBadgeGateway();
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final appState = AppStateManager()..updateLifecycle(AppRunState.background);
    final coordinator = _buildCoordinator(
      engine: engine,
      haptics: haptics,
      badge: badge,
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(),
      unread: _FakeUnreadSource(),
      appState: appState,
    );
    await coordinator.start();
    source.emit(_incoming());
    await _drain();
    expect(presenter.shows, hasLength(1));
    expect(presenter.shows.single.channel, SystemNotificationChannel.messages);
    expect(presenter.shows.single.title, '张三');
    expect(presenter.shows.single.body, '晚上一起吃饭吗？');
    expect(engine.plays, isEmpty);
    expect(haptics.triggers, isEmpty);
    await coordinator.dispose();
    await source.close();
  });

  test('同一 eventId 双通道到达只提醒一次（PRD §25/§66）', () async {
    final engine = _RecordingSoundEngine();
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final appState = AppStateManager()..updateLifecycle(AppRunState.foreground);
    final coordinator = _buildCoordinator(
      engine: engine,
      haptics: _RecordingHapticDriver(),
      badge: _RecordingBadgeGateway(),
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(),
      unread: _FakeUnreadSource(),
      appState: appState,
    );
    await coordinator.start();
    source.emit(_incoming(eventId: r'$dup'));
    source.emit(_incoming(eventId: r'$dup'));
    await _drain();
    expect(engine.plays, hasLength(1));
    await coordinator.dispose();
    await source.close();
  });

  test('同一会话 2 秒内多条消息只响一声（PRD §41）', () async {
    final engine = _RecordingSoundEngine();
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final appState = AppStateManager()..updateLifecycle(AppRunState.foreground);
    var clock = DateTime(2026, 9, 3, 12);
    final coordinator = _buildCoordinator(
      engine: engine,
      haptics: _RecordingHapticDriver(),
      badge: _RecordingBadgeGateway(),
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(),
      unread: _FakeUnreadSource(),
      appState: appState,
      cooldownGate: SoundCooldownGate(now: () => clock),
    );
    await coordinator.start();
    source.emit(_incoming(eventId: r'$e1'));
    await _drain();
    clock = clock.add(const Duration(milliseconds: 300));
    source.emit(_incoming(eventId: r'$e2'));
    await _drain();
    expect(engine.plays, hasLength(1));
    await coordinator.dispose();
    await source.close();
  });

  test('隐私模式传导到系统通知正文（PRD §45）', () async {
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final appState = AppStateManager()..updateLifecycle(AppRunState.background);
    final coordinator = _buildCoordinator(
      engine: _RecordingSoundEngine(),
      haptics: _RecordingHapticDriver(),
      badge: _RecordingBadgeGateway(),
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(
        const NotificationPreferenceValues(
          previewPrivacy: NotificationPrivacyLevel.hideAll,
        ),
      ),
      unread: _FakeUnreadSource(),
      appState: appState,
    );
    await coordinator.start();
    source.emit(_incoming());
    await _drain();
    expect(presenter.shows.single.title, '畅聊');
    expect(presenter.shows.single.body, '新消息');
    await coordinator.dispose();
    await source.close();
  });

  test('自己消息不触发任何提醒也不刷新角标（PRD §52）', () async {
    final engine = _RecordingSoundEngine();
    final badge = _RecordingBadgeGateway();
    final source = _StreamEventSource();
    final appState = AppStateManager()..updateLifecycle(AppRunState.foreground);
    final banners = InAppBannerController();
    final coordinator = _buildCoordinator(
      engine: engine,
      haptics: _RecordingHapticDriver(),
      badge: badge,
      presenter: _FakeSystemPresenter(),
      source: source,
      prefs: _FakePreferenceStore(),
      unread: _FakeUnreadSource(const [
        ConversationUnreadSnapshot(roomId: '!room1', unread: 0, isMuted: false),
      ]),
      appState: appState,
      banners: banners,
    );
    await coordinator.start();
    source.emit(_incoming(isOwnMessage: true));
    await _drain();
    expect(banners.current, isNull);
    expect(engine.plays, isEmpty);
    expect(badge.lastCount, isNull);
    await coordinator.dispose();
    await source.close();
  });
}
