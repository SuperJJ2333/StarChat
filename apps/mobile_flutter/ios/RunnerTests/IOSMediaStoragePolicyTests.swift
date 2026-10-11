import XCTest
@testable import Runner

final class IOSMediaStoragePolicyTests: XCTestCase {
  func testPendingDirectoryIsProtectedExcludedAndSeparateFromCache() throws {
    let policy = IOSMediaStoragePolicy()
    let result = try policy.pendingDirectory()
    let root = URL(fileURLWithPath: try XCTUnwrap(result["path"] as? String))
    XCTAssertEqual(root.lastPathComponent, "pending-media-v1")
    XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "Application Support")
    XCTAssertEqual(result["protected"] as? Bool, true)
    XCTAssertEqual(result["backupExcluded"] as? Bool, true)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(result["availableBytes"] as? Int64), 0)
    XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }

  func testSealsSyntheticSourceAndRejectsTraversalAndSymlink() throws {
    let policy = IOSMediaStoragePolicy()
    let root = URL(fileURLWithPath: try XCTUnwrap(try policy.pendingDirectory()["path"] as? String))
    let scope = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "0", count: 32)
    let folder = root.appendingPathComponent(scope, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = folder.appendingPathComponent("sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try Data("synthetic".utf8).write(to: folder.appendingPathComponent("manifest-v1.db"))
    let source = String(repeating: "a", count: 64)
    let file = sources.appendingPathComponent(source + ".bin")
    try Data("synthetic-source".utf8).write(to: file)
    let result = try policy.sealPendingFiles(scope: scope, sourceId: source)
    XCTAssertEqual(result["protected"] as? Bool, true)
    XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    XCTAssertEqual(try Data(contentsOf: file), Data("synthetic-source".utf8))
    XCTAssertThrowsError(try policy.sealPendingFiles(scope: "../outside", sourceId: nil))
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: folder.appendingPathComponent("manifest-v1.db"))
    XCTAssertThrowsError(try policy.sealPendingFiles(scope: scope, sourceId: source))
  }
}
