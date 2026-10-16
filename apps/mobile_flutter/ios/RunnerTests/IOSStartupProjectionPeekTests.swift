import XCTest
import Security
@testable import Runner

private final class ProjectionPeekSecurity: IOSSessionSecurityOperations {
  var reads = 0
  var writes = 0
  var status: OSStatus = errSecItemNotFound
  func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
    reads += 1
    return (status, nil)
  }
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { writes += 1; return errSecSuccess }
  func add(_ attributes: [String: Any]) -> OSStatus { writes += 1; return errSecSuccess }
  func delete(_ query: [String: Any]) -> OSStatus { writes += 1; return errSecSuccess }
}

final class IOSStartupProjectionPeekTests: XCTestCase {
  func testInspectionAllowlistNeverMutatesKeychain() throws {
    let security = ProjectionPeekSecurity()
    let store = IOSSecureSessionStore(security: security)
    let keys = ["liuhetong.registration_device_key.v1", "liuhetong.startup_projection_head.v1",
                "liuhetong.startup_projection_head.v1." + String(repeating: "a", count: 64)]
    for key in keys {
      XCTAssertNil(try store.peek(key: key))
      XCTAssertThrowsError(try store.write(key: key, value: "synthetic"))
      XCTAssertThrowsError(try store.delete(key: key))
    }
    XCTAssertEqual(security.reads, 3)
    XCTAssertEqual(security.writes, 0)
    XCTAssertThrowsError(try store.peek(key: "liuhetong.startup_projection_head.v1.invalid"))
    XCTAssertEqual(security.reads, 3)
  }
  func testLockedInspectionPropagatesWithoutRepair() {
    let security = ProjectionPeekSecurity()
    security.status = errSecInteractionNotAllowed
    let store = IOSSecureSessionStore(security: security)
    XCTAssertThrowsError(try store.peek(key: "liuhetong.registration_device_key.v1")) { error in
      guard case IOSSecureSessionError.status(errSecInteractionNotAllowed) = error else {
        return XCTFail("Locked read must preserve native status")
      }
    }
    XCTAssertEqual(security.reads, 1)
    XCTAssertEqual(security.writes, 0)
  }
}
