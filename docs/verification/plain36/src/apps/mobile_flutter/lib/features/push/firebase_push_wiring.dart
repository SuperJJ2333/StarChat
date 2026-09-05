import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/notification/notification_diagnostics.dart';
import '../../core/notification/system_notification_presenter.dart';
import 'push_tap_router.dart';

/// 冷启动通知点击路由（不依赖 FCM 凭据，常规消息通知同样受益）：
/// 通知系统报告 App 由通知点击启动且 payload 形如 roomId 时，
/// 经 PushTapRouter 进入对应会话。
Future<void> routeNotificationLaunch({
  required PushTapRouter tapRouter,
}) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    final details = await plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return;
    final payload = details?.notificationResponse?.payload;
    if (payload == null || payload.isEmpty) return;
    tapRouter.handleTap(PushNotificationPayload(roomId: payload));
  } catch (error) {
    debugPrint(
        '[chatflow/notif-diag] launch route failed: ${error.runtimeType}');
  }
}

/// FCM 接线（凭据就绪时由组合根调用；未就绪时安全返回，零行为变化）：
/// - 冷启动点击（getInitialMessage）与后台点击（onMessageOpenedApp）→
///   PushTapRouter（eventId 先入持久去重，会话就绪后进入对应房间）；
/// - 前台消息（onMessage）：Matrix 同步通道已在通知，仅记录诊断；
/// - 后台/被杀（onBackgroundMessage）：展示通用通知（不含正文）。
Future<void> configureFirebasePushHandlers({
  required PushTapRouter tapRouter,
  NotificationDiagnostics? diagnostics,
}) async {
  final diag = diagnostics ?? NotificationDiagnostics.shared;
  try {
    await Firebase.initializeApp();
  } catch (error) {
    diag.record(NotificationDiagStage.push,
        'firebase unavailable: ${error.runtimeType}');
    return;
  }
  final messaging = FirebaseMessaging.instance;

  FirebaseMessaging.onBackgroundMessage(onBackgroundPushMessage);

  final initial = await messaging.getInitialMessage();
  if (initial != null) {
    tapRouter.handleTap(PushNotificationPayload.parse(initial.data));
  }

  FirebaseMessaging.onMessageOpenedApp.listen((message) {
    tapRouter.handleTap(PushNotificationPayload.parse(message.data));
  });

  FirebaseMessaging.onMessage.listen((message) {
    // 前台：Matrix 同步链路已在本地通知（含解密预览）；推送仅作旁证。
    diag.record(NotificationDiagStage.push, 'foreground message received');
  });
}

const int _messagePushNotificationId = 42001;
const int _callPushNotificationId = 42002;
const String _callsChannelId = 'calls';
const String _callsChannelName = '通话提醒';

/// Android 后台/进程被杀时的兜底展示：只含通用文案，绝不含消息正文
/// （E2EE 边界，apps/mobile_flutter/AGENTS.md）。点击冷启动 App →
/// 本地 Matrix 同步 → 解密 → 进入会话。
@pragma('vm:entry-point')
Future<void> onBackgroundPushMessage(RemoteMessage message) async {
  final payload = PushNotificationPayload.parse(message.data);
  final roomId = payload.roomId;
  if (roomId == null || roomId.isEmpty) return;
  if (payload.isCall) {
    // 来电信令：高优先级推送唤醒进程；若主 isolate 存活，Matrix 同步
    // 会触发全屏来电通知（CallNotifications）。此处兜底展示 heads-up
    // 通知；真正合规的 VoIP 体验（Android CallStyle / iOS PushKit+
    // CallKit）为独立后续工作（docs/PUSH_SETUP.md）。
    await _showGenericNotification(
      id: _callPushNotificationId,
      channelId: _callsChannelId,
      channelName: _callsChannelName,
      title: '畅聊来电',
      body: '你有一个来电，点击查看',
      fullScreenIntent: true,
      importanceMax: true,
      roomId: roomId,
    );
    return;
  }
  await _showGenericNotification(
    id: _messagePushNotificationId,
    channelId: messagesChannelIdV2,
    channelName: '消息通知',
    title: '畅聊',
    body: '你收到一条新消息',
    fullScreenIntent: false,
    importanceMax: false,
    roomId: roomId,
  );
}

Future<void> _showGenericNotification({
  required int id,
  required String channelId,
  required String channelName,
  required String title,
  required String body,
  required bool fullScreenIntent,
  required bool importanceMax,
  required String roomId,
}) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    await plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: importanceMax ? Importance.max : Importance.high,
          priority: importanceMax ? Priority.max : Priority.high,
          category: importanceMax
              ? AndroidNotificationCategory.call
              : AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          fullScreenIntent: fullScreenIntent,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      // 点击 payload 只携带 roomId：进入会话后由本地同步+解密呈现内容。
      payload: roomId,
    );
  } catch (error) {
    // 后台 isolate 中插件可能尚未就绪；失败不抛出（推送尽力而为）。
    debugPrint(
        '[chatflow/notif-diag] background push notify failed: ${error.runtimeType}');
  }
}
