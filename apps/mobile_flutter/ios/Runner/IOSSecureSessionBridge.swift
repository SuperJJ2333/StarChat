import Flutter

final class IOSSecureSessionBridge {
  private let store = IOSSecureSessionStore()
  private var channel: FlutterMethodChannel?
  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "chatflow/ios_secure_session", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "secure_session_unavailable", message: "Session storage unavailable", details: nil)); return }
      guard let arguments = call.arguments as? [String: Any], let key = arguments["key"] as? String else {
        result(FlutterError(code: "secure_session_arguments", message: "Invalid session storage arguments", details: nil)); return
      }
      do {
        switch call.method {
        case "read": result(try self.store.read(key: key))
        case "write":
          guard let value = arguments["value"] as? String else { throw IOSSecureSessionError.invalidData }
          try self.store.write(key: key, value: value); result(nil)
        case "delete": try self.store.delete(key: key); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      } catch IOSSecureSessionError.status(let status) {
        // Return the actual OSStatus without secret values or keychain queries.
        result(FlutterError(code: "secure_session_status", message: "Keychain operation failed", details: ["status": status]))
      } catch {
        result(FlutterError(code: "secure_session_integrity", message: "Session storage validation failed", details: nil))
      }
    }
  }
}
