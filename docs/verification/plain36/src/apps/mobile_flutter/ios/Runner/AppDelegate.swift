import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 桌面角标通道（PRD §35）：与 Android 侧 MainActivity 同名约定
    // chatflow/badge。iOS 直接写 UIApplication 角标数字。
    MethodChannel(
      binaryMessenger: engineBridge.engineForDartExecutor.binaryMessenger,
      name: "chatflow/badge"
    ).setMethodCallHandler { call, result in
      switch call.method {
      case "updateCount":
        let count = call.arguments["count"] as? Int ?? 0
        UIApplication.shared.applicationIconBadgeNumber = count
        result(true)
      case "clear":
        UIApplication.shared.applicationIconBadgeNumber = 0
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
