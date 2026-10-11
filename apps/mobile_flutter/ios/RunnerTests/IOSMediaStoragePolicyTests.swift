import XCTest
@testable import Runner

final class IOSMediaStoragePolicyTests: XCTestCase {
  private struct FilesystemCapabilities {
    let protection: String?
    let excluded: Bool?
    let availableBytes: Int64?

    var verifiedSimulatorWithoutDataProtection: Bool {
      #if targetEnvironment(simulator)
      return protection == nil && excluded == true && (availableBytes.map { $0 >= 0 } ?? false)
      #else
      return false
      #endif
    }
  }

  private func requireDataProtection() throws {
    let capabilities = try probeFilesystemCapabilities()
    if capabilities.verifiedSimulatorWithoutDataProtection {
      throw XCTSkip("Simulator filesystem returned nil protection after explicit completeUntilFirstUserAuthentication set/readback; backup exclusion and nonnegative important capacity verified. Real-device Data Protection success remains unverified.")
    }
    XCTAssertEqual(capabilities.protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    XCTAssertEqual(capabilities.excluded, true)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(capabilities.availableBytes), 0)
  }

  func testRunnerBundlesStoragePrivacyReasons() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    let manifest = try XCTUnwrap(try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), format: nil) as? [String: Any])
    let entries = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    for (category, reason) in [("DiskSpace", "E174.1"), ("FileTimestamp", "C617.1"), ("UserDefaults", "CA92.1")] {
      let entry = try XCTUnwrap(entries.first {
        $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategory" + category
      })
      XCTAssertTrue((entry["NSPrivacyAccessedAPITypeReasons"] as? [String])?.contains(reason) == true)
    }
  }

  private func probeFilesystemCapabilities() throws -> FilesystemCapabilities {
    let manager = FileManager.default
    let base = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true)
    let folder = base.appendingPathComponent("capability-" + UUID().uuidString, isDirectory: true)
    defer { try? manager.removeItem(at: folder) }
    try manager.createDirectory(at: folder, withIntermediateDirectories: false,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                              ofItemAtPath: folder.path)
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
    return FilesystemCapabilities(protection: actual, excluded: resource.isExcludedFromBackup,
                                 availableBytes: resource.volumeAvailableCapacityForImportantUsage)
  }

  func testReportsSyntheticFilesystemCapabilities() throws {
    let capabilities = try probeFilesystemCapabilities()
    XCTAssertEqual(capabilities.excluded, true)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(capabilities.availableBytes), 0)
    if !capabilities.verifiedSimulatorWithoutDataProtection {
      XCTAssertEqual(capabilities.protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    }
  }

  func testRepeatedDirectoryPreparationPreservesExistingContent() throws {
    try requireDataProtection()
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
    try requireDataProtection()
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
    try requireDataProtection()
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
    try requireDataProtection()
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

  func testDirectoryPreparationMatchesCapabilityAndPreservesContent() throws {
    let capabilities = try probeFilesystemCapabilities()
    XCTAssertEqual(capabilities.excluded, true)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(capabilities.availableBytes), 0)
    let unsupported = capabilities.verifiedSimulatorWithoutDataProtection
    if !unsupported {
      XCTAssertEqual(capabilities.protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    }
    let manager = FileManager.default
    let base = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true).resolvingSymlinksInPath()
    let root = base.appendingPathComponent("pending-media-v1", isDirectory: true)
    let marker = root.appendingPathComponent("synthetic-" + UUID().uuidString)
    defer { try? manager.removeItem(at: marker) }
    let policy = IOSMediaStoragePolicy()
    for attempt in 0..<2 {
      if unsupported {
        XCTAssertThrowsError(try policy.pendingDirectory()) {
          XCTAssertEqual(String(describing: $0), "protectionUnavailable")
        }
        XCTAssertThrowsError(try policy.documentsChatMediaPolicy()) {
          XCTAssertEqual(String(describing: $0), "protectionUnavailable")
        }
      } else {
        XCTAssertEqual(try policy.pendingDirectory()["path"] as? String, root.path)
        XCTAssertEqual(try policy.documentsChatMediaPolicy()["protected"] as? Bool, true)
      }
      if attempt == 0 { try Data("preserved".utf8).write(to: marker) }
      XCTAssertEqual(try Data(contentsOf: marker), Data("preserved".utf8))
    }
  }

  func testEntryValidationWithoutDataProtectionRejectsUnsafeEntries() throws {
    let manager = FileManager.default
    let base = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true).resolvingSymlinksInPath()
    let fixture = base.appendingPathComponent("entries-" + UUID().uuidString, isDirectory: true)
    defer { try? manager.removeItem(at: fixture) }
    let root = fixture.appendingPathComponent("root", isDirectory: true)
    let outside = fixture.appendingPathComponent("root-outside", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try manager.createDirectory(at: outside, withIntermediateDirectories: false)
    let policy = IOSMediaStoragePolicy()
    let file = root.appendingPathComponent("source.bin")
    try Data("preserved".utf8).write(to: file)
    XCTAssertEqual(try policy.validateEntry(root, inside: root, directory: true), root.path)
    XCTAssertEqual(try policy.validateEntry(file, inside: root), file.path)
    func rejected(_ url: URL, directory: Bool = false) {
      XCTAssertThrowsError(try policy.validateEntry(url, inside: root, directory: directory)) {
        XCTAssertEqual(String(describing: $0), "invalidEntry")
      }
    }
    rejected(root) // A directory must not stand in for a manifest or source.
    rejected(file, directory: true)
    rejected(outside, directory: true) // A prefix sibling is outside the root.
    rejected(root.appendingPathComponent("../root-outside"), directory: true)
    rejected(root.appendingPathComponent("absent"))
    let link = root.appendingPathComponent("linked.bin")
    try manager.createSymbolicLink(at: link, withDestinationURL: file)
    rejected(link)
    for name in ["manifest-v1.db-wal", "source.bin.part"] {
      let dangling = root.appendingPathComponent(name)
      try manager.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("absent"))
      rejected(dangling)
    }
    let alias = root.appendingPathComponent("alias", isDirectory: true)
    try manager.createSymbolicLink(at: alias, withDestinationURL: root)
    rejected(alias.appendingPathComponent("source.bin"))
    XCTAssertThrowsError(try policy.sealPendingFiles(scope: "../outside", sourceId: nil)) {
      XCTAssertEqual(String(describing: $0), "invalidEntry")
    }
    XCTAssertEqual(try Data(contentsOf: file), Data("preserved".utf8))
  }
}
