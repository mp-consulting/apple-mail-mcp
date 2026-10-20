import Foundation
import Security

/// The secret that turns indexed words into opaque tokens (see ``BodyIndex``).
///
/// Mail's own store is behind Full Disk Access; the index file is not. Without this key the
/// index holds no text, only keyed hashes, so a process that can read the file still cannot
/// read mail. The key lives in the Keychain, out of reach of other apps (see ``KeychainSecret``).
public struct BodyIndexKey: Sendable, Equatable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 16, "the body index key is 16 bytes")
        self.bytes = bytes
    }

    public static func random() -> BodyIndexKey { BodyIndexKey(bytes: KeychainSecret.random(16)) }

    /// The key for an index at `url`. The real index (the default location) always uses the Keychain's. An
    /// index elsewhere, which `mail-bench` builds on generated or throwaway data, may use a fixed key from
    /// `APPLE_MAIL_MCP_TEST_INDEX_KEY` (32 hex digits) instead, so the server it starts reads that index without a
    /// Keychain prompt. Where the index is decides, not the environment alone: no variable makes the real index
    /// use a key someone else knows.
    public static func provider(forIndexAt url: URL) -> @Sendable () throws -> BodyIndexKey {
        if let key = testKey(forIndexAt: url, environment: ProcessInfo.processInfo.environment) { return { key } }
        return fromKeychain
    }

    static func testKey(forIndexAt url: URL, environment: [String: String]) -> BodyIndexKey? {
        let real = BodyIndex.defaultURL().standardizedFileURL.resolvingSymlinksInPath().path
        guard url.standardizedFileURL.resolvingSymlinksInPath().path != real,
            let hex = environment["APPLE_MAIL_MCP_TEST_INDEX_KEY"]
        else { return nil }
        return BodyIndexKey(hex: hex)
    }

    /// 32 hex digits; nil for anything else.
    public init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count == 32 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes: bytes)
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    public static let service = "apple-mail-mcp.body-index"
    public static let account = "token-key"

    /// Reads the key from the Keychain, creating it on first use (see ``KeychainSecret``).
    public static func fromKeychain() throws -> BodyIndexKey {
        do {
            return BodyIndexKey(bytes: try KeychainSecret.load(
                service: service, account: account, length: 16, label: "Apple Mail MCP search index key",
                description: "Unlocks the body search index of Apple Mail MCP"))
        } catch KeychainSecret.Failure.keychain(let status) {
            throw BodyIndexKeyError.keychain(status)
        } catch {
            throw BodyIndexKeyError.malformed
        }
    }
}

/// A random secret in the Keychain, created on first use and shared by the menu bar app and the server.
///
/// Release builds keep it in the data protection Keychain under the team's access group, which both executables
/// claim (their provisioning profile allows it), so neither is ever asked for a key the other made. A key from an
/// earlier version, in the login Keychain, is copied over the first time and left in place. Builds without the
/// access group (development builds, the Claude extension's lone binary) use the login Keychain, where macOS asks
/// before another program reads the item.
public enum KeychainSecret {
    public enum Failure: Error, Sendable {
        case keychain(OSStatus)
        case malformed
    }

    static let accessGroup = "4HWBUF2R8D.com.mpconsulting.AppleMailMCP"

    /// Whether this build claims the team's access group (a release build with its provisioning profile), so its
    /// secrets are the ones the app and the server share. Reads nothing.
    public static var claimsSharedGroup: Bool {
        SecItemCopyMatching(query(service: "apple-mail-mcp.probe", account: "probe", protected: true) as CFDictionary, nil)
            != errSecMissingEntitlement
    }

    /// Whether the login Keychain holds the item; reads its attributes only, which macOS never asks about.
    public static func inLoginKeychain(service: String, account: String) -> Bool {
        var query = query(service: service, account: account, protected: false)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The item in the data protection Keychain in the team's group, or in the login Keychain.
    static func query(service: String, account: String, protected: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if protected {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public static func random(_ length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }

    public static func load(service: String, account: String, length: Int, label: String, description: String) throws -> [UInt8] {
        let item = Item(service: service, account: account, length: length, label: label, description: description)
        do {
            if let bytes = try item.read(protected: true) { return bytes }
            // First run of a version with the access group: keep the key an earlier version made.
            let bytes = try item.read(protected: false) ?? random(length)
            return try item.add(bytes, protected: true)
        } catch Failure.keychain(errSecMissingEntitlement) {
            if let bytes = try item.read(protected: false) { return bytes }
            return try item.add(random(length), protected: false)
        }
    }

    private struct Item {
        let service: String
        let account: String
        let length: Int
        let label: String
        let description: String

        private func query(protected: Bool) -> [String: Any] {
            KeychainSecret.query(service: service, account: account, protected: protected)
        }

        func read(protected: Bool) throws -> [UInt8]? {
            var query = query(protected: protected)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw Failure.keychain(status) }
            guard let data = result as? Data, data.count == length else { throw Failure.malformed }
            return [UInt8](data)
        }

        /// Adds `bytes`; when another process added the item first, returns what it stored instead.
        func add(_ bytes: [UInt8], protected: Bool) throws -> [UInt8] {
            var item = query(protected: protected)
            item[kSecAttrLabel as String] = label
            item[kSecAttrDescription as String] = description
            item[kSecValueData as String] = Data(bytes)
            // The server runs while the screen is locked (MCP clients, indexing), never on another Mac.
            if protected { item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
            let status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem, let raced = try read(protected: protected) { return raced }
            guard status == errSecSuccess else { throw Failure.keychain(status) }
            return bytes
        }
    }
}

public enum BodyIndexKeyError: Error, CustomStringConvertible, Sendable {
    case keychain(OSStatus)
    case malformed

    public var description: String {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "The search index key is not available from the Keychain (\(message)). Body searches scan messages instead."
        case .malformed:
            return "The search index key in the Keychain is malformed; delete \"Apple Mail MCP search index key\" in Keychain Access to start over."
        }
    }
}
