import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  let iosCalls = IOSCallsBridge()
  private let secureSession = IOSSecureSessionBridge()
  private var sharedEngine: FlutterEngine?
  private var apnsChannel: FlutterMethodChannel?
  private var apnsToken: String?
  private var apnsListening = false
  private var pendingTap: [String: String]?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    iosCalls.registerPushKit()
    _ = startSharedEngine()
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func startSharedEngine() -> FlutterEngine {
    if let engine = sharedEngine { return engine }
    let engine = FlutterEngine(name: "chatflow.shared", project: nil, allowHeadlessExecution: true)
    sharedEngine = engine
    engine.run()
    GeneratedPluginRegistrant.register(with: engine)
    configureChannels(messenger: engine.binaryMessenger)
    return engine
  }

  private func configureChannels(messenger: FlutterBinaryMessenger) {
    iosCalls.attach(messenger: messenger)
    secureSession.attach(messenger: messenger)

    // 桌面角标通道（PRD §35）：与 Android 侧 MainActivity 同名约定
    // chatflow/badge。iOS 直接写 UIApplication 角标数字。
    FlutterMethodChannel(
      name: "chatflow/badge",
      binaryMessenger: messenger
    ).setMethodCallHandler { call, result in
      switch call.method {
      case "updateCount":
        let arguments = call.arguments as? [String: Any]
        let count = arguments?["count"] as? Int ?? 0
        UIApplication.shared.applicationIconBadgeNumber = count
        result(true)
      case "clear":
        UIApplication.shared.applicationIconBadgeNumber = 0
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let channel = FlutterMethodChannel(
      name: "chatflow/apns",
      binaryMessenger: messenger
    )
    apnsChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "start":
        self.apnsListening = true
        UIApplication.shared.registerForRemoteNotifications()
        result(nil)
        self.deliverPendingTap()
      case "getNotificationSettings":
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          let status: String
          switch settings.authorizationStatus {
          case .authorized: status = "authorized"
          case .denied: status = "denied"
          case .provisional: status = "provisional"
          case .ephemeral: status = "ephemeral"
          case .notDetermined: status = "notDetermined"
          @unknown default: status = "unknown"
          }
          DispatchQueue.main.async {
            result(["authorizationStatus": status, "alertEnabled": settings.alertSetting == .enabled,
                    "soundEnabled": settings.soundSetting == .enabled, "badgeEnabled": settings.badgeSetting == .enabled])
          }
        }
      case "openNotificationSettings":
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { result(false); return }
        UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
      case "getToken":
        UIApplication.shared.registerForRemoteNotifications()
        result(self.apnsToken)
      case "stop":
        self.apnsListening = false
        self.pendingTap = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    apnsToken = token
    iosCalls.updateAPNSToken(token)
    if apnsListening {
      apnsChannel?.invokeMethod("tokenChanged", arguments: apnsToken)
    }
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.notification.request.trigger is UNPushNotificationTrigger,
       response.actionIdentifier == UNNotificationDefaultActionIdentifier {
      let info = response.notification.request.content.userInfo
      var identifiers = [String: String]()
      for key in ["event_id", "room_id"] {
        if let value = info[key] as? String, !value.isEmpty { identifiers[key] = value }
      }
      if identifiers["room_id"] != nil {
        pendingTap = identifiers
        deliverPendingTap()
      }
    }
    if response.notification.request.trigger is UNPushNotificationTrigger {
      completionHandler()
    } else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
    }
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    if iosCalls.handleCancellation(userInfo) { completionHandler(.newData); return }
    super.application(application, didReceiveRemoteNotification: userInfo, fetchCompletionHandler: completionHandler)
  }
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if notification.request.trigger is UNPushNotificationTrigger {
      // Matrix already presents foreground message notices using the user's
      // in-app preferences. Suppress the generic APNs copy to avoid two alerts.
      _ = iosCalls.handleCancellation(notification.request.content.userInfo)
      completionHandler([])
    } else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }
  }

  private func deliverPendingTap() {
    guard apnsListening, let tap = pendingTap, let channel = apnsChannel else { return }
    channel.invokeMethod("notificationTap", arguments: tap) { [weak self] result in
      guard let self = self else { return }
      if result as? Bool == true, self.pendingTap == tap { self.pendingTap = nil }
    }
  }
}
