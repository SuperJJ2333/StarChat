import XCTest
@testable import Runner

final class IOSBackgroundMediaPolicyTests: XCTestCase {
  func testNonceSurvivesRestartAndLogoutPreventsLateAccountRevocation() {
    let suite = "background-media-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let alice = String(repeating: "a", count: 64)
    let bob = String(repeating: "b", count: 64)
    let first = IOSBackgroundMediaAccountState(defaults: defaults)
    let oldNonce = first.activate(alice)
    let restored = IOSBackgroundMediaAccountState(defaults: defaults)
    XCTAssertEqual(restored.activate(alice), oldNonce)
    restored.revoke(account: alice, nonce: oldNonce)
    let next = restored.activate(bob)
    restored.revoke(account: alice, nonce: oldNonce)
    XCTAssertEqual(restored.account, bob)
    XCTAssertEqual(restored.nonce, next)
    XCTAssertNotEqual(next, oldNonce)
    restored.revoke(account: bob, nonce: next)
    XCTAssertNil(IOSBackgroundMediaAccountState(defaults: defaults).account)
  }
  func testTrustedOriginAndSizeBoundaries() {
    func allowed(_ raw: String, origin: String = "https://matrix.test", kind: String = "matrix",
                 size: Int64 = 1024, token: String? = nil) -> Bool {
      IOSBackgroundMediaPolicy.allows(url: URL(string: raw)!, origin: origin,
        kind: kind, maxBytes: size, authorization: token, mediaType: kind == "moments" ? "image" : "cipher")
    }
    XCTAssertTrue(allowed("https://matrix.test/_matrix/client/v1/media/download/test/id?allow_redirect=false", token: "Bearer test"))
    XCTAssertFalse(allowed("https://evil.test/_matrix/client/v1/media/download/test/id", token: "Bearer test"))
    XCTAssertFalse(allowed("http://matrix.test/_matrix/client/v1/media/download/test/id"))
    XCTAssertFalse(allowed("https://matrix.test/other"))
    XCTAssertFalse(allowed("https://matrix.test/_matrix/media/v3/download/test/id", size: 67_108_865))
    XCTAssertTrue(allowed("https://api.test/api/v1/moments/media/content/id", origin: "https://api.test", kind: "moments"))
    XCTAssertFalse(allowed("https://api.test/api/v1/moments/media/content/id", origin: "https://api.test", kind: "moments", token: "Bearer test"))
  }
}
