import Foundation
import Flutter
import Darwin

/// Caller supplies only opaque identifiers, never a filesystem path.
final class IOSMediaStoragePolicy {
  private let manager = FileManager.default
  private enum Failure: Error {
    case unavailable, invalidEntry, protectionUnavailable, backupExclusionUnavailable, capacityUnavailable
  }

  private func base(_ directory: FileManager.SearchPathDirectory) throws -> URL {
    try manager.url(for: directory, in: .userDomainMask,
                    appropriateFor: nil, create: true).resolvingSymlinksInPath()
  }

  private func entryType(_ url: URL) throws -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      if errno == ENOENT { return nil }
      throw Failure.unavailable
    }
    return info.st_mode & mode_t(S_IFMT)
  }

  // Kept separate so entry safety is testable even on Simulator filesystems
  // without Data Protection. Every production apply still validates first.
  func validateEntry(_ url: URL, inside root: URL, directory: Bool = false) throws -> String {
    let path = url.standardizedFileURL.path
    guard path == root.path || path.hasPrefix(root.path + "/"),
          url.resolvingSymlinksInPath().path == path,
          try entryType(url) == mode_t(directory ? S_IFDIR : S_IFREG)
    else { throw Failure.invalidEntry }
    return path
  }

  private func apply(_ url: URL, inside root: URL, directory: Bool = false) throws {
    let path = try validateEntry(url, inside: root, directory: directory)
    try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                              ofItemAtPath: path)
    var fresh = URL(fileURLWithPath: path)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try fresh.setResourceValues(values)
    let protection = try manager.attributesOfItem(atPath: path)[.protectionKey]
    let actual = (protection as? FileProtectionType)?.rawValue ?? (protection as? String)
    guard actual == FileProtectionType.completeUntilFirstUserAuthentication.rawValue
    else { throw Failure.protectionUnavailable }
    guard try URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    else { throw Failure.backupExclusionUnavailable }
  }

  private func directory(_ name: String, inside parent: URL) throws -> URL {
    let url = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
    let existing = try entryType(url)
    guard url.resolvingSymlinksInPath().path == url.path,
          existing == nil || existing == mode_t(S_IFDIR) else { throw Failure.invalidEntry }
    if existing == nil {
      try manager.createDirectory(at: url, withIntermediateDirectories: false,
          attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
    try apply(url, inside: parent, directory: true)
    return url
  }

  private func pendingRoot() throws -> URL {
    try directory("pending-media-v1", inside: base(.applicationSupportDirectory))
  }

  func pendingDirectory() throws -> [String: Any] {
    let root = try pendingRoot()
    let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage
    guard let capacity = capacity, capacity >= 0 else { throw Failure.capacityUnavailable }
    return ["path": root.path, "availableBytes": capacity,
            "protected": true, "backupExcluded": true]
  }

  private func validId(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  func sealPendingFiles(scope: String, sourceId: String?) throws -> [String: Any] {
    guard validId(scope), sourceId.map(validId) ?? true else { throw Failure.invalidEntry }
    let root = try pendingRoot()
    let namespace = root.appendingPathComponent(scope, isDirectory: true)
    // Do not manufacture a missing namespace or manifest and call it recovery.
    try apply(namespace, inside: root, directory: true)
    try apply(namespace.appendingPathComponent("manifest-v1.db"), inside: root)
    for suffix in ["-journal", "-wal", "-shm"] {
      let file = namespace.appendingPathComponent("manifest-v1.db" + suffix)
      if try entryType(file) != nil { try apply(file, inside: root) }
    }
    let sources = namespace.appendingPathComponent("sources", isDirectory: true)
    if try entryType(sources) != nil { try apply(sources, inside: root, directory: true) }
    if let sourceId = sourceId {
      var found = false
      for suffix in [".bin", ".bin.part"] {
        let file = sources.appendingPathComponent(sourceId + suffix)
        if try entryType(file) != nil {
          try apply(file, inside: root)
          found = true
        }
      }
      guard found else { throw Failure.unavailable }
    }
    return ["protected": true, "backupExcluded": true]
  }

  func documentsChatMediaPolicy() throws -> [String: Any] {
    // Preserve the current Documents cache and cover the future Caches root.
    // This excludes directory groups; it does not move or delete user files.
    _ = try directory("chat-media", inside: base(.documentDirectory))
    _ = try directory("chat-media", inside: base(.cachesDirectory))
    return ["protected": true, "backupExcluded": true]
  }

  static func attach(messenger: FlutterBinaryMessenger) {
    let policy = IOSMediaStoragePolicy()
    let queue = DispatchQueue(label: "chatflow.media-storage", qos: .utility)
    FlutterMethodChannel(name: "chatflow/media_storage", binaryMessenger: messenger)
        .setMethodCallHandler { call, result in
      guard ["pendingMediaDirectory", "sealPendingFiles", "documentsChatMediaPolicy"].contains(call.method)
      else { result(FlutterMethodNotImplemented); return }
      queue.async {
        do {
          let value: [String: Any]
          if call.method == "sealPendingFiles" {
            guard let args = call.arguments as? [String: Any],
                  args.keys.allSatisfy({ $0 == "scope" || $0 == "sourceId" }),
                  let scope = args["scope"] as? String,
                  args["sourceId"] == nil || args["sourceId"] is NSNull || args["sourceId"] is String
            else { throw Failure.invalidEntry }
            value = try policy.sealPendingFiles(scope: scope, sourceId: args["sourceId"] as? String)
          } else {
            guard call.arguments == nil || call.arguments is NSNull else { throw Failure.invalidEntry }
            value = try call.method == "pendingMediaDirectory"
                ? policy.pendingDirectory() : policy.documentsChatMediaPolicy()
          }
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "MEDIA_STORAGE_UNAVAILABLE",
                message: "Protected media storage unavailable", details: nil))
          }
        }
      }
    }
  }
}
