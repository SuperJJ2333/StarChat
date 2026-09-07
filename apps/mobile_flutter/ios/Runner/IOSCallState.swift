import Foundation
import CoreFoundation
import CryptoKit

struct IOSCallDescriptor {
  let callId: String
  let roomId: String
  let video: Bool
  let expiresAt: TimeInterval
  var uuid: UUID { Self.uuid(for: callId, roomId: roomId) }

  init?(push: [String: Any], now: TimeInterval) {
    guard let callId = push["call_id"] as? String, !callId.isEmpty, callId.utf8.count <= 255,
          let roomId = push["room_id"] as? String, !roomId.isEmpty, roomId.utf8.count <= 255,
          let expiry = push["expires_at"] as? NSNumber,
          CFGetTypeID(expiry) != CFBooleanGetTypeID(),
          expiry.doubleValue.isFinite, expiry.doubleValue > now,
          expiry.doubleValue <= now + 35 else { return nil }
    self.callId = callId
    self.roomId = roomId
    self.video = push["video"] as? Bool ?? false
    self.expiresAt = min(expiry.doubleValue, now + 30)
  }

  static func uuid(for callId: String, roomId: String) -> UUID {
    // Length-prefix the room so even opaque identifiers containing separators
    // cannot produce an ambiguous composite identity.
    let identity = "chatflow.call:\(roomId.utf8.count):\(roomId)\(callId)"
    var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }
}

// All access is serialized on the main queue by IOSCallsBridge.
final class IOSCallState {
  private(set) var calls: [UUID: IOSCallDescriptor] = [:]
  private var tombstones: [UUID: TimeInterval] = [:]
  private var pending: [(expiry: TimeInterval, value: [String: Any])] = []

  func insert(_ call: IOSCallDescriptor, now: TimeInterval) -> Bool {
    tombstones = tombstones.filter { $0.value > now }
    guard calls.isEmpty, tombstones[call.uuid] == nil, call.expiresAt > now else { return false }
    calls[call.uuid] = call
    return true
  }
  func match(callId: String, roomId: String) -> IOSCallDescriptor? {
    guard let call = calls[IOSCallDescriptor.uuid(for: callId, roomId: roomId)], call.callId == callId, call.roomId == roomId else { return nil }
    return call
  }
  func resolveEndCommand(_ arguments: [String: Any]) -> IOSCallDescriptor? {
    guard let callId = arguments["callId"] as? String, !callId.isEmpty,
          let roomId = arguments["roomId"] as? String, !roomId.isEmpty else { return nil }
    return match(callId: callId, roomId: roomId)
  }
  func remove(_ call: IOSCallDescriptor, now: TimeInterval) {
    calls.removeValue(forKey: call.uuid)
    rememberEnded(callId: call.callId, roomId: call.roomId, now: now)
    pending.removeAll { $0.value["callId"] as? String == call.callId && $0.value["roomId"] as? String == call.roomId }
  }
  func rememberEnded(callId: String, roomId: String, now: TimeInterval) {
    tombstones = tombstones.filter { $0.value > now }
    if tombstones.count >= 128, let oldest = tombstones.min(by: { $0.value < $1.value }) { tombstones.removeValue(forKey: oldest.key) }
    tombstones[IOSCallDescriptor.uuid(for: callId, roomId: roomId)] = now + 60
  }
  func enqueue(action: String, call: IOSCallDescriptor, now: TimeInterval, muted: Bool? = nil, owner: String? = nil) {
    var value: [String: Any] = ["action": action, "callId": call.callId, "roomId": call.roomId, "at": Int64(now * 1000)]
    if let muted = muted { value["muted"] = muted }
    if let owner = owner { value["owner"] = owner }
    if pending.count >= 64 { pending.removeFirst() }
    pending.append((now + 30, value))
  }
  func drain(now: TimeInterval, owner: String? = nil) -> [[String: Any]] {
    guard let owner = owner, !owner.isEmpty else { return [] }
    let values = pending.filter {
      $0.expiry > now && ($0.value["owner"] == nil || $0.value["owner"] as? String == owner)
    }.map { action -> [String: Any] in
      var value = action.value
      // Only PushKit actions queued before first ownership may be claimed.
      // Already-owned actions never change identity when a new handler starts.
      value["owner"] = owner
      return value
    }
    pending.removeAll()
    return values
  }
  func clear() { calls.removeAll(); pending.removeAll(); tombstones.removeAll() }
}

// Pure command ownership guard, shared by every method on ios_calls. The first
// owner preserves a cold-start PushKit call; a replacement triggers cleanup.
final class IOSCallSessionOwner {
  enum Claim: Equatable { case invalid, initial, resumed, replaced }
  private var owner: String?
  var current: String? { owner }

  func claim(_ candidate: Any?) -> Claim {
    guard let candidate = candidate as? String, !candidate.isEmpty else { return .invalid }
    let previous = owner
    owner = candidate
    guard let previous = previous else { return .initial }
    return previous == candidate ? .resumed : .replaced
  }
  func accepts(_ candidate: Any?) -> Bool {
    guard let candidate = candidate as? String, !candidate.isEmpty, let owner = owner else { return false }
    return candidate == owner
  }
}
