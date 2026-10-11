import XCTest
@testable import Runner

final class IOSMediaStoragePolicyTests: XCTestCase {
  func testReportsSyntheticFilesystemCapabilities() throws {
    let manager = FileManager.default
    let base = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true)
    let folder = base.appendingPathComponent("capability-" + UUID().uuidString, isDirectory: true)
    defer { try? manager.removeItem(at: folder) }
    try manager.createDirectory(at: folder, withIntermediateDirectories: false,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var fresh = folder
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try fresh.setResourceValues(values)
    let protection = try manager.attributesOfItem(atPath: folder.path)[.protectionKey]
    let actual = (protection as? FileProtectionType)?.rawValue ?? (protection as? String)
    let resource = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    let filesystem = try manager.attributesOfFileSystem(forPath: folder.path)
    let report = "protection=\(actual ?? "nil"), excluded=\(String(describing: resource.isExcludedFromBackup)), " +
        "importantCapacity=\(String(describing: resource.volumeAvailableCapacityForImportantUsage)), " +
        "capacity=\(String(describing: resource.volumeAvailableCapacity)), systemFree=\(String(describing: filesystem[.systemFreeSize]))"
    let attachment = XCTAttachment(string: report)
    attachment.lifetime = .keepAlways
    add(attachment)
    print("SYNTHETIC_STORAGE_CAPABILITIES " + report)
  }

  func testRepeatedDirectoryPreparationPreservesExistingContent() throws {
    let policy = IOSMediaStoragePolicy()
    let first = try policy.pendingDirectory()
    let root = URL(fileURLWithPath: try XCTUnwrap(first["path"] as? String))
    let marker = root.appendingPathComponent("synthetic-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    try Data("preserved".utf8).write(to: marker)
    XCTAssertEqual(try policy.pendingDirectory()["path"] as? String, root.path)
    XCTAssertEqual(try Data(contentsOf: marker), Data("preserved".utf8))
    _ = try policy.documentsChatMediaPolicy()
    _ = try policy.documentsChatMediaPolicy()
  }

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

  func testRejectsDirectoriesAndDanglingOptionalEntries() throws {
    let manager = FileManager.default
    let policy = IOSMediaStoragePolicy()
    let root = URL(fileURLWithPath: try XCTUnwrap(try policy.pendingDirectory()["path"] as? String))
    let scope = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "0", count: 32)
    let folder = root.appendingPathComponent(scope, isDirectory: true)
    defer { try? manager.removeItem(at: folder) }
    let sources = folder.appendingPathComponent("sources", isDirectory: true)
    try manager.createDirectory(at: sources, withIntermediateDirectories: true)
    let manifest = folder.appendingPathComponent("manifest-v1.db")
    try manager.createDirectory(at: manifest, withIntermediateDirectories: false)
    XCTAssertThrowsError(try policy.sealPendingFiles(scope: scope, sourceId: nil))
    try manager.removeItem(at: manifest)
    try Data("synthetic".utf8).write(to: manifest)
    let source = String(repeating: "f", count: 64)
    let file = sources.appendingPathComponent(source + ".bin")
    try manager.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try policy.sealPendingFiles(scope: scope, sourceId: source))
    try manager.removeItem(at: file)
    try Data("synthetic-source".utf8).write(to: file)
    let wal = folder.appendingPathComponent("manifest-v1.db-wal")
    try manager.createSymbolicLink(at: wal, withDestinationURL: folder.appendingPathComponent("absent-wal"))
    XCTAssertThrowsError(try policy.sealPendingFiles(scope: scope, sourceId: source))
    try manager.removeItem(at: wal)
    try manager.createSymbolicLink(at: sources.appendingPathComponent(source + ".bin.part"),
                                  withDestinationURL: sources.appendingPathComponent("absent-part"))
    XCTAssertThrowsError(try policy.sealPendingFiles(scope: scope, sourceId: source))
    XCTAssertEqual(try Data(contentsOf: file), Data("synthetic-source".utf8))
  }
}
