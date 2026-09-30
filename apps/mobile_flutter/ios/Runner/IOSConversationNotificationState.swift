import Foundation

/// Match only message notifications for this exact encrypted room identifier.
/// Call notifications and opaque wakeups belong to their own lifecycle.
enum IOSConversationNotificationState {
  static func matches(roomId: String, userInfo: [AnyHashable: Any]) -> Bool {
    guard !roomId.isEmpty,
          let deliveredRoom = userInfo["room_id"] as? String,
          deliveredRoom == roomId,
          userInfo["call_id"] == nil,
          let eventId = userInfo["event_id"] as? String,
          !eventId.isEmpty else { return false }
    return true
  }
}
