import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_diagnostics.dart';

/// 前台服务所有权人。
enum ForegroundServiceOwner {
  /// 消息同步保活（dataSync 类型，通知 41003）。
  keepAlive(1),

  /// 通话进行中（microphone|camera 类型，通知 41002）。
  ongoingCall(2);

  const ForegroundServiceOwner(this.priority);

  /// 数值越大优先级越高：仲裁时呈现最高优先级 owner 的请求。
  final int priority;
}

/// 一次前台服务呈现请求（通知内容 + 前台服务类型）。
///
/// 值对象：相同 owner 以相同请求重复 acquire 只触发重申（reassert），
/// 不改变当前呈现。
final class ForegroundServiceRequest {
  const ForegroundServiceRequest({
    required this.notificationId,
    required this.channelId,
    required this.channelName,
    required this.channelDescription,
    required this.title,
    required this.body,
    this.importance = Importance.low,
    this.priority = Priority.low,
    this.category,
    this.ongoing = true,
    this.playSound = false,
    this.enableVibration = false,
    this.sound,
    this.payload,
    this.foregroundServiceTypes = const {},
  });

  final int notificationId;
  final String channelId;
  final String channelName;
  final String channelDescription;
  final String title;
  final String body;
  final Importance importance;
  final Priority priority;
  final AndroidNotificationCategory? category;
  final bool ongoing;
  final bool playSound;
  final bool enableVibration;
  final AndroidNotificationSound? sound;
  final String? payload;
  final Set<AndroidServiceForegroundType> foregroundServiceTypes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ForegroundServiceRequest &&
          notificationId == other.notificationId &&
          channelId == other.channelId &&
          title == other.title &&
          body == other.body &&
          importance == other.importance &&
          priority == other.priority &&
          category == other.category &&
          ongoing == other.ongoing &&
          playSound == other.playSound &&
          enableVibration == other.enableVibration &&
          sound == other.sound &&
          payload == other.payload &&
          setEquals(foregroundServiceTypes, other.foregroundServiceTypes);

  @override
  int get hashCode => Object.hash(
        notificationId,
        channelId,
        title,
        body,
        importance,
        priority,
        category,
        ongoing,
        playSound,
        enableVibration,
        sound,
        payload,
        Object.hashAllUnordered(foregroundServiceTypes),
      );
}

/// 前台服务后端抽象：插件实现 + 测试替身。
abstract interface class ForegroundServiceBackend {
  Future<void> start(ForegroundServiceRequest request);

  Future<void> stop();
}

/// flutter_local_notifications 后端。
///
/// 关键事实：该插件全局只有一个 Android `ForegroundService`——
/// `startForegroundService` 复用同一 OS 服务（新通知替换旧通知），
/// `stopForegroundService` 一次性停掉它。多业务直控必然互踩，
/// 争用仲裁必须集中在 [ForegroundServiceArbiter]。
final class FlutterForegroundServiceBackend
    implements ForegroundServiceBackend {
  FlutterForegroundServiceBackend({FlutterLocalNotificationsPlugin? plugin})
      : plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin plugin;

  @override
  Future<void> start(ForegroundServiceRequest request) async {
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.startForegroundService(
      request.notificationId,
      request.title,
      request.body,
      notificationDetails: AndroidNotificationDetails(
        request.channelId,
        request.channelName,
        channelDescription: request.channelDescription,
        importance: request.importance,
        priority: request.priority,
        category: request.category,
        ongoing: request.ongoing,
        autoCancel: !request.ongoing,
        playSound: request.playSound,
        enableVibration: request.enableVibration,
        sound: request.sound,
      ),
      foregroundServiceTypes: request.foregroundServiceTypes,
      payload: request.payload,
    );
  }

  @override
  Future<void> stop() async {
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.stopForegroundService();
  }
}

/// 前台服务仲裁器（修复"通话结束停止消息保活"）：
///
/// - `acquire(owner, request)`：登记所有权并呈现当前最高优先级请求；
/// - `release(owner)`：仍有其他 owner 时**重申**剩余最高优先级请求
///   （通话结束 → 回写保活通知 41003），无剩余 owner 才真正 stop；
/// - `reassert()`：看门狗/生命周期自愈，幂等重申当前呈现；
/// - 后端失败不抛出（保活尽力而为），必留诊断。
final class ForegroundServiceArbiter {
  ForegroundServiceArbiter({
    required this.backend,
    NotificationDiagnostics? diagnostics,
  }) : diagnostics = diagnostics ?? NotificationDiagnostics.shared;

  final ForegroundServiceBackend backend;
  final NotificationDiagnostics diagnostics;

  final Map<ForegroundServiceOwner, ForegroundServiceRequest> _active = {};

  bool isActive(ForegroundServiceOwner owner) => _active.containsKey(owner);

  Future<void> acquire(
    ForegroundServiceOwner owner,
    ForegroundServiceRequest request,
  ) async {
    final previous = _active[owner];
    if (previous == request) {
      await reassert();
      return;
    }
    _active[owner] = request;
    await _applyTop('acquire:$owner');
  }

  Future<void> release(ForegroundServiceOwner owner) async {
    if (_active.remove(owner) == null) return;
    if (_active.isEmpty) {
      try {
        await backend.stop();
        diagnostics.record(
            NotificationDiagStage.foregroundService, 'stopped (no owners)');
      } catch (error) {
        diagnostics.record(NotificationDiagStage.foregroundService,
            'stop failed: ${error.runtimeType}');
      }
      return;
    }
    await _applyTop('release:$owner → reassert remaining');
  }

  Future<void> reassert() async {
    if (_active.isEmpty) return;
    await _applyTop('reassert');
  }

  Future<void> _applyTop(String reason) async {
    var topOwner = _active.keys.first;
    for (final owner in _active.keys) {
      if (owner.priority > topOwner.priority) topOwner = owner;
    }
    final request = _active[topOwner]!;
    try {
      await backend.start(request);
      diagnostics.record(NotificationDiagStage.foregroundService,
          '$reason → applied #${request.notificationId}');
    } catch (error) {
      diagnostics.record(NotificationDiagStage.foregroundService,
          '$reason failed: ${error.runtimeType}');
    }
  }
}
