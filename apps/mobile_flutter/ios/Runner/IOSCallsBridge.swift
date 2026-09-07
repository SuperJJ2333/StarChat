import AVFoundation
import CallKit
import Flutter
import PushKit
import WebRTC
import UIKit

final class IOSCallsBridge: NSObject, PKPushRegistryDelegate, CXProviderDelegate {
  private let state = IOSCallState()
  private let controller = CXCallController()
  private let provider: CXProvider
  private var registry: PKPushRegistry?
  private var channel: FlutterMethodChannel?
  private var ready = false
  private var active = UserDefaults.standard.bool(forKey: "chatflow.iosCalls.active")
  private var voipToken: String?
  private var apnsToken: String?
  private var timers: [UUID: DispatchWorkItem] = [:]
  private var answers: [UUID: CXAnswerCallAction] = [:]
  private var outgoing = Set<UUID>()
  private let pip = IOSCallPictureInPicture()
  private var audioActivated = false
  private var generation = 0

  override init() {
    let config = CXProviderConfiguration(localizedName: "ChatFlow")
    config.supportsVideo = true
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    config.includesCallsInRecents = false
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: .main)
    pip.onRestore = { [weak self] in self?.channel?.invokeMethod("returnToCall", arguments: nil) }
  }

  func registerPushKit() {
    guard registry == nil else { return }
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    self.registry = registry
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "chatflow/ios_calls", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      self.handle(call, result: result)
    }
  }

  func updateAPNSToken(_ token: String) { apnsToken = token; notifyTokens() }
  private var tokens: [String: Any] {
    ["voipToken": voipToken as Any? ?? NSNull(), "apnsToken": apnsToken as Any? ?? NSNull()]
  }
  private func notifyTokens() { if active { channel?.invokeMethod("tokensChanged", arguments: tokens) } }
  private var now: TimeInterval { Date().timeIntervalSince1970 }

  private func handle(_ method: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = method.arguments as? [String: Any] ?? [:]
    switch method.method {
    case "start":
      active = true
      UserDefaults.standard.set(true, forKey: "chatflow.iosCalls.active")
      registerPushKit()
      UIApplication.shared.registerForRemoteNotifications()
      result(tokens)
    case "getTokens": result(tokens)
    case "stop":
      generation += 1
      active = false; ready = false
      UserDefaults.standard.set(false, forKey: "chatflow.iosCalls.active")
      for call in Array(state.calls.values) { end(call, reason: .remoteEnded, notify: false) }
      state.clear()
      pip.clear()
      result(true)
    case "ready", "getPending":
      if method.method == "ready" { ready = active }
      result(["actions": active ? state.drain(now: now) : []])
    case "showIncoming":
      guard active, let call = descriptor(args) else { result(false); return }
      reportIncoming(call, completion: { result($0) })
    case "reportState": result(reportState(args))
    case "endCall":
      let id = args["callId"] as? String
      for call in Array(state.calls.values) where id == nil || call.callId == id {
        end(call, reason: .remoteEnded, notify: false)
      }
      result(true)
    case "setPipVideo":
      guard active, !state.calls.isEmpty else { pip.clear(); result(false); return }
      result(pip.setVideo(streamId: args["streamId"] as? String, ownerTag: args["ownerTag"] as? String))
    case "startPip": result(pip.start())
    case "stopPip": result(pip.stop())
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func descriptor(_ args: [String: Any]) -> IOSCallDescriptor? {
    let milliseconds = (args["expiresAt"] as? NSNumber)?.doubleValue ?? ((now + 30) * 1000)
    return IOSCallDescriptor(push: ["call_id": args["callId"] ?? NSNull(), "room_id": args["roomId"] ?? NSNull(), "video": args["video"] ?? false, "expires_at": milliseconds / 1000], now: now)
  }

  private func update(for call: IOSCallDescriptor) -> CXCallUpdate {
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: "ChatFlow")
    update.localizedCallerName = "ChatFlow 来电"
    update.hasVideo = call.video
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    return update
  }

  private func reportIncoming(_ call: IOSCallDescriptor, completion: @escaping (Bool) -> Void) {
    if state.match(callId: call.callId, roomId: call.roomId) != nil { completion(true); return }
    guard state.insert(call, now: now) else { completion(false); return }
    configureManualAudio()
    let reportGeneration = generation
    provider.reportNewIncomingCall(with: call.uuid, update: update(for: call)) { [weak self] error in
      DispatchQueue.main.async {
        guard let self = self else { completion(false); return }
        guard reportGeneration == self.generation else { completion(false); return }
        guard error == nil, call.expiresAt > self.now, self.state.match(callId: call.callId, roomId: call.roomId) != nil else {
          if error == nil { self.provider.reportCall(with: call.uuid, endedAt: Date(), reason: .remoteEnded) }
          self.state.remove(call, now: self.now)
          self.releaseAudio()
          completion(false)
          return
        }
        self.emit("incoming", call: call)
        self.scheduleTimeout(call)
        completion(true)
      }
    }
  }

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    voipToken = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    notifyTokens()
  }
  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    voipToken = nil; notifyTokens()
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    guard type == .voIP else { completion(); return }
    let data = payload.dictionaryPayload.reduce(into: [String: Any]()) { result, pair in
      if let key = pair.key as? String { result[key] = pair.value }
    }
    if active, let call = IOSCallDescriptor(push: data, now: now), state.calls.isEmpty {
      reportIncoming(call) { [weak self] accepted in
        // A rejected/tombstoned call must still be reported to CallKit for this VoIP delivery.
        if accepted { completion() } else if let self = self { self.reportRejectedPush(data, completion: completion) } else { completion() }
      }
    } else {
      reportRejectedPush(data, completion: completion)
    }
  }

  private func reportRejectedPush(_ data: [String: Any], completion: @escaping () -> Void) {
    let callId = data["call_id"] as? String
    let uuid = callId.map { IOSCallDescriptor.uuid(for: $0) } ?? UUID()
    let existing = state.calls[uuid]
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: "ChatFlow")
    update.localizedCallerName = "ChatFlow 来电"
    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      // Duplicate UUIDs are rejected by CallKit; never end the original active call.
      if existing == nil, error == nil { self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed) }
      completion()
    }
  }

  // Ordinary APNs cancellation is not a new VoIP call. Bind both identifiers.
  func handleCancellation(_ info: [AnyHashable: Any]) -> Bool {
    guard info["call_action"] as? String == "end",
          let callId = info["call_id"] as? String, !callId.isEmpty,
          let roomId = info["room_id"] as? String, !roomId.isEmpty else { return false }
    guard active else { return true }
    if let call = state.match(callId: callId, roomId: roomId) { end(call, reason: .remoteEnded, notify: true) }
    else if state.calls[IOSCallDescriptor.uuid(for: callId)] == nil { state.rememberEnded(callId: callId, now: now) }
    return true
  }

  private func reportState(_ args: [String: Any]) -> Bool {
    guard active, let callId = args["callId"] as? String, let roomId = args["roomId"] as? String,
          let phase = args["phase"] as? String else { return false }
    var bound = state.match(callId: callId, roomId: roomId)
    if bound == nil, phase == "connecting", args["incoming"] as? Bool == false, let call = descriptor(args), state.insert(call, now: now) {
      bound = call
      outgoing.insert(call.uuid)
      configureManualAudio()
      let start = CXStartCallAction(call: call.uuid, handle: CXHandle(type: .generic, value: "ChatFlow"))
      start.isVideo = call.video
      controller.request(CXTransaction(action: start)) { [weak self] error in
        if error != nil { DispatchQueue.main.async { self?.end(call, reason: .failed, notify: true) } }
      }
      scheduleTimeout(call)
    }
    guard let call = bound else { return false }
    switch phase {
    case "connected", "active":
      timers.removeValue(forKey: call.uuid)?.cancel()
      answers.removeValue(forKey: call.uuid)?.fulfill()
      if outgoing.contains(call.uuid) { provider.reportOutgoingCall(with: call.uuid, connectedAt: Date()) }
      provider.reportCall(with: call.uuid, updated: update(for: call))
    case "ended", "idle", "failed", "permissionDenied": end(call, reason: phase == "failed" || phase == "permissionDenied" ? .failed : .remoteEnded, notify: false)
    default: break
    }
    return true
  }

  private func scheduleTimeout(_ call: IOSCallDescriptor) {
    timers.removeValue(forKey: call.uuid)?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.end(call, reason: .unanswered, notify: true) }
    timers[call.uuid] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, call.expiresAt - now), execute: work)
  }
  private func emit(_ action: String, call: IOSCallDescriptor, muted: Bool? = nil) {
    guard active else { return }
    state.enqueue(action: action, call: call, now: now, muted: muted)
    if ready, let channel = channel {
      for event in state.drain(now: now) { channel.invokeMethod("event", arguments: event) }
    }
  }
  private func end(_ call: IOSCallDescriptor, reason: CXCallEndedReason, notify: Bool) {
    guard state.match(callId: call.callId, roomId: call.roomId) != nil else { return }
    timers.removeValue(forKey: call.uuid)?.cancel()
    answers.removeValue(forKey: call.uuid)?.fail()
    outgoing.remove(call.uuid)
    state.remove(call, now: now)
    provider.reportCall(with: call.uuid, endedAt: Date(), reason: reason)
    if notify { emit("end", call: call) }
    if state.calls.isEmpty { pip.clear(); releaseAudio() }
  }

  func providerDidReset(_ provider: CXProvider) {
    for call in Array(state.calls.values) { end(call, reason: .failed, notify: true) }
    releaseAudio()
  }
  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard active, let call = state.calls[action.callUUID], call.expiresAt > now else { action.fail(); return }
    guard answers[action.callUUID] == nil else { action.fail(); return }
    guard configureCallAudio(video: call.video) else { action.fail(); end(call, reason: .failed, notify: true); return }
    answers[action.callUUID] = action
    configureManualAudio()
    emit("answer", call: call)
    // Fulfilled only after the matching encrypted Matrix session connects.
  }
  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    guard let call = state.calls[action.callUUID] else { action.fulfill(); return }
    end(call, reason: .remoteEnded, notify: true)
    action.fulfill()
  }
  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    guard let call = state.calls[action.callUUID] else { action.fail(); return }
    emit("mute", call: call, muted: action.isMuted)
    action.fulfill()
  }
  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    guard let call = state.calls[action.callUUID], outgoing.contains(call.uuid) else { action.fail(); return }
    guard configureCallAudio(video: call.video) else { action.fail(); end(call, reason: .failed, notify: true); return }
    provider.reportOutgoingCall(with: call.uuid, startedConnectingAt: Date())
    action.fulfill()
  }
  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    if let callAction = action as? CXCallAction, let call = state.calls[callAction.callUUID] { end(call, reason: .failed, notify: true) }
  }
  private func configureCallAudio(video: Bool) -> Bool {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: video ? .videoChat : .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
      return true
    } catch { return false }
  }
  private func configureManualAudio() {
    let audio = RTCAudioSession.sharedInstance()
    audio.useManualAudio = true
    if !audioActivated { audio.isAudioEnabled = false }
  }
  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    audioActivated = true
    let audio = RTCAudioSession.sharedInstance()
    audio.audioSessionDidActivate(audioSession)
    audio.isAudioEnabled = !state.calls.isEmpty
  }
  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    audioActivated = false
    let audio = RTCAudioSession.sharedInstance()
    audio.isAudioEnabled = false
    audio.audioSessionDidDeactivate(audioSession)
  }
  private func releaseAudio() {
    RTCAudioSession.sharedInstance().isAudioEnabled = false
    // CallKit owns AVAudioSession activation; do not unbalance its activation count.
  }
}
