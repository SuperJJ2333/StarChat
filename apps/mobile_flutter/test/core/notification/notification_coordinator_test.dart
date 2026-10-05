import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/push/native_message_policy.dart';
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
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';

IncomingNotification _incoming({
  String eventId = r'$ev1',
  String roomId = r'!room1',
  bool isOwnMessage = false,
  bool isCurrentConversation = false,
  MuteNotificationDecision muteDecision = MuteNotificationDecision.normal,
  bool isAttention = false,
  String preview = '晚上一起吃饭吗？',
  String? avatarUrl,
}) =>
    IncomingNotification(
      event: NotificationEvent(
        eventId: eventId,
        conversationId: roomId,
        senderId: r'@peer',
        senderName: '张三',
        conversationName: '张三',
        messagePreview: preview,
        avatarUrl: avatarUrl,
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

final class _FakeSystemPresenter
    implements
        SystemNotificationPresenter,
        DeliveredConversationNotificationPresenter {
  final cancellations = <int>[];
  final deliveredCancellations = <String>[];
  Future<void> Function()? beforeShow;
  Future<void> Function()? beforeCancel;
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
    await beforeCancel?.call();
    cancellations.add(notificationId);
  }

  @override
  Future<void> cancelDeliveredConversation(String roomId) async {
    deliveredCancellations.add(roomId);
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
  Future<List<ConversationUnreadSnapshot>> Function()? onLoad;

  @override
  Future<List<ConversationUnreadSnapshot>> load() async =>
      onLoad == null ? snapshots : await onLoad!();
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
  NativeMessagePolicy? nativePolicy,
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
      nativePolicy: nativePolicy,
    );

/// 等待广播流事件与未 await 的 handleEvent 微任务完成。
Future<void> _drain() => Future<void>.delayed(const Duration(milliseconds: 20));

// Stream cancellation returns Dart's completed root-zone future, while queued
// writes belong to Flutter's fake zone. Drain both queues with a bounded loop
// before awaiting real cleanup; neither runAsync nor pump alone drains both.
Future<void> _disposeWidgetCoordinator(
  WidgetTester tester,
  NotificationCoordinator coordinator,
  _StreamEventSource source,
) async {
  var disposed = false;
  final disposing = coordinator.dispose().then((_) => disposed = true);
  for (var i = 0; i < 4 && !disposed; i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(disposed, isTrue, reason: 'fake notification disposal must drain');
  await disposing;
  var closed = false;
  final closing = source.close().then((_) => closed = true);
  for (var i = 0; i < 4 && !closed; i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(closed, isTrue, reason: 'fake notification stream must close');
  await closing;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('queued exact old read rechecks current presented ID after newer show',
      () async {
    final reads = ConversationReadState.shared()..resetForTest();
    reads.bindAccount('@queued');
    final oldEntered = Completer<void>();
    final oldRelease = Completer<void>();
    var showCount = 0;
    final presenter = _FakeSystemPresenter()
      ..beforeShow = () async {
        if (++showCount == 1) {
          oldEntered.complete();
          await oldRelease.future;
        }
      };
    final source = _StreamEventSource();
    final coordinator = _buildCoordinator(
        engine: _RecordingSoundEngine(),
        haptics: _RecordingHapticDriver(),
        badge: _RecordingBadgeGateway(),
        presenter: presenter,
        source: source,
        prefs: _FakePreferenceStore(),
        unread: _FakeUnreadSource(),
        appState: AppStateManager()..updateLifecycle(AppRunState.background));
    await coordinator.start();
    final oldShow =
        coordinator.handleEvent(_incoming(roomId: 'A', eventId: 'old'));
    await oldEntered.future;
    final newShow =
        coordinator.handleEvent(_incoming(roomId: 'A', eventId: 'new'));
    await _drain(); // The newer show queues before the exact old-read cancellation.
    reads.markCleared('A', eventId: 'old');
    oldRelease.complete();
    await oldShow;
    await newShow;
    await _drain();
    expect(presenter.shows, hasLength(2));
    expect(
        presenter.cancellations
            .where((id) => id == notificationIdForConversation('A')),
        hasLength(1),
        reason:
            'retire in-flight old show only; queued cancellation must preserve new show');
    await coordinator.dispose();
    await source.close();
    reads.resetForTest();
  });
  test('delivered new notification survives unrelated delayed old read',
      () async {
    final reads = ConversationReadState.shared()..resetForTest();
    reads.bindAccount('@mixed');
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
        appState: AppStateManager()..updateLifecycle(AppRunState.background));
    await coordinator.start();
    await coordinator.handleEvent(_incoming(roomId: 'A', eventId: 'new'));
    reads.observeTimeline('A', ['old'], viewing: false);
    reads.markCleared('A', eventId: 'old', updateUnreadMarker: false);
    await _drain();
    expect(presenter.shows, hasLength(1));
    expect(presenter.cancellations,
        isNot(contains(notificationIdForConversation('A'))),
        reason: 'exact old receipt must not cancel displayed new event');
    await coordinator.dispose();
    await source.close();
    reads.resetForTest();
  });
  test('background mounted room late exact read never bridges open viewing',
      () async {
    final reads = ConversationReadState.shared()..resetForTest();
    reads.bindAccount('@mixed');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridgeReads = <Map>[];
    messenger.setMockMethodCallHandler(NativeMessagePolicy.channel,
        (call) async {
      if (call.method == 'bind') {
        return {'scope': 'a'.padRight(64, 'a'), 'revision': 0};
      }
      if (call.method == 'readRoom') bridgeReads.add(call.arguments as Map);
      return true;
    });
    final policy = NativeMessagePolicy(enabled: true);
    await policy.prepare('@mixed', const NotificationPreferenceValues());
    final source = _StreamEventSource();
    final coordinator = _buildCoordinator(
        engine: _RecordingSoundEngine(),
        haptics: _RecordingHapticDriver(),
        badge: _RecordingBadgeGateway(),
        presenter: _FakeSystemPresenter(),
        source: source,
        prefs: _FakePreferenceStore(),
        unread: _FakeUnreadSource(),
        nativePolicy: policy,
        appState: AppStateManager()..updateLifecycle(AppRunState.background));
    await coordinator.start();
    reads.setRoomOpen('A', open: true);
    reads.markCleared('A', eventId: 'old');
    await _drain();
    expect(bridgeReads, isNotEmpty);
    expect(bridgeReads.last['open'], isFalse,
        reason: 'background old read cannot bulk retire pending future push');
    await coordinator.dispose();
    await source.close();
    reads.resetForTest();
    messenger.setMockMethodCallHandler(NativeMessagePolicy.channel, null);
  });
  test('new background event still notifies when chat page remains mounted',
      () async {
    final reads = ConversationReadState.shared()..resetForTest();
    reads.bindAccount('@background');
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final state = AppStateManager();
    final coordinator = _buildCoordinator(
        engine: _RecordingSoundEngine(),
        haptics: _RecordingHapticDriver(),
        badge: _RecordingBadgeGateway(),
        presenter: presenter,
        source: source,
        prefs: _FakePreferenceStore(),
        unread: _FakeUnreadSource(),
        appState: state);
    await coordinator.start();
    reads.setRoomOpen('A', open: true);
    reads.markCleared('A', eventId: 'old');
    await _drain();
    state.updateLifecycle(AppRunState.background);
    await coordinator.handleEvent(
        _incoming(roomId: 'A', eventId: 'new', isCurrentConversation: true));
    expect(presenter.shows, hasLength(1));
    await coordinator.dispose();
    await source.close();
    reads.resetForTest();
  });
  test('viewed event never replays after leaving room but new event notifies',
      () async {
    final reads = ConversationReadState.shared()..resetForTest();
    reads.bindAccount('@read-test');
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
    reads.setRoomOpen('A', open: true);
    reads.markCleared('A', eventId: 'old');
    reads.setRoomOpen('A', open: false);
    await coordinator.handleEvent(_incoming(roomId: 'A', eventId: 'old'));
    expect(presenter.shows, isEmpty);
    await coordinator.handleEvent(_incoming(roomId: 'A', eventId: 'new'));
    expect(presenter.shows, hasLength(1));
    await coordinator.dispose();
    await source.close();
    reads.resetForTest();
  });
  test('foreground banner carries conversation avatar', () async {
    final reads = ConversationReadState.shared()..resetForTest();
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final banners = InAppBannerController();
    final coordinator = _buildCoordinator(
      engine: _RecordingSoundEngine(),
      haptics: _RecordingHapticDriver(),
      badge: _RecordingBadgeGateway(),
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(),
      unread: _FakeUnreadSource(),
      appState: AppStateManager(),
      banners: banners,
    );
    await coordinator.start();
    await coordinator
        .handleEvent(_incoming(avatarUrl: 'https://example.test/avatar'));
    expect(banners.current?.avatarUrl, 'https://example.test/avatar');
    await coordinator.dispose();
    await source.close();
    reads.resetForTest();
  });
  test('held native ACK across policy change cannot leak foreground effects',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final beginReply = Completer<String>();
    final beginEntered = Completer<void>();
    final installReply = Completer<bool>();
    final installEntered = Completer<void>();
    var changingPolicy = false;
    var abandoned = false;
    messenger.setMockMethodCallHandler(NativeMessagePolicy.channel,
        (call) async {
      if (call.method == 'bind') return {'scope': 'a' * 64, 'revision': 0};
      if (call.method == 'beginForeground') {
        beginEntered.complete();
        return beginReply.future;
      }
      if (call.method == 'install' && changingPolicy) {
        installEntered.complete();
        return installReply.future;
      }
      if (call.method == 'finishForeground') {
        abandoned = (call.arguments as Map)['handled'] == false;
      }
      return true;
    });
    final policy = NativeMessagePolicy(enabled: true);
    await policy.prepare('account', const NotificationPreferenceValues());
    final engine = _RecordingSoundEngine();
    final haptics = _RecordingHapticDriver();
    final banners = InAppBannerController();
    final source = _StreamEventSource();
    final coordinator = _buildCoordinator(
        engine: engine,
        haptics: haptics,
        badge: _RecordingBadgeGateway(),
        presenter: _FakeSystemPresenter(),
        source: source,
        prefs: _FakePreferenceStore(),
        unread: _FakeUnreadSource(),
        appState: AppStateManager(),
        banners: banners,
        nativePolicy: policy);
    await coordinator.start();
    final handling = coordinator.handleEvent(_incoming());
    await beginEntered.future;
    changingPolicy = true;
    final updating = policy.updatePreferences(
        const NotificationPreferenceValues(soundEnabled: false));
    await installEntered.future;
    beginReply.complete('attempt-1');
    await handling;
    expect(abandoned, true);
    expect(banners.current, isNull);
    expect(engine.plays, isEmpty);
    expect(haptics.triggers, isEmpty);
    installReply.complete(true);
    await updating;
    await coordinator.dispose();
    await source.close();
    messenger.setMockMethodCallHandler(NativeMessagePolicy.channel, null);
  });
  for (final takeover in [true, false]) {
    test(
        'delayed foreground badge respects native ownership takeover=$takeover',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var nativeDisplayed = false;
      var claimActive = false;
      messenger.setMockMethodCallHandler(NativeMessagePolicy.channel,
          (call) async {
        if (call.method == 'bind') return {'scope': 'a' * 64, 'revision': 0};
        if (call.method == 'claim') {
          claimActive = true;
          return true;
        }
        if (call.method == 'beginForeground') {
          if (!claimActive || nativeDisplayed) return null;
          claimActive = false;
          return 'lease-1';
        }
        return true;
      });
      final policy = NativeMessagePolicy(enabled: true);
      await policy.prepare('account', const NotificationPreferenceValues());
      final release = Completer<List<ConversationUnreadSnapshot>>();
      final entered = Completer<void>();
      final unread = _FakeUnreadSource()
        ..onLoad = () {
          if (!entered.isCompleted) entered.complete();
          return release.future;
        };
      final engine = _RecordingSoundEngine();
      final haptics = _RecordingHapticDriver();
      final badge = _RecordingBadgeGateway();
      final banners = InAppBannerController();
      final state = AppStateManager();
      final source = _StreamEventSource();
      final coordinator = _buildCoordinator(
          engine: engine,
          haptics: haptics,
          badge: badge,
          presenter: _FakeSystemPresenter(),
          source: source,
          prefs: _FakePreferenceStore(),
          unread: unread,
          appState: state,
          banners: banners,
          nativePolicy: policy);
      await coordinator.start();
      final handling = coordinator.handleEvent(_incoming());
      await entered.future;
      expect(claimActive, true);
      if (takeover) {
        // Native expired reservation then displayed while Flutter awaited badge.
        state.updateLifecycle(AppRunState.background);
        claimActive = false;
        nativeDisplayed = true;
        // Returning foreground does not restore the expired event's ownership.
        state.updateLifecycle(AppRunState.foreground);
      }
      release.complete(const [
        ConversationUnreadSnapshot(roomId: '!room1', unread: 1, isMuted: false)
      ]);
      await handling;
      expect(badge.lastCount, 1);
      expect(banners.current == null, takeover);
      expect(engine.plays.isEmpty, takeover);
      expect(haptics.triggers.isEmpty, takeover);
      await coordinator.dispose();
      await source.close();
      messenger.setMockMethodCallHandler(NativeMessagePolicy.channel, null);
    });
  }
  test('account switch stops a delayed native notification cancellation',
      () async {
    final reads = ConversationReadState.shared()..resetForTest();
    reads.bindAccount('@A');
    final cancelling = Completer<void>();
    final entered = Completer<void>();
    final presenter = _FakeSystemPresenter()
      ..beforeCancel = () {
        entered.complete();
        return cancelling.future;
      };
    final source = _StreamEventSource();
    final coordinator = _buildCoordinator(
      engine: _RecordingSoundEngine(),
      haptics: _RecordingHapticDriver(),
      badge: _RecordingBadgeGateway(),
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(),
      unread: _FakeUnreadSource(),
      appState: AppStateManager(),
    );
    await coordinator.start();
    reads.setRoomOpen('A', open: true);
    await entered.future;
    reads.bindAccount('@B');
    cancelling.complete();
    await _drain();
    expect(presenter.deliveredCancellations, isEmpty);
    await coordinator.dispose();
    await source.close();
    reads.resetForTest();
  });
  test('opening a room from the app clears only its alert and badge', () async {
    final readState = ConversationReadState.shared()..resetForTest();
    readState.bindAccount('@notification-test');
    final presenter = _FakeSystemPresenter();
    final source = _StreamEventSource();
    final badge = _RecordingBadgeGateway();
    final unread = _FakeUnreadSource(const [
      ConversationUnreadSnapshot(roomId: 'A', unread: 7, isMuted: false),
      ConversationUnreadSnapshot(roomId: 'B', unread: 2, isMuted: false),
    ]);
    final coordinator = _buildCoordinator(
      engine: _RecordingSoundEngine(),
      haptics: _RecordingHapticDriver(),
      badge: badge,
      presenter: presenter,
      source: source,
      prefs: _FakePreferenceStore(),
      unread: unread,
      appState: AppStateManager(),
    );
    await coordinator.start();
    await coordinator.refreshLauncherBadge();
    expect(badge.lastCount, 9);
    // MatrixUnreadSnapshotSource applies the local read suppression immediately.
    unread.snapshots = const [
      ConversationUnreadSnapshot(roomId: 'A', unread: 0, isMuted: false),
      ConversationUnreadSnapshot(roomId: 'B', unread: 2, isMuted: false),
    ];
    readState.setRoomOpen('A', open: true);
    await _drain();
    await _drain();
    expect(
        presenter.cancellations, contains(notificationIdForConversation('A')));
    expect(presenter.cancellations,
        isNot(contains(notificationIdForConversation('B'))));
    expect(badge.lastCount, 2);
    expect(presenter.deliveredCancellations, ['A']);
    await coordinator.dispose();
    await source.close();
    readState.resetForTest();
  });

  test('an in-flight notification cannot reappear after opening its room',
      () async {
    final reads = ConversationReadState.shared()..resetForTest();
    reads.bindAccount('@test');
    final showing = Completer<void>();
    final startedShowing = Completer<void>();
    final presenter = _FakeSystemPresenter()
      ..beforeShow = () {
        startedShowing.complete();
        return showing.future;
      };
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
    final pending = coordinator.handleEvent(_incoming(roomId: 'A'));
    await startedShowing.future;
    reads.setRoomOpen('A', open: true);
    showing.complete();
    await pending;
    await _drain();
    expect(presenter.shows, hasLength(1));
    expect(presenter.cancellations.last, notificationIdForConversation('A'));
    expect(presenter.deliveredCancellations, everyElement('A'));
    await coordinator.dispose();
    await source.close();
    reads.resetForTest();
  });

  test('old badge snapshots cannot overwrite newer reads or another account',
      () async {
    final reads = ConversationReadState.shared()..resetForTest();
    reads.bindAccount('@first');
    final unread = _FakeUnreadSource();
    final stale = Completer<List<ConversationUnreadSnapshot>>();
    unread.onLoad = () => stale.future;
    final source = _StreamEventSource();
    final badge = _RecordingBadgeGateway();
    final coordinator = _buildCoordinator(
      engine: _RecordingSoundEngine(),
      haptics: _RecordingHapticDriver(),
      badge: badge,
      presenter: _FakeSystemPresenter(),
      source: source,
      prefs: _FakePreferenceStore(),
      unread: unread,
      appState: AppStateManager(),
    );
    await coordinator.start();
    final old = coordinator.refreshLauncherBadge();
    unread.onLoad = null;
    unread.snapshots = const [
      ConversationUnreadSnapshot(roomId: 'B', unread: 2, isMuted: false)
    ];
    reads.setRoomOpen('A', open: true);
    await _drain();
    expect(badge.lastCount, 2);
    stale.complete(const [
      ConversationUnreadSnapshot(roomId: 'A', unread: 9, isMuted: false)
    ]);
    await old;
    expect(badge.lastCount, 2);
    final other = Completer<List<ConversationUnreadSnapshot>>();
    unread.onLoad = () => other.future;
    final oldAccount = coordinator.refreshLauncherBadge();
    reads.bindAccount('@second');
    other.complete(const [
      ConversationUnreadSnapshot(roomId: 'A', unread: 99, isMuted: false)
    ]);
    await oldAccount;
    expect(badge.lastCount, 2);
    await coordinator.dispose();
    await source.close();
    reads.resetForTest();
  });

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
    await _disposeWidgetCoordinator(tester, coordinator, source);
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
    await _disposeWidgetCoordinator(tester, coordinator, source);
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
    await _disposeWidgetCoordinator(tester, coordinator, source);
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
    await _disposeWidgetCoordinator(tester, coordinator, source);
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
    await _disposeWidgetCoordinator(tester, coordinator, source);
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
