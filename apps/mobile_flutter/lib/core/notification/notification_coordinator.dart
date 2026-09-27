import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'app_state_manager.dart';
import 'badge_service.dart';
import 'foreground_sound_service.dart';
import 'haptic_service.dart';
import 'in_app_banner_controller.dart';
import 'notification_decision.dart';
import 'notification_deduplicator.dart';
import 'notification_diagnostics.dart';
import 'notification_event.dart';
import 'notification_policy_engine.dart';
import 'notification_preferences.dart';
import 'notification_usage_recorder.dart';
import 'sound_cooldown_gate.dart';
import 'sound_type.dart';
import 'system_notification_presenter.dart';

import '../../features/matrix/mute_exception_policy.dart';
import '../../features/matrix/conversation_read_state.dart';

/// Matrix 同步侧预计算后的入站通知事实。
final class IncomingNotification {
  const IncomingNotification({
    required this.event,
    required this.isOwnMessage,
    required this.isCurrentConversation,
    required this.muteDecision,
    required this.isAttention,
  });

  final NotificationEvent event;
  final bool isOwnMessage;
  final bool isCurrentConversation;
  final MuteNotificationDecision muteDecision;
  final bool isAttention;
}

/// 入站事件来源（由 Matrix 适配层实现，隔离 SDK 依赖便于测试）。
abstract interface class NotificationEventSource {
  Stream<IncomingNotification> get events;
}

/// 通知协调器（PRD §2）：所有通知/声音/震动/角标/系统通知的唯一入口。
///
/// 链路：事件 → 去重（§25）→ 策略（§22）→ 冷却（§41）→ 执行
/// （横幅 / 前台声音 / 震动 / 系统通知 / 角标）。
final class NotificationCoordinator {
  NotificationCoordinator({
    required this.preferenceStore,
    required this.systemNotifications,
    required this.soundService,
    required this.hapticService,
    required this.badgeGateway,
    required this.appState,
    required this.banners,
    required this.eventSource,
    required this.unreadSource,
    NotificationDeduplicator? deduplicator,
    SoundCooldownGate? cooldownGate,
    NotificationUsageRecorder? usageRecorder,
    NotificationDiagnostics? diagnostics,
    ConversationReadState? readState,
    DateTime Function()? now,
  })  : deduplicator = deduplicator ?? NotificationDeduplicator(),
        cooldownGate = cooldownGate ?? SoundCooldownGate(),
        usageRecorder =
            usageRecorder ?? const SharedPreferencesNotificationUsageRecorder(),
        diagnostics = diagnostics ?? NotificationDiagnostics.shared,
        readState = readState ?? ConversationReadState.shared(),
        now = now ?? DateTime.now;

  final NotificationPreferenceStore preferenceStore;
  final SystemNotificationPresenter systemNotifications;
  final ForegroundSoundService soundService;
  final HapticService hapticService;
  final LauncherBadgeGateway badgeGateway;
  final AppStateManager appState;
  final InAppBannerController banners;
  final NotificationEventSource eventSource;
  final UnreadSnapshotSource unreadSource;
  final NotificationDeduplicator deduplicator;
  final SoundCooldownGate cooldownGate;
  final NotificationUsageRecorder usageRecorder;
  final NotificationDiagnostics diagnostics;
  final DateTime Function() now;
  final ConversationReadState readState;

  NotificationPreferenceValues _prefs = const NotificationPreferenceValues();

  /// 当前偏好快照（设置页/通话铃声开关读取）。
  NotificationPreferenceValues get preferences => _prefs;

  StreamSubscription<IncomingNotification>? _subscription;
  bool _started = false;
  Timer? _pushWakeTimer;
  int _pushWakeGeneration = 0;
  StreamSubscription<ConversationReadChange>? _readSubscription;
  String? _readAccount;
  int _epoch = 0;
  int _badgeGeneration = 0;
  Future<void> _badgeWrites = Future<void>.value();
  final Map<String, int> _roomRevisions = {};
  final Map<String, Future<void>> _roomWrites = {};

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _prefs = await preferenceStore.load();
    await systemNotifications.initialize();
    _readAccount = readState.accountId;
    _readSubscription = readState.changes.listen(_onReadChange);
    _subscription = eventSource.events.listen(
      (notification) => unawaited(handleEvent(notification)),
    );
    for (final roomId in readState.openRoomIds) {
      _onReadChange(ConversationReadChange(
          accountId: _readAccount, roomId: roomId, isOpen: true));
    }
  }

  void _onReadChange(ConversationReadChange change) {
    if (!_started) return;
    if (change.accountId != _readAccount) {
      ++_epoch;
      ++_badgeGeneration;
      return;
    }
    final roomId = change.roomId;
    // Viewing already suppresses alerts and unread counts. Receipt updates
    // inside that room must not rescan all conversations for every message.
    if (change.cleared && change.isOpen) return;
    if (roomId != null) {
      _roomRevisions[roomId] = (_roomRevisions[roomId] ?? 0) + 1;
      if (change.isOpen || change.cleared) {
        unawaited(_writeRoom(roomId, (epoch) => _cancelRoom(roomId, epoch)));
      }
    }
    unawaited(refreshLauncherBadge());
  }

  bool _isCurrent(int epoch) =>
      _started && epoch == _epoch && readState.accountId == _readAccount;

  Future<void> _cancelRoom(String roomId, int epoch) async {
    if (!_isCurrent(epoch)) return;
    await systemNotifications
        .cancelConversation(notificationIdForConversation(roomId));
    if (!_isCurrent(epoch)) return;
    final presenter = systemNotifications;
    if (presenter is DeliveredConversationNotificationPresenter) {
      await (presenter as DeliveredConversationNotificationPresenter)
          .cancelDeliveredConversation(roomId);
    }
  }

  Future<void> _writeRoom(String roomId, Future<void> Function(int) action) {
    final epoch = _epoch;
    final prior = _roomWrites[roomId] ?? Future<void>.value();
    late final Future<void> flight;
    flight = prior.then((_) async {
      if (!_started || epoch != _epoch || readState.accountId != _readAccount) {
        return;
      }
      await action(epoch);
    }).catchError((Object error) {
      diagnostics.record(NotificationDiagStage.suppressed,
          'room reconciliation failed: ${error.runtimeType}');
    }).whenComplete(() {
      if (identical(_roomWrites[roomId], flight)) _roomWrites.remove(roomId);
    });
    _roomWrites[roomId] = flight;
    return flight;
  }

  /// 设置页更新偏好后同步内存快照（PRD §38 即时生效）。
  Future<void> updatePreferences(NotificationPreferenceValues values) async {
    _prefs = values;
    await preferenceStore.save(values);
    if (values.badgeEnabled) {
      await refreshLauncherBadge();
    } else {
      await badgeGateway.updateCount(0);
    }
  }

  Future<void> handleEvent(IncomingNotification notification) async {
    if (!notification.isOwnMessage) await cancelPushWakeNotification();
    debugPrint('[PUSH] received event room='
        '${notification.event.conversationId} kind='
        '${notification.event.messageKind.name}');
    // PRD §25/§66：同一 eventId 双通道只处理一次。
    if (!deduplicator.tryProcess(notification.event.eventId)) {
      diagnostics.record(NotificationDiagStage.suppressed, 'duplicate',
          eventId: notification.event.eventId,
          roomId: notification.event.conversationId);
      return;
    }
    unawaited(usageRecorder.count(NotificationUsageEvents.received));

    final event = notification.event;
    final decision = decideNotification(
      NotificationPolicyContext(
        appForeground: appState.isForeground,
        isOwnMessage: notification.isOwnMessage,
        isCurrentConversation: notification.isCurrentConversation,
        muteDecision: notification.muteDecision,
        isMention: event.isMention,
        isAttention: notification.isAttention,
        callActive: appState.callActive,
        prefs: _prefs,
        event: event,
        now: now(),
      ),
    );
    _diagnoseDecision(decision, notification);
    await _execute(decision, event);
  }

  /// 策略结果诊断：说明事件是否被抑制、被什么抑制（不含正文）。
  void _diagnoseDecision(
    NotificationDecision decision,
    IncomingNotification notification,
  ) {
    final event = notification.event;
    if (!decision.showInAppBanner &&
        !decision.showSystemNotification &&
        !decision.playSound) {
      diagnostics.record(
        NotificationDiagStage.suppressed,
        _suppressionReason(notification),
        eventId: event.eventId,
        roomId: event.conversationId,
      );
      return;
    }
    diagnostics.record(
      NotificationDiagStage.policy,
      decision.showSystemNotification
          ? decision.systemChannel == SystemNotificationChannel.silent
              ? 'background → silent channel'
              : 'background → ${decision.systemChannel.name}'
          : 'foreground feedback (banner=${decision.showInAppBanner}, '
              'sound=${decision.playSound})',
      eventId: event.eventId,
      roomId: event.conversationId,
    );
  }

  String _suppressionReason(IncomingNotification notification) {
    if (notification.isOwnMessage) return 'own message';
    if (notification.isCurrentConversation) return 'current conversation open';
    if (appState.callActive) return 'call active';
    if (notification.muteDecision == MuteNotificationDecision.suppressed) {
      return 'muted';
    }
    if (!_prefs.messageNotificationEnabled) return 'master switch off';
    if (isWithinDndWindow(_prefs, now())) return 'dnd window';
    return 'none';
  }

  Future<void> _execute(
    NotificationDecision decision,
    NotificationEvent event,
  ) async {
    final roomRevision = _roomRevisions[event.conversationId] ?? 0;
    if (decision.updateBadge) {
      await refreshLauncherBadge();
    }
    if (decision.showInAppBanner) {
      unawaited(usageRecorder.count(NotificationUsageEvents.displayed));
      banners.present(
        InAppBannerItem(
          id: event.eventId,
          conversationId: event.conversationId,
          title: decision.previewTitle,
          body: decision.previewBody,
          avatarUrl: null,
          timestamp: event.timestamp,
        ),
      );
    }
    if (decision.playSound && decision.soundType != null) {
      // PRD §41：声音冷却（同一会话 2s / 全局 600ms）。
      if (cooldownGate.shouldPlaySound(event.conversationId)) {
        await soundService.play(decision.soundType!);
      }
    }
    if (decision.haptic != HapticFeedbackKind.none) {
      await hapticService.trigger(decision.haptic);
    }
    if (decision.showSystemNotification) {
      unawaited(usageRecorder.count(NotificationUsageEvents.displayed));
      final unreadCount = await _unreadForRoom(event.conversationId);
      await _writeRoom(event.conversationId, (epoch) async {
        if (readState.isRoomOpen(event.conversationId) ||
            (_roomRevisions[event.conversationId] ?? 0) != roomRevision) {
          return;
        }
        await systemNotifications.showConversationMessage(
          notificationId: notificationIdForConversation(event.conversationId),
          title: decision.previewTitle,
          body: decision.previewBody,
          channel: decision.systemChannel,
          roomIdPayload: event.conversationId,
          avatarUrl: event.avatarUrl,
          unreadCount: unreadCount,
        );
        if (readState.isRoomOpen(event.conversationId) ||
            (_roomRevisions[event.conversationId] ?? 0) != roomRevision) {
          await _cancelRoom(event.conversationId, epoch);
        }
      });
    }
  }

  /// 该会话当前未读数（含本条，服务器计数+1；失败不阻塞通知）。
  Future<int?> _unreadForRoom(String roomId) async {
    try {
      final snapshots = await unreadSource.load();
      for (final snapshot in snapshots) {
        if (snapshot.roomId == roomId && snapshot.unread > 0) {
          return snapshot.unread;
        }
      }
      return 1;
    } catch (_) {
      return null;
    }
  }

  /// PRD §36：角标以服务器未读为事实来源，聚合后整笔刷新（不做 badge++）。
  Future<void> refreshLauncherBadge() async {
    if (!_prefs.badgeEnabled) return;
    final generation = ++_badgeGeneration;
    final epoch = _epoch;
    try {
      final snapshots = await unreadSource.load();
      if (generation != _badgeGeneration ||
          epoch != _epoch ||
          readState.accountId != _readAccount) {
        return;
      }
      final total =
          aggregateLauncherBadge(prefs: _prefs, conversations: snapshots);
      final write = _badgeWrites.then((_) async {
        if (generation != _badgeGeneration ||
            epoch != _epoch ||
            readState.accountId != _readAccount) {
          return;
        }
        await badgeGateway.updateCount(total);
      });
      _badgeWrites = write.catchError((Object _) {});
      await write;
    } catch (_) {
      // 快照加载失败保留上次角标；下次事件或前台同步会重新对齐。
    }
  }

  /// 纯前台 UI 反馈音（发送成功 / 红包开启 / 扫码，PRD §26）。
  /// 业务页面经由 [NotificationFeedback] 间接调用，不直接触碰引擎。
  Future<void> playUiSound(SoundType type) async {
    if (!_prefs.soundEnabled) return;
    await soundService.play(type);
  }

  /// Opaque push wakes cannot distinguish encrypted calls from messages.
  /// Give local sync/decryption a bounded opportunity to present the real event;
  /// retain a generic fallback if the event cannot be resolved.
  Future<void> showPushWakeNotification() async {
    if (!_started || appState.callActive || _pushWakeTimer != null) return;
    final generation = ++_pushWakeGeneration;
    _pushWakeTimer = Timer(const Duration(seconds: 5), () {
      _pushWakeTimer = null;
      unawaited(_showUnresolvedPushWake(generation));
    });
  }

  /// Called when Matrix resolves a message or an incoming call. Cancels only
  /// the opaque fallback, never another conversation's actual message alert.
  Future<void> cancelPushWakeNotification() async {
    ++_pushWakeGeneration;
    _pushWakeTimer?.cancel();
    _pushWakeTimer = null;
    try {
      await systemNotifications.cancelConversation(pushWakeNotificationId);
    } catch (error) {
      diagnostics.record(NotificationDiagStage.suppressed,
          'wake cancellation failed: ${error.runtimeType}');
    }
  }

  Future<void> _showUnresolvedPushWake(int generation) async {
    if (!_started || generation != _pushWakeGeneration || appState.callActive) {
      return;
    }
    debugPrint('[PUSH] show notification id=$pushWakeNotificationId '
        'channel=wake (push wakeup fallback)');
    await systemNotifications.showConversationMessage(
      notificationId: pushWakeNotificationId,
      title: '畅聊',
      body: '您有一条新消息',
      channel: SystemNotificationChannel.silent,
      roomIdPayload: '',
    );
    // A call can resolve while the platform show is in flight. Remove the
    // completed stale fallback too, rather than resurrecting it after cancel.
    if (!_started || generation != _pushWakeGeneration || appState.callActive) {
      await systemNotifications.cancelConversation(pushWakeNotificationId);
    }
  }

  Future<void> dispose() async {
    _started = false;
    ++_epoch;
    ++_badgeGeneration;
    await _readSubscription?.cancel();
    _readSubscription = null;
    await Future.wait(_roomWrites.values.toList());
    await _badgeWrites;
    await cancelPushWakeNotification();
    await _subscription?.cancel();
    _subscription = null;
    _started = false;
  }
}

/// PRD §16/§42：同会话聚合为同一个系统通知（notificationId = hash(roomId)）。
int notificationIdForConversation(String conversationId) {
  final bytes = sha256.convert(utf8.encode(conversationId)).bytes;
  return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
      0x7fffffff;
}

/// 推送唤醒兜底通知固定 ID（与按会话的聚合通知互不冲突）。
const pushWakeNotificationId = 42001;

/// 组合根安装的全局访问点：供设置页等无构造注入路径获取协调器
/// （与 ConversationReadState.shared 同一模式；仅主会话安装一次）。
final class NotificationSystemHandle {
  NotificationSystemHandle._(this._coordinator);

  static NotificationSystemHandle? _instance;

  final NotificationCoordinator _coordinator;

  static void install(NotificationCoordinator coordinator) {
    _instance = NotificationSystemHandle._(coordinator);
  }

  static void uninstall() {
    _instance = null;
  }

  static NotificationCoordinator? get coordinator => _instance?._coordinator;
}
