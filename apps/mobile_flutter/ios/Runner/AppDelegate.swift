import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var apnsChannel: FlutterMethodChannel?
  private var apnsToken: String?
  private var apnsListening = false
  private var pendingTap: [String: String]?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 桌面角标通道（PRD §35）：与 Android 侧 MainActivity 同名约定
    // chatflow/badge。iOS 直接写 UIApplication 角标数字。
    FlutterMethodChannel(
      name: "chatflow/badge",
      binaryMessenger: engineBridge.engineForDartExecutor.binaryMessenger
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
      binaryMessenger: engineBridge.engineForDartExecutor.binaryMessenger
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
    apnsToken = deviceToken.map { String(format: "%02x", $0) }.joined()
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
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }

  private func deliverPendingTap() {
    guard apnsListening, let tap = pendingTap, let channel = apnsChannel else { return }
    channel.invokeMethod("notificationTap", arguments: tap) { [weak self] result in
      guard let self = self else { return }
      if result as? Bool == true, self.pendingTap == tap { self.pendingTap = nil }
    }
  }
}
