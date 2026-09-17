import Flutter
import UIKit
import UserNotifications
import AVFoundation
import CallKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  let iosCalls = IOSCallsBridge()
  private let secureSession = IOSSecureSessionBridge()
  private var sharedEngine: FlutterEngine?
  private var apnsChannel: FlutterMethodChannel?
  private var apnsToken: String?
  private var apnsListening = false
  private var pendingTap: [String: String]?
  private let voiceCallObserver = CXCallObserver()
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
    configureScreenCaptureChannels(messenger: messenger)
    configureAudioRouteChannel(messenger: messenger)

    FlutterMethodChannel(name: "chatflow/voice_audio_session", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self = self else { result(nil); return }
        guard call.method == "checkPlaybackAllowed" || call.method == "preparePlayback" else {
          result(FlutterMethodNotImplemented); return
        }
        // This handler runs on the main queue, shared with CallKit ownership.
        // Never change the global audio session while a call owns it.
        guard !self.iosCalls.hasActiveCall,
              !self.voiceCallObserver.calls.contains(where: { !$0.hasEnded }) else {
          result(FlutterError(code: "VOICE_CALL_ACTIVE", message: "Voice playback unavailable during a call", details: nil))
          return
        }
        if call.method == "checkPlaybackAllowed" { result(nil); return }
        guard let args = call.arguments as? [String: Any], let earpiece = args["earpiece"] as? Bool else {
          result(FlutterError(code: "VOICE_INVALID_ROUTE", message: "Invalid audio route", details: nil)); return
        }
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(.playAndRecord, mode: .default,
                                  options: earpiece ? [] : [.defaultToSpeaker])
          try session.overrideOutputAudioPort(earpiece ? .none : .speaker)
          try session.setActive(true)
          result(nil)
        } catch {
          // Do not expose audio source URLs or decrypted media in errors.
          result(FlutterError(code: "VOICE_SESSION_FAILED", message: "Could not prepare voice playback", details: nil))
        }
      }

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

  // MARK: - 闪照屏幕捕获（Task E）
  //
  // iOS 没有官方等价于 Android FLAG_SECURE 的通用截图阻止 API：
  // - 不使用 secure UITextField hack / private API / 未公开 UIView trick；
  // - 这里只做两件事：① 上报「正在录屏或镜像」状态（禁止 reveal）；
  //   ② 上报系统截图**已完成**的事件（事后销毁闪照，不声称阻止截图）。
  // 不涉及相册权限、不扫描/删除用户截图、不上传任何内容。

  private var screenCaptureChannel: FlutterEventChannel?
  private var screenSecurityChannel: FlutterMethodChannel?
  private var screenCaptureSink: FlutterEventSink?
  private var captureObserversRegistered = false

  /// 只读的音频路由观察通道（外设：蓝牙 / 有线耳机 / USB / AirPlay）。
  ///
  /// 边界：这里**只上报**当前是否存在外部音频输出设备，绝不调用
  /// `overrideOutputAudioPort(.speaker)` 去抢 AirPods / 蓝牙路由——
  /// 真实路由由 CallKit 与 AVAudioSession 负责，speaker/earpiece 策略的
  /// 唯一 owner 是 Dart 侧 CallAudioRouteCoordinator。
  /// 隐私：只返回端口**类型名**，不返回设备名称。
  private var audioRouteChannel: FlutterMethodChannel?

  private func configureAudioRouteChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "chatflow/audio_route", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "currentAudioRoute":
        result(["devices": self.currentAudioOutputPortTypes()])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    audioRouteChannel = channel
  }

  /// 当前音频输出端口类型名（只读快照）。
  private func currentAudioOutputPortTypes() -> [String] {
    let session = AVAudioSession.sharedInstance()
    var types: [String] = []
    for output in session.currentRoute.outputs {
      let name: String
      switch output.portType {
      case .bluetoothA2DP: name = "bluetooth-a2dp"
      case .bluetoothLE: name = "bluetooth-ble"
      case .bluetoothHFP: name = "bluetooth-sco"
      case .headsetMic, .headphones: name = "wired-headphones"
      case .usbAudio: name = "usb"
      case .carAudio: name = "car"
      case .airPlay: name = "airplay"
      case .builtInSpeaker: name = "speaker"
      case .builtInReceiver: name = "earpiece"
      default: name = "other"
      }
      if !types.contains(name) { types.append(name) }
    }
    return types
  }

  private func configureScreenCaptureChannels(messenger: FlutterBinaryMessenger) {
    // iOS 无 FLAG_SECURE 等价能力：acquire/release 为显式 no-op（保持 Dart
    // 侧统一契约），绝不伪装成截图保护。
    let security = FlutterMethodChannel(name: "chatflow/screen_security", binaryMessenger: messenger)
    security.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "acquireSecure", "releaseSecure", "releaseAllSecure", "reassertSecure":
        result(0) // 明确：iOS 不支持通用截图阻止
      case "getCurrentCaptureState":
        // 同步快照：查看器打开时不必等第一次 EventChannel 事件
        // （设备在查看器打开前就已在录屏时，那段空窗是 fail-open 的）。
        guard let self = self else {
          result(FlutterError(code: "SCREEN_SECURITY_UNAVAILABLE",
                              message: "screen security channel unavailable",
                              details: nil))
          return
        }
        result(["supported": true, "active": self.currentCaptureActive()])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    screenSecurityChannel = security

    let capture = FlutterEventChannel(name: "chatflow/screen_capture", binaryMessenger: messenger)
    capture.setStreamHandler(self)
    screenCaptureChannel = capture
    registerCaptureObservers()
    publishCaptureState()
  }

  private func registerCaptureObservers() {
    guard !captureObserversRegistered else { return }
    captureObserversRegistered = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenCapturedDidChange),
      name: UIScreen.capturedDidChangeNotification,
      object: nil
    )
    // 该通知在系统截图**完成之后**触发：只能事后销毁，不能阻止。
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(userDidTakeScreenshot),
      name: UIApplication.userDidTakeScreenshotNotification,
      object: nil
    )
  }

  @objc private func screenCapturedDidChange() {
    publishCaptureState()
  }

  @objc private func userDidTakeScreenshot() {
    screenCaptureSink?(["type": "screenshot"])
  }

  /// 现代系统优先 scene capture state；否则回退 UIScreen.isCaptured。
  private func currentCaptureActive() -> Bool {
    var active = UIScreen.main.isCaptured
    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
      if #available(iOS 17.0, *) {
        active = scene.traitCollection.sceneCaptureState != .inactive
      }
    }
    return active
  }

  private func publishCaptureState() {
    screenCaptureSink?(["type": "captureState", "active": currentCaptureActive()])
  }
}

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    screenCaptureSink = events
    publishCaptureState()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    screenCaptureSink = nil
    return nil
  }
}
