import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 通话系统通知：
/// - **来电**：全屏意图（full-screen intent）通知，App 在后台/锁屏/其他
///   应用界面之上弹出来电，点击拉起通话接听页；进程存活期间 Matrix
///   长连接持续同步，来电可达。
/// - **通话中**：前台服务通知（microphone|camera 类型），按 Home 键或
///   切换应用后通话继续、麦克风/摄像头不因退后台被系统回收。
final class CallNotifications {
  CallNotifications({FlutterLocalNotificationsPlugin? plugin})
      : plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin plugin;
  bool _initialized = false;

  static const incomingCallId = 41001;
  static const ongoingCallId = 41002;
  static const _callsChannelId = 'calls';
  static const _callsChannelName = '通话提醒';
  static const _ongoingChannelId = 'call-ongoing';
  static const _ongoingChannelName = '通话中';

  Future<void> _ensureInit() async {
    if (_initialized) return;
    await plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ));
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _callsChannelId,
      _callsChannelName,
      description: '加密语音/视频来电提醒，覆盖在其他应用与锁屏之上',
      importance: Importance.max,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _ongoingChannelId,
      _ongoingChannelName,
      description: '通话进行中的常驻通知，保证切后台后通话继续',
      importance: Importance.low,
    ));
    _initialized = true;
  }

  AndroidNotificationDetails _details({
    required String channelId,
    required String title,
    required String body,
    required bool ongoing,
    bool fullScreenIntent = false,
  }) =>
      AndroidNotificationDetails(
        channelId,
        title,
        channelDescription: body,
        importance: fullScreenIntent ? Importance.max : Importance.low,
        priority: fullScreenIntent ? Priority.max : Priority.low,
        category: AndroidNotificationCategory.call,
        ongoing: ongoing,
        autoCancel: !ongoing,
        fullScreenIntent: fullScreenIntent,
        // 响铃/震动由应用内 CallAlerts 驱动，通知不重复发声。
        playSound: false,
        enableVibration: false,
        ticker: title,
      );

  /// 来电覆盖提醒：后台/锁屏/其他应用之上弹出，点击回到接听页。
  Future<void> showIncoming({
    required String callerName,
    required bool video,
  }) async {
    await _ensureInit();
    await plugin.show(
      incomingCallId,
      video ? '畅聊视频来电' : '畅聊语音来电',
      callerName,
      NotificationDetails(
        android: _details(
          channelId: _callsChannelId,
          title: video ? '畅聊视频来电' : '畅聊语音来电',
          body: callerName,
          ongoing: true,
          fullScreenIntent: true,
        ),
      ),
      payload: 'incoming-call',
    );
  }

  Future<void> hideIncoming() async {
    await _ensureInit();
    await plugin.cancel(incomingCallId);
  }

  /// 通话中前台服务：切后台/Home 键后通话继续，麦克风摄像头不被回收。
  Future<void> showOngoing({required String title}) async {
    await _ensureInit();
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.startForegroundService(
      ongoingCallId,
      '畅聊通话中',
      title,
      notificationDetails: _details(
        channelId: _ongoingChannelId,
        title: '畅聊通话中',
        body: title,
        ongoing: true,
      ),
      foregroundServiceTypes: {
        AndroidServiceForegroundType.foregroundServiceTypeMicrophone,
        AndroidServiceForegroundType.foregroundServiceTypeCamera,
      },
    );
  }

  Future<void> hideOngoing() async {
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.stopForegroundService();
  }
}
