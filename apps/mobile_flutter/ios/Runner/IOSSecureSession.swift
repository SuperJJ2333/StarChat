import Foundation
import Security

protocol IOSSessionSecurityOperations {
  func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
  func add(_ attributes: [String: Any]) -> OSStatus
  func delete(_ query: [String: Any]) -> OSStatus
}

private struct IOSSystemSessionSecurity: IOSSessionSecurityOperations {
  func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    return (status, value)
  }
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }
  func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
  func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

enum IOSSecureSessionError: Error {
  case invalidKey
  case invalidData
  case status(OSStatus)
  case verification
}

// ADR0011: only these two existing, device-local entries can be migrated.
// No recovery keys, Matrix room keys or other secure-storage items are queried.
final class IOSSecureSessionStore {
  private let security: IOSSessionSecurityOperations
  private static let keys: Set<String> = ["liuhetong.matrix_database_key.v1", "liuhetong.business_session.v1"]
  private static let service = "flutter_secure_storage_service"
  private let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

  init(security: IOSSessionSecurityOperations) { self.security = security }
  convenience init() { self.init(security: IOSSystemSessionSecurity()) }

  private func query(key: String) throws -> [String: Any] {
    guard Self.keys.contains(key) else { throw IOSSecureSessionError.invalidKey }
    // Accessibility is deliberately NOT a search filter: an old WhenUnlocked
    // item must return its real locked error, not masquerade as absent.
    return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false]
  }

  private func lookup(key: String) throws -> [String: Any]? {
    var query = try query(key: key)
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true
    query[kSecReturnAttributes as String] = true
    let (status, result) = security.copy(query)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw IOSSecureSessionError.status(status) }
    guard let item = result as? [String: Any], item[kSecValueData as String] is Data,
          item[kSecAttrAccount as String] as? String == key,
          item[kSecAttrService as String] as? String == Self.service,
          (item[kSecAttrSynchronizable as String] as? Bool ?? false) == false else {
      throw IOSSecureSessionError.invalidData
    }
    return item
  }

  func read(key: String) throws -> String? {
    guard let original = try lookup(key: key) else { return nil }
    guard let data = original[kSecValueData as String] as? Data,
          let value = String(data: data, encoding: .utf8) else { throw IOSSecureSessionError.invalidData }
    if original[kSecAttrAccessible as String] as? String != accessible {
      let status = security.update(try query(key: key), attributes: [kSecAttrAccessible as String: accessible])
      guard status == errSecSuccess else { throw IOSSecureSessionError.status(status) }
      try verify(key: key, expected: data, original: original)
    }
    return value
  }

  func write(key: String, value: String) throws {
    let query = try query(key: key)
    let original = try lookup(key: key)
    let data = Data(value.utf8)
    let changed: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
    let status: OSStatus
    if original != nil {
      // Even errSecItemNotFound here is a race/error, never permission to add.
      status = security.update(query, attributes: changed)
    } else {
      // Only the unequivocal errSecItemNotFound from lookup reaches this branch.
      status = security.add(query.merging(changed) { _, new in new })
    }
    guard status == errSecSuccess else { throw IOSSecureSessionError.status(status) }
    try verify(key: key, expected: data, original: original)
  }

  private func verify(key: String, expected: Data, original: [String: Any]?) throws {
    guard let checked = try lookup(key: key), checked[kSecValueData as String] as? Data == expected,
          checked[kSecAttrAccessible as String] as? String == accessible else { throw IOSSecureSessionError.verification }
    if let original = original {
      // The system may update modification time; identifiers and access group
      // must remain exactly the same and synchronizable must stay false.
      for name in [kSecAttrAccount, kSecAttrService, kSecAttrAccessGroup] {
        guard (checked[name as String] as? String) == (original[name as String] as? String) else {
          throw IOSSecureSessionError.verification
        }
      }
    }
  }

  func delete(key: String) throws {
    let status = security.delete(try query(key: key))
    guard status == errSecSuccess || status == errSecItemNotFound else { throw IOSSecureSessionError.status(status) }
  }
}
