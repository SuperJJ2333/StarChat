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
  func testEndCommandRequiresBothIdentifiersAndCannotSelectAnotherRoom() throws {
    let state = IOSCallState()
    let call = try XCTUnwrap(IOSCallDescriptor(push: payload(), now: now))
    XCTAssertTrue(state.insert(call, now: now))
    for invalid: [String: Any] in [[:], ["callId": call.callId], ["roomId": call.roomId],
                                  ["callId": call.callId, "roomId": "!other:server"],
                                  ["callId": "another-call", "roomId": call.roomId],
                                  ["callId": 1, "roomId": call.roomId],
                                  ["callId": call.callId, "roomId": NSNull()]] {
      XCTAssertNil(state.resolveEndCommand(invalid))
      XCTAssertEqual(state.calls.count, 1)
    }
    XCTAssertEqual(state.resolveEndCommand(["callId": call.callId, "roomId": call.roomId])?.uuid, call.uuid)
    XCTAssertEqual(state.calls.count, 1)
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
import Security

final class IOSSecureSessionTests: XCTestCase {
  private let key = "liuhetong.matrix_database_key.v1"
  private func item(_ value: String = "existing-secret", accessible: CFString = kSecAttrAccessibleWhenUnlocked) -> [String: Any] {
    [kSecValueData as String: Data(value.utf8), kSecAttrAccount as String: key,
     kSecAttrService as String: "flutter_secure_storage_service", kSecAttrAccessible as String: accessible,
     kSecAttrSynchronizable as String: false, kSecAttrAccessGroup as String: "existing-app-group"]
  }
  func testLockedReadPropagatesWithoutFallbackOrMutation() {
    let ops = FakeSessionSecurity(); ops.copies = [(errSecInteractionNotAllowed, nil)]
    XCTAssertThrowsError(try IOSSecureSessionStore(security: ops).read(key: key))
    XCTAssertEqual(ops.queries.count, 1)
    XCTAssertTrue(ops.updates.isEmpty); XCTAssertTrue(ops.additions.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
  }
  func testOnlyNotFoundReturnsNil() throws {
    let ops = FakeSessionSecurity(); ops.copies = [(errSecItemNotFound, nil)]
    XCTAssertNil(try IOSSecureSessionStore(security: ops).read(key: key))
    XCTAssertTrue(ops.updates.isEmpty); XCTAssertTrue(ops.additions.isEmpty)
  }
  func testMigrationChangesOnlyAccessibilityAndVerifiesOriginalBytes() throws {
    let ops = FakeSessionSecurity()
    ops.copies = [(errSecSuccess, item() as CFDictionary), (errSecSuccess, item(accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) as CFDictionary)]
    XCTAssertEqual(try IOSSecureSessionStore(security: ops).read(key: key), "existing-secret")
    XCTAssertEqual(ops.updates.count, 1)
    XCTAssertEqual(Set(ops.updates[0].1.keys), [kSecAttrAccessible as String])
    XCTAssertTrue(ops.additions.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
    for query in ops.queries {
      XCTAssertNil(query[kSecAttrAccessible as String]); XCTAssertNil(query[kSecAttrAccessGroup as String])
      XCTAssertEqual(query[kSecAttrAccount as String] as? String, key)
      XCTAssertEqual(query[kSecAttrService as String] as? String, "flutter_secure_storage_service")
      XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    }
  }
  func testMigrationFailureNeverDeletesAddsOrRewritesSecret() {
    let ops = FakeSessionSecurity(); ops.copies = [(errSecSuccess, item() as CFDictionary)]
    ops.updateStatus = errSecInteractionNotAllowed
    XCTAssertThrowsError(try IOSSecureSessionStore(security: ops).read(key: key))
    XCTAssertEqual(ops.updates.count, 1)
    XCTAssertNil(ops.updates[0].1[kSecValueData as String])
    XCTAssertTrue(ops.additions.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
  }
  func testMigrationReadbackMismatchStopsWithoutRepair() {
    let ops = FakeSessionSecurity()
    ops.copies = [(errSecSuccess, item() as CFDictionary), (errSecSuccess, item("changed-secret", accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) as CFDictionary)]
    XCTAssertThrowsError(try IOSSecureSessionStore(security: ops).read(key: key))
    XCTAssertEqual(ops.updates.count, 1); XCTAssertTrue(ops.additions.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
  }
  func testAlreadyMigratedReadDoesNotWrite() throws {
    let ops = FakeSessionSecurity(); ops.copies = [(errSecSuccess, item(accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) as CFDictionary)]
    XCTAssertEqual(try IOSSecureSessionStore(security: ops).read(key: key), "existing-secret")
    XCTAssertTrue(ops.updates.isEmpty)
  }
  func testWriteLockedLookupNeverAdds() {
    let ops = FakeSessionSecurity(); ops.copies = [(errSecInteractionNotAllowed, nil)]
    XCTAssertThrowsError(try IOSSecureSessionStore(security: ops).write(key: key, value: "new-secret"))
    XCTAssertTrue(ops.additions.isEmpty); XCTAssertTrue(ops.updates.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
  }
  func testExistingWriteFailureNeverFallsBackToAddDelete() {
    let ops = FakeSessionSecurity(); ops.copies = [(errSecSuccess, item() as CFDictionary)]; ops.updateStatus = errSecItemNotFound
    XCTAssertThrowsError(try IOSSecureSessionStore(security: ops).write(key: key, value: "new-secret"))
    XCTAssertEqual(ops.updates.count, 1); XCTAssertTrue(ops.additions.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
  }
  func testAddOnlyAfterDefinitiveAbsenceAndDuplicateFailureStops() {
    let ops = FakeSessionSecurity(); ops.copies = [(errSecItemNotFound, nil)]; ops.addStatus = errSecDuplicateItem
    XCTAssertThrowsError(try IOSSecureSessionStore(security: ops).write(key: key, value: "new-secret"))
    XCTAssertEqual(ops.additions.count, 1); XCTAssertTrue(ops.updates.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
  }
  func testScopeRejectsAllOtherKeysWithoutTouchingSecurity() {
    let ops = FakeSessionSecurity(); let store = IOSSecureSessionStore(security: ops)
    XCTAssertThrowsError(try store.read(key: "recovery-key"))
    XCTAssertThrowsError(try store.write(key: "recovery-key", value: "value"))
    XCTAssertThrowsError(try store.delete(key: "recovery-key"))
    XCTAssertTrue(ops.queries.isEmpty); XCTAssertTrue(ops.additions.isEmpty); XCTAssertTrue(ops.updates.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
  }
  func testMigrationVerificationLockedErrorIsNotAbsence() {
    let ops = FakeSessionSecurity()
    ops.copies = [(errSecSuccess, item() as CFDictionary), (errSecInteractionNotAllowed, nil)]
    XCTAssertThrowsError(try IOSSecureSessionStore(security: ops).read(key: key))
    XCTAssertEqual(ops.queries.count, 2); XCTAssertEqual(ops.updates.count, 1)
    XCTAssertTrue(ops.additions.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
  }
  func testMigrationCannotSilentlyChangeAccessGroup() {
    let ops = FakeSessionSecurity()
    var changed = item(accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    changed[kSecAttrAccessGroup as String] = "different-group"
    ops.copies = [(errSecSuccess, item() as CFDictionary), (errSecSuccess, changed as CFDictionary)]
    XCTAssertThrowsError(try IOSSecureSessionStore(security: ops).read(key: key))
    XCTAssertTrue(ops.additions.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
  }
  func testExistingWriteUpdatesAndVerifiesWithoutDeleteAdd() throws {
    let ops = FakeSessionSecurity()
    ops.copies = [(errSecSuccess, item() as CFDictionary), (errSecSuccess, item("new-secret", accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) as CFDictionary)]
    try IOSSecureSessionStore(security: ops).write(key: key, value: "new-secret")
    XCTAssertEqual(ops.updates.count, 1)
    XCTAssertEqual(ops.updates[0].1[kSecValueData as String] as? Data, Data("new-secret".utf8))
    XCTAssertTrue(ops.additions.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
  }
  func testNewWriteAddsOnceAndVerifies() throws {
    let ops = FakeSessionSecurity()
    ops.copies = [(errSecItemNotFound, nil), (errSecSuccess, item("new-secret", accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) as CFDictionary)]
    try IOSSecureSessionStore(security: ops).write(key: key, value: "new-secret")
    XCTAssertEqual(ops.additions.count, 1); XCTAssertTrue(ops.updates.isEmpty); XCTAssertTrue(ops.deletions.isEmpty)
  }
  func testExplicitDeleteIsScopedToOneAllowedBusinessKey() throws {
    let ops = FakeSessionSecurity()
    try IOSSecureSessionStore(security: ops).delete(key: "liuhetong.business_session.v1")
    XCTAssertEqual(ops.deletions.count, 1)
    XCTAssertEqual(ops.deletions[0][kSecAttrAccount as String] as? String, "liuhetong.business_session.v1")
    XCTAssertEqual(ops.deletions[0][kSecAttrSynchronizable as String] as? Bool, false)
    XCTAssertTrue(ops.queries.isEmpty); XCTAssertTrue(ops.updates.isEmpty); XCTAssertTrue(ops.additions.isEmpty)
  }
}

private final class FakeSessionSecurity: IOSSessionSecurityOperations {
  var copies: [(OSStatus, CFTypeRef?)] = []
  var queries: [[String: Any]] = []
  var updates: [([String: Any], [String: Any])] = []
  var additions: [[String: Any]] = []
  var deletions: [[String: Any]] = []
  var updateStatus = errSecSuccess
  var addStatus = errSecSuccess
  func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) { queries.append(query); return copies.removeFirst() }
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { updates.append((query, attributes)); return updateStatus }
  func add(_ attributes: [String: Any]) -> OSStatus { additions.append(attributes); return addStatus }
  func delete(_ query: [String: Any]) -> OSStatus { deletions.append(query); return errSecSuccess }
}
