import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
    if (android == null) {
      throw StateError('Android foreground service unavailable');
    }
    await android.startForegroundService(
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

/// Native sends only fixed lifecycle reasons, after releasing locks/stopSelf.
/// A single handler fans out to the arbiter and keepalive state machine.
abstract final class ForegroundServiceLifecycle {
  static const _channel = MethodChannel('chatflow/foreground_service');
  static final _events = StreamController<String>.broadcast(sync: true);
  static bool _attached = false;

  static Stream<String> get events {
    if (!_attached) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'stopped') _events.add('stopped');
        if (call.method == 'locksReleased') _events.add('locksReleased');
      });
      _attached = true;
    }
    return _events.stream;
  }
}

enum ForegroundServiceApplyResult { applied, denied, stopped }

/// desired ownership is retained separately from OS-confirmed running state.
/// Mutations are immediate; native operations are serialized so a late start
/// cannot overtake stop or resurrect an owner released while it was pending.
final class ForegroundServiceArbiter {
  ForegroundServiceArbiter({
    required this.backend,
    NotificationDiagnostics? diagnostics,
  }) : diagnostics = diagnostics ?? NotificationDiagnostics.shared;

  final ForegroundServiceBackend backend;
  final NotificationDiagnostics diagnostics;
  final Map<ForegroundServiceOwner, ForegroundServiceRequest> _desired = {};
  Future<void> _tail = Future.value();
  StreamSubscription<String>? _lifecycle;
  int _revision = 0;
  bool _running = false;
  bool _suspended = false;

  bool isDesired(ForegroundServiceOwner owner) => _desired.containsKey(owner);
  bool isActive(ForegroundServiceOwner owner) => _running && isDesired(owner);

  Future<ForegroundServiceApplyResult> acquire(
    ForegroundServiceOwner owner,
    ForegroundServiceRequest request,
  ) {
    _lifecycle ??= ForegroundServiceLifecycle.events.listen((event) {
      if (event == 'locksReleased') return;
      _revision++;
      _running = false;
      _suspended = true;
    });
    _desired[owner] = request;
    _suspended = false; // Explicit lifecycle/call request, never a timer.
    return _enqueue(++_revision);
  }

  Future<void> release(ForegroundServiceOwner owner) async {
    if (_desired.remove(owner) == null) return;
    await _enqueue(++_revision);
    if (_desired.isEmpty) {
      await _lifecycle?.cancel();
      _lifecycle = null;
    }
  }

  Future<void> reassert() async {
    if (_desired.isEmpty || _suspended) return;
    await _enqueue(++_revision);
  }

  Future<ForegroundServiceApplyResult> _enqueue(int revision) {
    final result = _tail.then((_) => _apply(revision));
    _tail = result.then<void>((_) {});
    return result;
  }

  Future<ForegroundServiceApplyResult> _apply(int revision) async {
    if (revision != _revision || _suspended) {
      return ForegroundServiceApplyResult.stopped;
    }
    if (_desired.isEmpty) {
      _running = false;
      try {
        await backend.stop();
      } catch (error) {
        diagnostics.record(NotificationDiagStage.foregroundService,
            'stop failed: ${error.runtimeType}');
      }
      return ForegroundServiceApplyResult.stopped;
    }
    var top = _desired.keys.first;
    for (final owner in _desired.keys) {
      if (owner.priority > top.priority) top = owner;
    }
    try {
      await backend.start(_desired[top]!);
      if (revision != _revision) return ForegroundServiceApplyResult.stopped;
      _running = true;
      return ForegroundServiceApplyResult.applied;
    } catch (error) {
      _running = false;
      diagnostics.record(NotificationDiagStage.foregroundService,
          'start failed: ${error.runtimeType}');
      return ForegroundServiceApplyResult.denied;
    }
  }
}
