import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  private let now: TimeInterval = 1_800_000_000
  private func payload(_ call: String = "opaque-call") -> [String: Any] {
    ["call_id": call, "room_id": "!room:server", "video": true, "expires_at": now + 30]
  }
  func testPayloadRequiresBoundIdentifiersAndShortExpiry() throws {
    let call = try XCTUnwrap(IOSCallDescriptor(push: payload(), now: now))
    XCTAssertEqual(call.callId, "opaque-call")
    XCTAssertEqual(call.roomId, "!room:server")
    XCTAssertTrue(call.video)
    var invalid = payload(); invalid["room_id"] = ""
    XCTAssertNil(IOSCallDescriptor(push: invalid, now: now))
    invalid = payload(); invalid["expires_at"] = now
    XCTAssertNil(IOSCallDescriptor(push: invalid, now: now))
    invalid["expires_at"] = now + 90
    XCTAssertNil(IOSCallDescriptor(push: invalid, now: now))
    invalid["expires_at"] = "1800000030"
    XCTAssertNil(IOSCallDescriptor(push: invalid, now: now))
  }
  func testOpaqueIdentifierProducesStableDistinctUUID() {
    XCTAssertEqual(IOSCallDescriptor.uuid(for: "call-a"), IOSCallDescriptor.uuid(for: "call-a"))
    XCTAssertNotEqual(IOSCallDescriptor.uuid(for: "call-a"), IOSCallDescriptor.uuid(for: "call-b"))
  }
  func testDuplicateAndMismatchedRoomCannotReplaceCall() throws {
    let call = try XCTUnwrap(IOSCallDescriptor(push: payload(), now: now))
    let state = IOSCallState()
    XCTAssertTrue(state.insert(call, now: now))
    XCTAssertFalse(state.insert(call, now: now))
    var otherRoom = payload(); otherRoom["room_id"] = "!other:server"
    XCTAssertFalse(state.insert(try XCTUnwrap(IOSCallDescriptor(push: otherRoom, now: now)), now: now))
    XCTAssertNil(state.match(callId: call.callId, roomId: "!other:server"))
    XCTAssertEqual(state.match(callId: call.callId, roomId: call.roomId)?.uuid, call.uuid)
  }
  func testActionQueueIsBoundedFIFOAndLogoutClearsEverything() throws {
    let state = IOSCallState()
    let call = try XCTUnwrap(IOSCallDescriptor(push: payload(), now: now))
    XCTAssertTrue(state.insert(call, now: now))
    state.enqueue(action: "incoming", call: call, now: now)
    state.enqueue(action: "answer", call: call, now: now + 1)
    let actions = state.drain(now: now + 2)
    XCTAssertEqual(actions.compactMap { $0["action"] as? String }, ["incoming", "answer"])
    XCTAssertTrue(actions.allSatisfy { $0["callId"] as? String == call.callId && $0["roomId"] as? String == call.roomId })
    XCTAssertTrue(state.drain(now: now + 2).isEmpty)
    state.enqueue(action: "answer", call: call, now: now)
    XCTAssertTrue(state.drain(now: now + 31).isEmpty)
    state.clear()
    XCTAssertNil(state.match(callId: call.callId, roomId: call.roomId))
    XCTAssertTrue(state.drain(now: now).isEmpty)
  }
  func testEndedCallTombstonePreventsLatePushAndClearsAnswer() throws {
    let state = IOSCallState()
    let call = try XCTUnwrap(IOSCallDescriptor(push: payload(), now: now))
    XCTAssertTrue(state.insert(call, now: now))
    state.enqueue(action: "answer", call: call, now: now)
    state.remove(call, now: now + 1)
    XCTAssertFalse(state.insert(call, now: now + 2))
    XCTAssertTrue(state.drain(now: now + 2).isEmpty)
  }
}
